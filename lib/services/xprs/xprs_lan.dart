/// XPRS over the local network — UDP broadcast, the cheapest bearer there is.
///
/// A station attached to a WiFi or an ethernet already has a medium that costs
/// nothing and reaches every machine in the building. `docs/lan.md` is this
/// bearer's page and `docs/XPRS.md` section 24.4 assigns the port: **UDP 4242**,
/// the same number XPRS answers on over TCP. Broadcast needs it on UDP because
/// TCP needs an address and the first station on a network knows nobody's; the
/// two sockets never collide.
///
/// ── What this is not ────────────────────────────────────────────────────────
///
/// Not Reticulum. Reticulum's LAN discovery is UDP 42671 and a different
/// protocol (`RnsLanInterface`); nothing here touches it.
///
/// ── This station does not relay ─────────────────────────────────────────────
///
/// It airs what it composed and it ingests what it hears. No `via:` appending,
/// no re-airing of somebody else's packet, no hop budget to get wrong — a
/// desktop is an endpoint on this bearer, and the digipeaters on the segment
/// are the stations built to be one. Adding relaying here means implementing
/// section 13.2.1 in full (the 200–1200 ms jitter AND the cancel-on-hearing),
/// so it is a deliberate omission rather than an oversight.
///
/// ── Why it does not rely on broadcast alone ─────────────────────────────────
///
/// WiFi drops and rate-limits broadcast, often asymmetrically per device: the
/// Reticulum LAN interface was measured with one phone's broadcasts reaching
/// the other but never the reverse, while unicast worked flawlessly both ways.
/// So every packet goes to the limited broadcast address, to each
/// subnet-directed `x.y.z.255`, AND unicast to every station we have heard a
/// datagram from. Hearing one packet from a peer is enough to make the rest of
/// the conversation reliable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../log_service.dart';
import '../receive/packet_gateway.dart';
import 'xprs_packet.dart';

/// A station whose datagram we have seen, so we can reach it by unicast.
class _LanPeer {
  _LanPeer(this.addr, this.port, this.lastMs);
  final InternetAddress addr;
  final int port;
  int lastMs;
}

class XprsLan {
  XprsLan._();
  static final XprsLan instance = XprsLan._();

  /// `docs/XPRS.md` section 24.4.
  static const int port = 4242;

  /// A peer we have not heard from in this long is not unicast to any more.
  /// Broadcast still reaches it, so this only stops the unicast list growing
  /// stale — it is not a reachability judgement.
  static const int _peerTtlMs = 10 * 60 * 1000;
  static const int _maxPeers = 32;

  RawDatagramSocket? _socket;
  String _selfCallsign = '';

  /// The socket can die under us -- the runtime closes it on an error the
  /// bearer never sees -- and before this the object kept the dead handle,
  /// reported `up`, sent into nothing and received nothing, for hours.
  /// Measured on the bench, 2026-08-30: `/api/xprs/bearers` said
  /// `active:true`, the process held no UDP socket at all, and packets that
  /// a raw listener on the same port saw never reached the app. So a close
  /// is now an EVENT this bearer handles: say why, drop the handle, and
  /// bind again after a moment.
  ///
  /// No poll watches for a socket that dies WITHOUT an event. The LAN beacon
  /// already sends every 300 s (mesh_service); a send on a dead socket
  /// throws, and that lands here too. A timer of our own would be a second
  /// tick for the same fact (docs/performance.md 6.5, 8.5).
  Timer? _reopen;
  int _reopenDelayS = 5;
  int reopened = 0;

  /// Our own addresses, so our own broadcast loopback is never ingested as if
  /// somebody else had said it.
  final Set<String> _selfAddrs = {};
  final List<InternetAddress> _directed = [];
  final Map<String, _LanPeer> _peers = {};

  int rx = 0;
  int tx = 0;
  int dropped = 0;

  bool get up => _socket != null;
  int get peerCount => _peers.length;

  set selfCallsign(String c) => _selfCallsign = c.trim();

  /// Open the socket. Safe to call repeatedly; safe before an interface has an
  /// address, since datagrams simply start arriving when one appears.
  Future<void> start({required String selfCallsign}) async {
    _selfCallsign = selfCallsign.trim();
    if (_socket != null) return;
    try {
      // `reusePort` so a second instance on the same machine — which is how
      // this bearer gets tested — can share the socket instead of failing to
      // bind and silently going deaf.
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port,
          reuseAddress: true, reusePort: true);
      s.broadcastEnabled = true;
      _socket = s;
      await _learnSelfAddresses();
      s.listen(_onEvent,
          onError: (Object e) => _lost('error: $e'),
          onDone: () => _lost('stream done'));
      _reopenDelayS = 5;
      LogService.instance
          .add('XPRS: LAN bearer on UDP $port (broadcast, ${_directed.length} '
              'subnet${_directed.length == 1 ? "" : "s"})');
    } catch (e) {
      // A bind failure is not fatal: every other bearer still works, and the
      // usual cause is another process already holding the port. It is also
      // not final: the next beacon's failed send brings us back here.
      LogService.instance.add('XPRS: LAN bearer could not bind UDP $port — $e');
    }
  }

  void stop() {
    _reopen?.cancel();
    _reopen = null;
    _socket?.close();
    _socket = null;
    _peers.clear();
  }

  /// The socket is gone. Forget it -- `up` must not lie -- and come back.
  void _lost(String why) {
    if (_socket == null) return;
    LogService.instance.add('XPRS: LAN bearer socket closed ($why) — '
        'reopening in ${_reopenDelayS}s');
    _socket = null;
    _scheduleReopen(why);
  }

  void _scheduleReopen(String why) {
    _reopen?.cancel();
    _reopen = Timer(Duration(seconds: _reopenDelayS), () async {
      _reopen = null;
      await start(selfCallsign: _selfCallsign);
      if (_socket != null) {
        reopened++;
        LogService.instance.add('XPRS: LAN bearer back on UDP $port ($why)');
      } else {
        // Back off, but never past the beacon's own cadence: a LAN that
        // comes back is missed for five minutes at most either way.
        _reopenDelayS = _reopenDelayS < 300 ? _reopenDelayS * 2 : 300;
        _scheduleReopen(why);
      }
    });
  }

  Future<void> _learnSelfAddresses() async {
    _selfAddrs.clear();
    _directed.clear();
    try {
      final list =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final ni in list) {
        for (final a in ni.addresses) {
          if (a.isLoopback) continue;
          _selfAddrs.add(a.address);
          // Assume /24, the home-LAN norm. A wrong guess costs one datagram
          // that nobody receives, not a failure.
          final p = a.address.split('.');
          if (p.length == 4) {
            final d = '${p[0]}.${p[1]}.${p[2]}.255';
            if (!_directed.any((x) => x.address == d)) {
              _directed.add(InternetAddress(d));
            }
          }
        }
      }
    } catch (_) {
      // No interface list (sandboxed, or none up yet). Limited broadcast alone
      // still works on most networks.
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
      _lost(event == RawSocketEvent.closed ? 'closed' : 'read side closed');
      return;
    }
    if (event != RawSocketEvent.read) return;
    final s = _socket;
    if (s == null) return;
    Datagram? dg;
    try {
      dg = s.receive();
    } catch (e) {
      _lost('receive: $e');
      return;
    }
    if (dg == null) return;

    final src = dg.address.address;
    if (_selfAddrs.contains(src)) return; // our own broadcast, come back to us

    rx++;
    _learnPeer(src, dg.address, dg.port);

    // One door. A datagram that is not XPRS is dropped by the gateway without
    // comment — that is what makes the bearer versionless (docs/lan.md) — and
    // is counted there rather than here.
    if (PacketGateway.instance.receive(dg.data,
            bearer: 'lan', lane: RxLane.advert, peer: src) !=
        RxVerdict.xprs) {
      dropped++;
    }
  }

  void _learnPeer(String ip, InternetAddress addr, int fromPort) {
    final known = _peers.containsKey(ip);
    _peers[ip] =
        _LanPeer(addr, fromPort == 0 ? port : fromPort, _nowMs());
    if (!known && _peers.length > _maxPeers) {
      var oldestKey = ip;
      var oldestMs = 1 << 62;
      for (final e in _peers.entries) {
        if (e.value.lastMs < oldestMs) {
          oldestMs = e.value.lastMs;
          oldestKey = e.key;
        }
      }
      _peers.remove(oldestKey);
    }
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Air one packet of our own: verbatim, one datagram, no header.
  ///
  /// Returns false when the socket is down or the wire is not a packet —
  /// never because delivery failed, which UDP cannot tell us.
  bool send(String wire) {
    final s = _socket;
    if (s == null) return false;
    final w = wire.trim();
    if (w.isEmpty || !w.startsWith('t:')) return false;
    final bytes = utf8.encode(w);
    if (bytes.length > XprsPacket.maxBytes) return false;

    var sent = false;
    try {
      sent = s.send(bytes, InternetAddress('255.255.255.255'), port) > 0;
      for (final d in _directed) {
        if (s.send(bytes, d, port) > 0) sent = true;
      }
      final cutoff = _nowMs() - _peerTtlMs;
      _peers.removeWhere((_, p) => p.lastMs < cutoff);
      for (final p in _peers.values) {
        if (s.send(bytes, p.addr, p.port) > 0) sent = true;
      }
    } catch (e) {
      // A send that throws is a socket that is no longer a socket.
      LogService.instance.add('XPRS: LAN send failed — $e');
      _lost('send: $e');
      return false;
    }
    if (sent) tx++;
    return sent;
  }

  /// Counters for a status view, so this is checkable without a wapp.
  Map<String, dynamic> statusJson() => {
        'up': up,
        'port': port,
        'rx': rx,
        'tx': tx,
        'dropped': dropped,
        'peers': _peers.length,
        // 0 subnets = no IPv4 interface found: the phone is not on a network,
        // and every send fails "Network is unreachable". Bench 2026-09-05:
        // this took a shell on the phone to see; it should take one curl.
        'subnets': _directed.length,
        'reopened': reopened,
      };
}
