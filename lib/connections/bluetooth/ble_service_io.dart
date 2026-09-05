// Native shared BLE service (Android/iOS/macOS/Windows/Linux). Owns the single
// adapter via the bluetooth_low_energy package and shares it across all wapps.
//
// THE CONNECTIONLESS LANE IS BLE5 ONLY. Broadcast goes out as one extended
// advert on the shared [Ble5Bus] (subtype 0x58 for XPRS), and comes back in
// through [PacketGateway]. A device without LE extended advertising —
// Android < 8.0, a chipset that reports isLeExtendedAdvertisingSupported
// false, or any platform with no Ble5 method channel — has no XPRS BLE lane.
//
// It used to have one, and that is worth recording rather than rediscovering.
// The legacy path scanned for our company frames itself and aired multi-chunk
// `[3E 50 …]` broadcasts with a NACK ARQ over a rotating legacy advertiser.
// Every piece of it was unreachable: a station drops any subtype that is not
// 0x58 on the first line of `on_ble` (firmware/common/xprs_app/xprs_app.c), and
// the chunker did not carry the subtype at all, so an XPRS wire went out under
// no type byte. It also read the radio around the core's single receive door.
// So it is gone — scan, chunker, ARQ, rotation and the ble_peripheral/BlueZ
// advertiser that existed only to drive it.
//
// What remains here: the reference-counted CentralManager scan (GATT discovery
// only), both GATT roles, and the BLE5 bus wiring. Every byte received arrives
// at [PacketGateway]; nothing in this file delivers anywhere else.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;

import '../../profile/profile_service.dart';
import '../../services/android_permissions_service.dart';
import '../../services/log_service.dart';
import '../../services/mesh/mesh_custody.dart';
import '../../services/power_state.dart';
import '../../services/mesh/mesh_transfer_scheduler.dart';
import '../../services/mesh/mesh_service.dart';
import '../../services/reticulum/rns_service.dart';
import '../../services/wifi_direct/wifi_direct_coordinator.dart';
import '../../services/mesh/mesh_session.dart' show MspCaps;
import '../../services/mesh/xblob_service.dart';
import '../../services/receive/packet_gateway.dart';
import '../../services/preferences_service.dart';
import '../../wapp/android_foreground_service.dart';
import 'ble5_bus.dart';
import 'ble_gatt_client.dart';
import 'ble_gatt_server.dart';
import 'ble_parcel.dart';
import 'ble_queue_service.dart';
import 'ble_reassembler.dart';

/// APRS-over-BLE manufacturer id carried in advertisement manufacturer data.
/// Must match peer firmware (e.g. ESP32). 0xFFFF is the reserved test id.
const int kBleCompanyId = 0xFFFF;

/// Service UUID advertised alongside the manufacturer data (the 16-bit 0xFFE0
/// the ESP32 uses, in 128-bit form). Some Android controllers won't actually
/// emit an advertisement that carries ONLY manufacturer data, so a service
/// UUID must be present; peers still match on the manufacturer data, not this.
const String kBleServiceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';

/// How long to hold a primary advert waiting for its continuation when the two
/// arrive as separate scan events (BlueZ collapses duplicate company ids, so
/// the advert and its scan response surface one after another, not together).
const Duration kBleContWindow = Duration(milliseconds: 450);

class BleInboundFrame {
  final String from; // peer uuid
  final int rssi;
  final Uint8List data; // the manufacturer payload (e.g. an APRS TNC2 frame)
  BleInboundFrame(this.from, this.rssi, this.data);
}

class BleService {
  BleService._();
  static final BleService instance = BleService._();

  CentralManager? _central;
  bool _inited = false;
  bool _advertiseSupported = true;
  WidgetsBindingObserver? _lifecycle;

  // Advertising backend: on Android/iOS use the ble_peripheral package (the
  // bluetooth_low_energy PeripheralManager doesn't reliably radiate on some
  // Android chipsets — XPRS uses ble_peripheral for the same reason). On
  // Linux fall back to BlueZ D-Bus. Scanning always uses CentralManager above.
  bool get _useBlePeripheral => Platform.isAndroid || Platform.isIOS;

  bool get supported => true;
  bool get advertiseSupported => _advertiseSupported;

  /// True only when the physical Bluetooth adapter is powered ON and usable.
  /// Goes false the moment the user turns Bluetooth off at the OS level, so a
  /// wapp can hide its "BLE available" indicator instead of claiming a channel
  /// that can't carry anything. Before init (no central yet) BLE is unavailable.
  bool get poweredOn {
    final c = _central;
    if (c != null) return c.state == BluetoothLowEnergyState.poweredOn;
    return false;
  }

  final _inbound = StreamController<BleInboundFrame>.broadcast();
  Stream<BleInboundFrame> get inbound => _inbound.stream;

  // BLE 5 connectionless broadcast (Android): when supported, APRS group
  // messages ride the shared Ble5Bus as ONE extended advert each (subtype 0x41),
  // multiplexed with Reticulum announces on a single advertising set. This
  // replaces the fragile legacy 13-24B chunk + NACK broadcast for the common
  // case; the legacy path stays only as a fallback for non-BLE5 devices.
  bool _ble5 = false; // device supports + we use BLE5 for APRS broadcast
  bool _ble5Checked = false;
  bool _ble5Wired = false;
  // BLE5 advert keys we registered, per owner, so clearAdverts can drop them.
  final Map<Object, Set<String>> _ble5Keys = {};
  // Receiver dedup for single-frame BLE5 APRS (keyed by payload hash) so the
  // sender's TTL re-airs are delivered to the wapp exactly once.
  final Map<String, DateTime> _ble5Seen = {};

  // Generic GATT parcel transport: this device is both a client (connects out
  // to peers' servers) and a server (peers connect in), bridged by one queue.
  BleGattClient? _gatt;
  BleGattServer? _gattServer;
  final BLEQueueService _queue = BLEQueueService();
  bool _parcelWired = false;
  bool _gattLinkUp = false; // a GATT client link is active → pause scanning
  // Auto-pair: last GATT data activity (epoch ms); an idle link is dropped so
  // the connectionless broadcast (APRS, RNS announces) resumes.
  int _gattActivityMs = 0;
  static const int _gattIdleMs = 25000;

  // Wire the parcel queue to both GATT endpoints. The single send callback
  // routes by deviceId: a peer that connected to our server is notified on
  // FFF2; a peer we connected to is written on FFF1. Reassembled inbound
  // messages are fanned out on the same stream wapps already read, so APRS (and
  // any wapp) needs no change.
  // Fallback 2s tick for platforms with no native foreground service. Named for
  // the broadcast sweep it used to drive; that sweep is gone, the tick is not.
  Timer? _dartTickTimer;

  void _setupParcelTransport() {
    if (_parcelWired || _central == null) return;
    _parcelWired = true;
    _dartTickTimer ??=
        Timer.periodic(const Duration(seconds: 2), (_) => _dartTick());
    _armServiceTick();
    _gatt = BleGattClient(_central!, onData: (from, data) {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      if (PacketGateway.instance.receive(data,
              bearer: 'ble', lane: RxLane.session, peer: from) ==
          RxVerdict.parcel) {
        _queue.onDataReceived(from, data);
      }
    }, onLinkChange: (connected) {
      _gattLinkUp = connected;
      if (connected) {
        _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
        _dbg('GATT link up (client) to ${_gatt?.peerId}');
        // The extended scan is NOT paused for a GATT link. docs/ble5.md section 4:
        // "The scan is never suspended" — pausing it was measured as the
        // difference between 10 of 10 and 0 of 10 messages delivered. The legacy
        // CentralManager discovery below is a separate scan and still yields.
        _flushPendingGatt();
        MeshSessionManager.instance.onLinkUp(serverSide: false);
      } else {
        _dbg('GATT link down (client)');
        MeshSessionManager.instance.onLinkDown(serverSide: false);
        _resumeBle5Scan(); // transfer done/failed → resume broadcast reception
      }
      _applyScan(); // pause scanning while a GATT link is up (radio contention)
    })
      ..start();
    _gattServer = BleGattServer(onData: (from, data) {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      if (PacketGateway.instance.receive(data,
              bearer: 'ble',
              lane: RxLane.session,
              peer: from,
              serverSide: true) ==
          RxVerdict.parcel) {
        _queue.onDataReceived(from, data);
      }
    }, onClientsChanged: () {
      final n = _gattServer?.clientIds.length ?? 0;
      if (n > 0) {
        _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
        // The extended scan is NOT paused for a GATT link. docs/ble5.md section 4:
        // "The scan is never suspended" — pausing it was measured as the
        // difference between 10 of 10 and 0 of 10 messages delivered. The legacy
        // CentralManager discovery below is a separate scan and still yields.
        MeshSessionManager.instance.onLinkUp(serverSide: true);
      } else {
        MeshSessionManager.instance.onLinkDown(serverSide: true);
        _resumeBle5Scan();
      }
      _dbg('GATT server clients: $n');
      _applyScan(); // pause scanning while we're serving a client (contention)
    });
    _wireMeshHooks();
    _queue.setSendCallback((deviceId, data) async {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      // Native GATT path (BLE5): route by which role holds this peer.
      if (_ngClientUp && deviceId == _ngClientPeer) {
        await Ble5Bus.instance.gattWrite(data); // our client -> peer FFF1
        return;
      }
      if (deviceId == _ngServerCentral) {
        await Ble5Bus.instance.serverNotify(data); // our server -> central FFF2
        return;
      }
      // Legacy (non-BLE5) plugin path.
      if (_gattServer?.clientIds.contains(deviceId) ?? false) {
        await _gattServer!.notify(deviceId, data); // server -> client FFF2
      } else {
        await _gatt?.writeRaw(data); // client -> peer FFF1
      }
    });
    _queue.incomingMessages.listen((m) {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      _dbg('GATT message received ${m.payload.length}B from ${m.sourceDeviceId}');
      // An RNS packet that came over the link goes to RNS, not to the wapp
      // stream. Nothing used to do this: everything arriving on GATT was handed
      // to the wapp engine, so a Reticulum packet sent point-to-point was
      // received by nobody and the sender's message simply vanished.
      final rns = _stripRnsTag(m.payload);
      if (rns != null) {
        onGattRnsFrame?.call(rns);
        return;
      }
      // A reassembled parcel is a received packet like any other. It used to
      // go to the wapp stream and NOWHERE else -- never to the funnel, never
      // to custody -- so a message that arrived over the parcel lane was
      // seen by the chat wapp's own parser or by nobody at all.
      PacketGateway.instance.receive(m.payload,
          bearer: 'ble', lane: RxLane.datagram, peer: m.sourceDeviceId);
      if (!_inbound.isClosed) {
        // arch-ignore: one-receive-door the wapp raw door closes in the next pass; see docs/message-receive.md
        _inbound.add(BleInboundFrame(m.sourceDeviceId, 0, m.payload));
      }
    });
  }

  // ── Mesh custody transport hooks (docs/mesh.md M2) ──────────────────────────
  // The MSP session layer (mesh_custody.dart) is transport-agnostic; these
  // hooks give it a send path on whichever GATT stack is live, an inbound
  // delivery tap, and a way to drop the dialed link when a session ends.
  bool _meshHooksWired = false;
  void _wireMeshHooks() {
    if (_meshHooksWired) return;
    _meshHooksWired = true;
    final hooks = MeshSessionManager.instance.hooks;
    hooks.parcelLaneBusy = () => _queue.busy;
    hooks.clientSend = (data) async {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      if (_ble5) {
        await Ble5Bus.instance.gattWrite(data);
      } else {
        await _gatt?.writeRaw(data);
      }
    };
    hooks.serverSend = (data) async {
      _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
      if (_ble5) {
        await Ble5Bus.instance.serverNotify(data);
      } else {
        final id = _gattServer?.clientIds.firstOrNull;
        if (id != null) await _gattServer!.notify(id, data);
      }
    };
    hooks.dropClientLink = () {
      if (_ble5) {
        unawaited(Ble5Bus.instance.gattDisconnect());
      } else {
        unawaited(_gatt?.disconnect() ?? Future.value());
      }
    };
    hooks.dial = meshDial;
    hooks.dialable = meshDialable;
    // Beacon sightings feed the dial registry too (the extended beacon lands
    // at fringe RSSI where the legacy presence advert is missed).
    // A beacon that published where to write to its sender: ask for a path when
    // we hold none, so the NEXT message goes direct instead of being parked for
    // store-and-carry. The transport's per-destination backoff makes this one
    // question, not a storm (RnsTransport.requestPath).
    MeshService.instance.onPeerAddress = (destHex, callsign) {
      RnsService.instance.requestPathIfUnknown(destHex);
      // The beacon named its own sender, so this destination has a callsign
      // whether or not its announce ever carried one. Record it, else the
      // messaging directory serves a nameless row and the chat rail shows the
      // first bytes of the hash instead of the station.
      RnsService.instance.noteLxmfCallsign(destHex, callsign);
    };
    // …and what we publish in our own beacon, so a neighbour can address us.
    MeshService.instance.ourLxmfDest = () => RnsService.instance.lxmfDeliveryHex;
    MeshService.instance.onPeerSighting = (callsign, addr) {
      final cs = callsign.toUpperCase();
      final my = (ProfileService.instance.activeProfile?.callsign ?? '')
          .trim()
          .toUpperCase();
      if (cs.isEmpty || cs == my) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      // A sighting proves the peer is NEARBY, not where to dial it. A node
      // legitimately answers on a different address than it beacons from (the
      // dongle beacons on its extended-advert instance and accepts connections
      // on its connectable one), and a beacon can also reach us RE-AIRED by a
      // neighbour, carrying the relayer's address under the originator's
      // callsign. Where we already know the peer answers, keep that and let the
      // sighting only refresh freshness — otherwise the peer quietly ages out of
      // the dial registry while beaconing at us every thirty seconds.
      final verified = _verifiedAddr[cs];
      if (verified != null) {
        _meshPeers[cs] = (addr: verified, ms: now);
        return;
      }
      // An address already proven to belong to somebody else means this beacon
      // was re-aired by them, not sent by its author.
      if (_verifiedAddr.entries.any((e) => e.value == addr && e.key != cs)) {
        return;
      }
      _meshPeers[cs] = (addr: addr, ms: now);
    };
    // GROUND TRUTH for who lives at an address: the peer's own MSP HELLO.
    // Without this a phone spent hours dialling its neighbour believing it was
    // the dongle, because a re-aired beacon had filed the dongle's callsign
    // against the neighbour's address — and the mail it was carrying went
    // nowhere.
    MeshSessionManager.instance.hooks.peerIdentified = (callsign, caps) {
      final addr = _ngClientPeer ?? _ngServerCentral;
      if (addr == null || callsign.isEmpty) return;
      final cs = callsign.toUpperCase();
      final now = DateTime.now().millisecondsSinceEpoch;
      final wrong = _meshPeers.entries
          .where((e) => e.value.addr == addr && e.key != cs)
          .map((e) => e.key)
          .toList();
      for (final k in wrong) {
        _meshPeers.remove(k);
        LogService.instance.add(
            'Mesh: $addr is $cs, not $k — dropped the bad dial address');
      }
      _meshPeers[cs] = (addr: addr, ms: now);
      _verifiedAddr[cs] = addr;
      // What this station said it can do, kept past the end of the session so
      // the NEXT 1:1 to it can go point to point instead of to the whole
      // street. In memory only, same lifetime as _verifiedAddr — a stale
      // capability claim would be worse than no claim at all.
      if (_peerCaps.length > 64 && !_peerCaps.containsKey(cs)) {
        _peerCaps.remove(_peerCaps.keys.first);
      }
      _peerCaps[cs] = caps;
    };
    MeshSessionManager.instance.hooks.canTakeCustody = meshCanTakeCustody;
    MeshSessionManager.instance.hooks.dialWorth = meshDialWorth;
    MeshTransferScheduler.instance.start();
  }

  /// Addresses proven to belong to a callsign — by an MSP HELLO on a live link,
  /// or by the peer's own connectable presence advert (nothing re-airs that).
  /// A beacon sighting never overwrites one of these.
  final Map<String, String> _verifiedAddr = {};

  // Callsign → (BLE address, last-seen ms) registry from the native discovery
  // scan, so the mesh scheduler can dial a SPECIFIC peer (the old single
  // _lastPeerAddr slot only ever remembered the most recent one).
  final Map<String, ({String addr, int ms})> _meshPeers = {};
  static const int _meshPeerFreshMs = 150000; // ~2.5 min (a few scan gaps)

  /// Callsign → the `MspCaps` bitmask from that peer's last MSP HELLO. Only a
  /// completed HELLO writes here, so a key existing also proves the peer is
  /// CONNECTABLE — the address a beacon sighting files is the extended-advert
  /// MAC, which is deliberately not connectable (`Ble5.kt` setConnectable
  /// false); only the legacy presence advert and a live link give a dialable
  /// one.
  final Map<String, int> _peerCaps = {};

  /// Can [callsign] be handed a 1:1 over a session right now, rather than
  /// aired? See `MeshCustodyDelegate.pointToPointOk` for why it is asked this
  /// way and not from a device class.
  bool meshCanTakeCustody(String callsign) {
    final cs = callsign.toUpperCase();
    final p = _meshPeers[cs];
    final fresh = p != null &&
        DateTime.now().millisecondsSinceEpoch - p.ms < _meshPeerFreshMs;
    return MeshCustodyDelegate.pointToPointOk(
        dialableNow: fresh, peerCaps: _peerCaps[cs] ?? 0);
  }

  /// Is a 1:1 to [callsign] worth starting a session for right now? Fresh,
  /// on an address that can actually be dialled (a beacon MAC cannot), and
  /// not a peer that has said it does not take custody. See
  /// `MeshCustodyDelegate.worthDialing`.
  bool meshDialWorth(String callsign) {
    final cs = callsign.toUpperCase();
    final p = _meshPeers[cs];
    if (p == null) return false;
    final fresh =
        DateTime.now().millisecondsSinceEpoch - p.ms < _meshPeerFreshMs;
    final dialable = MeshCustodyDelegate.undialableReason(
            callsign: cs, addr: p.addr, verifiedAddr: _verifiedAddr[cs]) ==
        null;
    return MeshCustodyDelegate.worthDialing(
        dialableNow: fresh && dialable,
        capsKnown: _peerCaps.containsKey(cs),
        peerCaps: _peerCaps[cs] ?? 0);
  }

  /// Every callsign we have a capability record for: what it declared, and
  /// whether a 1:1 to it would go point to point right now. Diagnostic only.
  Map<String, dynamic> custodyStatus() => {
        for (final e in _peerCaps.entries)
          e.key: {
            'caps': '0x${e.value.toRadixString(16)}',
            'msgCustody': (e.value & MspCaps.msgCustody) != 0,
            'dialable': _meshPeers.containsKey(e.key),
            'direct': meshCanTakeCustody(e.key),
          }
      };

  /// Peers the mesh can currently dial: callsign → freshness.
  ///
  /// A peer is only listed once its address is VERIFIED — heard from its own
  /// connectable presence advert, or proven by an MSP HELLO. A beacon sighting
  /// files the extended-advert MAC, which is deliberately not connectable
  /// (`Ble5.kt` setConnectable false), so publishing it here sent the scheduler
  /// into a 30 s GATT_CONNECTION_TIMEOUT(147) followed by a silent backoff,
  /// forever, on a peer that was never reachable at that address.
  Map<String, int> meshDialable() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _meshPeers.removeWhere((_, v) => now - v.ms > _meshPeerFreshMs);
    return {
      for (final e in _meshPeers.entries)
        if (MeshCustodyDelegate.undialableReason(
              callsign: e.key,
              addr: e.value.addr,
              verifiedAddr: _verifiedAddr[e.key],
            ) ==
            null)
          e.key: now - e.value.ms,
    };
  }

  /// Peers seen recently whose address is not dialable, and why — for the
  /// diagnostics. Empty here while beacons keep arriving means the legacy
  /// discovery scan is not hearing anyone's connectable advert.
  Map<String, String> meshUndialable() {
    final out = <String, String>{};
    for (final e in _meshPeers.entries) {
      final why = MeshCustodyDelegate.undialableReason(
        callsign: e.key,
        addr: e.value.addr,
        verifiedAddr: _verifiedAddr[e.key],
      );
      if (why != null) out[e.key] = why;
    }
    return out;
  }

  /// Dial [callsign] for a mesh custody session. Returns false when the peer
  /// hasn't been seen recently, the radio is busy, or GATT is unavailable.
  bool meshDial(String callsign) {
    final cs = callsign.toUpperCase();
    final p = _meshPeers[cs];
    final now = DateTime.now().millisecondsSinceEpoch;
    // SAY WHY. Every one of these used to be a bare `return false`, and the
    // scheduler answers a bare false by arming a backoff — so a peer that
    // could never be dialled looked exactly like a peer that was busy, and a
    // payload waiting for a link that is never attempted is indistinguishable
    // from one that was sent. Same reason _maybeAutoPair reports its refusals.
    String? no;
    if (!_ble5) {
      no = 'not a BLE5 device';
    } else if (_ngClientUp || _ngServerCentral != null) {
      no = 'radio busy (${_ngClientUp ? "client link up" : "serving a central"})';
    } else if (p == null) {
      no = 'never seen';
    } else if (now - p.ms > _meshPeerFreshMs) {
      no = 'last seen ${(now - p.ms) ~/ 1000}s ago';
    } else {
      no = MeshCustodyDelegate.undialableReason(
        callsign: cs,
        addr: p.addr,
        verifiedAddr: _verifiedAddr[cs],
      );
    }
    if (no != null) {
      _noteDialRefusal(cs, no);
      return false;
    }
    final peer = p!;
    _ngClientPeer = peer.addr;
    // Freshly-seen peer (seconds) = in solid range: use the fast DIRECT
    // connect. Stale sighting = fringe: background (auto) connect waits at
    // controller level for an ADV_IND the direct window would miss.
    final fringe = now - peer.ms > 10000;
    _dbg('mesh dial: GATT connect to $cs (${peer.addr}) '
        '${fringe ? "auto" : "direct"}');
    _dialRefusals.remove(cs);
    Ble5Bus.instance.gattConnect(peer.addr, auto: fringe);
    return true;
  }

  /// Report a dial refusal once, and again only when the reason changes or ten
  /// minutes pass — the scheduler retries every tick and this must not become
  /// the log.
  final Map<String, ({String why, int ms})> _dialRefusals = {};

  void _noteDialRefusal(String cs, String why) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _dialRefusals[cs];
    if (last != null && last.why == why && now - last.ms < 600000) return;
    _dialRefusals[cs] = (why: why, ms: now);
    LogService.instance.add('Mesh: not dialling $cs — $why');
  }

  /// All peers currently reachable over the parcel transport (server clients +
  /// the peer we are a client of).
  List<String> _connectedPeers() {
    final ids = <String>{...?_gattServer?.clientIds};
    final p = _gatt?.peerId;
    if (p != null) ids.add(p);
    if (_ngClientUp && _ngClientPeer != null) ids.add(_ngClientPeer!);
    if (_ngServerCentral != null) ids.add(_ngServerCentral!);
    return ids.toList();
  }

  // Scanning (ref-counted).
  int _scanRefs = 0;
  bool _scanning = false;
  String _lastWarn = '';
  int _lastWarnMs = 0;

  void _warnThrottled(String msg) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (msg == _lastWarn && now - _lastWarnMs < 10000) return;
    _lastWarn = msg;
    _lastWarnMs = now;
    debugPrint('BleService: $msg');
  }

  Future<void> _ensure() async {
    if (_inited) return;
    _inited = true;
    try {
      _central = CentralManager();
      try {
        // Bounded: on Android authorize() can stall (it routes through
        // ActivityCompat.requestPermissions); the perms are requested up front
        // in the onboarding panel, so don't let a stalled call block scanning.
        await _central!.authorize().timeout(const Duration(seconds: 3),
            onTimeout: () => true);
      } catch (_) {}
      // Permanent discovered subscription; frames only flow while scanning.
      _central!.stateChanged.listen((_) => _applyScan());
      _setupParcelTransport();
      // Re-arm the scan when the app returns to the foreground: Android may stop
      // a scan while we were paused (screen off) without notifying us, leaving
      // _scanning true so _applyScan would never restart it. The lifecycle hook
      // forces a fresh discovery so reception resumes.
      try {
        _lifecycle ??= _BleLifecycleObserver(this);
        WidgetsBinding.instance.addObserver(_lifecycle!);
      } catch (_) {}
    } catch (e) {
      _central = null;
      debugPrint('BleService: central unavailable: $e');
    }
    // Advertising backend.
    if (_useBlePeripheral) {
      // NOT initialised here. ble_peripheral's GATT server callback calls
      // device.createBond() on EVERY unbonded central that connects
      // (BlePeripheralPlugin.kt, onConnectionStateChange), and Android hands a
      // server connection event to every GATT server registration in the
      // process — including this one, for a central that dialled our NATIVE
      // server. Merely initialising the plugin was therefore enough to raise a
      // system pairing dialog on both phones the moment a BLE5 link formed,
      // which is precisely what this transport must never do.
      //
      // Advertising now happens ONLY through the BLE5 extended bus (or, for
      // presence, the native GATT endpoint), so nothing here initialises it.
      _advertiseSupported = true;
    } else {
      _advertiseSupported = false; // no advertise backend on this platform
      debugPrint('BleService: advertising unavailable (scan-only)');
    }
    await _initBle5();
  }

  // Detect BLE5 support once and, if present, wire the shared bus so APRS
  // broadcast uses single extended adverts instead of legacy chunking.
  Future<void> _initBle5() async {
    if (_ble5Checked) return;
    _ble5Checked = true;
    try {
      _ble5 = await Ble5Bus.instance.supported();
    } catch (_) {
      _ble5 = false;
    }
    if (!_ble5Probe.isCompleted) _ble5Probe.complete();
    if (_ble5 && !_ble5Wired) {
      _ble5Wired = true;
      // Surface scan self-healing events in the app log (the bus watchdog
      // re-registers a scan that a vendor power manager silently killed).
      Ble5Bus.instance.onLog = (m) => LogService.instance.add(m);
      Ble5Bus.instance.onFrame(Ble5Subtype.aprs, _onBle5Aprs);
      // GATT large-file transfer runs ENTIRELY native on BLE5 devices: a single
      // coordinated stack (native GATT server + client + legacy connectable advert
      // + legacy discovery scan) with plain/unencrypted characteristics — no
      // pairing, and no dual-plugin handle-cache confusion. BLE5 extended
      // advertising carries only the connectionless broadcast (APRS + RNS).
      Ble5Bus.instance
        ..onAdvertFailed = _onAdvertRefused
        ..onAdapterRestarted = _onAdapterRestarted
        ..onGattConnected = _onNgConnected
        ..onGattDisconnected = _onNgDisconnected
        ..onGattData = _onNgClientData
        ..onGattDiscovered = _onNgDiscovered
        ..onGattServerData = _onNgServerData
        ..onGattServerConnected = _onNgServerConnected
        ..onGattServerDisconnected = _onNgServerDisconnected
        ..startGattEvents();
      _dbg('BLE5 broadcast + native GATT enabled');
      _armGattEndpoint();
    }
    // Street-mesh node (docs/mesh.md): rides the same BLE5 bus on its own
    // subtype. Non-BLE5 devices still start it as a scan-only leaf so the
    // Bluetooth wapp has a live (if empty) registry + self status.
    //
    // WAIT FOR THE PROBE FIRST. `_ble5` is answered asynchronously by
    // `_initBle5`, and starting before it lands passes `canAdvertise: false` —
    // which made the mesh a scan-only leaf for the WHOLE session, on a device
    // whose radio was perfectly able to transmit. Seen on C61 after a boot:
    // `advertising False, xprsSent 1`, no beacon for anyone to hear, while the
    // native layer was creating advertising sets and RNS traffic flowed over
    // the same bus. Nothing raised it afterwards, so the device stayed mute
    // until it was restarted and won the race by luck.
    unawaited(_ble5Probe.future
        .timeout(const Duration(seconds: 10), onTimeout: () {})
        .whenComplete(
            () => MeshService.instance.start(canAdvertise: _ble5)));
    // WiFi-Direct coordinator: negotiates a fast P2P data plane over this same
    // BLE bus (subtype 0x57) when a bulk transfer wants a BLE-adjacent peer.
    // Android-only + self-gating (no-op where WiFi Direct is unsupported).
    unawaited(WifiDirectCoordinator.instance.start());
    RnsService.instance.onWantFastPath =
        (dest) => WifiDirectCoordinator.instance.ensureFastPath(dest);
  }

  // ── Is this radio actually transmitting and hearing? ──────────────────────
  //
  // Queuing an advert says nothing about whether the controller aired it, and a
  // scan that returns nothing looks exactly like an empty room. A tablet sat
  // for hours reporting "advertising: true, beacons sent: 40" while its stack
  // held no advertising set and its scans returned zero results — the app had
  // no way to tell, and neither did we. These two make the difference visible.

  int _advertRefusals = 0;
  String? _advertLastError;
  bool _legacyFallback = false;

  void _onAdvertRefused(int status) {
    _advertRefusals++;
    _advertLastError = 'startAdvertisingSet status=$status';
    LogService.instance.add(
        'BLE5: controller refused the advert (status=$status) — '
        'falling back to the legacy advert');
    // BLE5 extended advertising is refused outright on some chips/ROMs. The
    // legacy chunked broadcast still works there (it drives its own rotation),
    // so route new ADVERTS down that path.
    //
    // What must NOT happen — and did — is clearing [_ble5] wholesale. That flag
    // also selects the GATT client: with it false the code dials through the
    // bluetooth_low_energy plugin instead of the native stack, and THAT is what
    // raised a system pairing dialog on both phones. The advert path and the
    // point-to-point path are separate decisions; a controller that refuses an
    // oversized advert is still perfectly able to carry a plain, pairing-free
    // GATT link.
    if (!_legacyFallback) {
      _legacyFallback = true;
      _advertLegacy = true;
      // The mesh beacons on the same refused set — tell it, so it stops
      // counting refused beacons as sent and reports itself scan-only.
      MeshService.instance.setCanAdvertise(false);
    }
  }

  /// The Bluetooth stack was replaced underneath us (a crash-restart, or off
  /// and on). Native has rebuilt the advertising set and the scan; what is
  /// left to do is say so, and put this station's beacon back on the air now
  /// rather than at the next 30 s tick — a neighbour that lost us for a night
  /// should not wait another half minute.
  void _onAdapterRestarted(int restarts) {
    _adapterRestarts = restarts;
    LogService.instance.add(
        'BLE5: Bluetooth stack restarted (#$restarts) — advertising set and '
        'scan rebuilt');
    MeshService.instance.reannounce();
  }

  int _adapterRestarts = 0;

  /// Adverts have fallen back to the legacy 31-byte path. Separate from
  /// [_ble5], which governs the GATT stack — see [_onAdvertRefused].
  bool _advertLegacy = false;

  /// Extended adverts are usable: BLE5 is up AND nothing has refused one.
  bool get _ble5Adverts => _ble5 && !_advertLegacy;

  /// Everything the radio can tell us about being heard and hearing, straight
  /// from the native side (attempts, refusals, scan results, on-air state).
  Future<Map<String, dynamic>> radioStatus() async {
    final native = await Ble5Bus.instance.radioStatus();
    return {
      ...native,
      'legacyFallback': _legacyFallback,
      'advertRefusals': _advertRefusals,
      if (_advertLastError != null) 'advertLastError': _advertLastError,
      'locationServicesOn':
          await AndroidPermissionsService.instance.locationServicesOn(),
    };
  }

  // ── Native GATT event handlers (BLE5) ─────────────────────────────────────
  void _onNgConnected() {
    _ngClientUp = true;
    _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
    _dbg('native GATT client link up to $_ngClientPeer');
    _applyScanTier(); // a link in flight is never scanned around slowly
    // Extended scan stays up: docs/ble5.md section 4, "The scan is never
    // suspended". Stopping it here is what left the phone deaf — Ble5Bus.stopScan
    // tore down the EventChannel subscription, the native sink went null, and
    // nothing re-armed it because both resume paths were gated on _scanRefs.
    _applyScan();
    _flushPendingGatt();
    _wireMeshHooks();
    if (GattPeer.callsign.isNotEmpty) {
      // An explicit station dial (firmware push, 1:1 to a board). Stations
      // do not speak MSP: starting a session here meant an unanswered HELLO,
      // a 5 s timeout, and the link dropped under the transfer. The link
      // carries raw XPRS wires and XBLOB frames instead.
      _dbg('station link to ${GattPeer.callsign} — no MSP session');
    } else {
      MeshSessionManager.instance
          .onLinkUp(serverSide: false, mtu: Ble5Bus.instance.clientMtu);
    }
  }

  void _onNgDisconnected() {
    XblobService.instance.onLinkDown();
    GattPeer.callsign = '';
    _dbg('native GATT client link down ($_ngClientPeer)');
    _applyScanTier();
    _ngClientUp = false;
    _ngClientPeer = null;
    MeshSessionManager.instance.onLinkDown(serverSide: false);
    if (_ngServerCentral == null) _resumeBle5Scan();
    _applyScan();
  }

  void _onNgClientData(Uint8List data) {
    _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
    final peer = _ngClientPeer ?? 'gatt';
    if (PacketGateway.instance.receive(data,
            bearer: 'ble', lane: RxLane.session, peer: peer) ==
        RxVerdict.parcel) {
      _queue.onDataReceived(peer, data);
    }
  }

  void _onNgDiscovered(String address, String callsign) {
    if (address.isEmpty) return;
    final myCall = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    if (callsign.isNotEmpty && callsign == myCall) return; // ourselves
    _lastPeerAddr = address;
    _lastPeerCall = callsign;
    _lastPeerMs = DateTime.now().millisecondsSinceEpoch;
    if (callsign.isNotEmpty) {
      final cs = callsign.toUpperCase();
      // A connectable presence advert comes from the device itself — nothing
      // re-airs it — so it proves the address, same as a session HELLO.
      _verifiedAddr[cs] = address;
      _meshPeers[cs] =
          (addr: address, ms: _lastPeerMs); // mesh scheduler dial registry
    }
    _maybeAutoPair();
  }

  int _ngServerRxCount = 0;
  void _onNgServerData(String address, Uint8List data) {
    _ngServerCentral = address;
    _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
    _dbg('native server rx #${++_ngServerRxCount} ${data.length}B from $address');
    if (PacketGateway.instance.receive(data,
            bearer: 'ble',
            lane: RxLane.session,
            peer: address,
            serverSide: true) ==
        RxVerdict.parcel) {
      _queue.onDataReceived(address, data);
    }
  }

  void _onNgServerConnected(String address) {
    _ngServerCentral = address;
    _gattActivityMs = DateTime.now().millisecondsSinceEpoch;
    _dbg('native GATT server: central $address connected');
    // Extended scan stays up: docs/ble5.md section 4, "The scan is never
    // suspended". Stopping it here is what left the phone deaf — Ble5Bus.stopScan
    // tore down the EventChannel subscription, the native sink went null, and
    // nothing re-armed it because both resume paths were gated on _scanRefs.
    _applyScan();
    _wireMeshHooks();
    _flushPendingGatt(); // a peer dialling US is just as good a route
    final smtu = Ble5Bus.instance.serverMtu;
    MeshSessionManager.instance
        .onLinkUp(serverSide: true, mtu: smtu > 23 ? smtu : 512);
  }

  void _onNgServerDisconnected(String address) {
    if (_ngServerCentral == address) _ngServerCentral = null;
    _dbg('native GATT server: central $address disconnected');
    MeshSessionManager.instance.onLinkDown(serverSide: true);
    if (!_ngClientUp) _resumeBle5Scan();
    _applyScan();
  }

  // One inbound single-frame APRS broadcast over BLE5. Dedup by payload hash
  // (the sender re-airs the same bytes for its TTL) and deliver once to wapps.
  // Inbound accounting, drained once a minute by _rxSummaryTick.
  int _rxAprsFrames = 0;
  int _rxAprsBytes = 0;
  int _rxSummaryTickMs = 0;

  /// One line a minute describing what the radio actually heard, and where the
  /// adverts that did not make it through went. The composition is the
  /// diagnosis: rxNoSink separates "deaf" from "empty room", which is the
  /// distinction this whole path lacked.
  void _rxSummaryTick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_rxSummaryTickMs == 0) _rxSummaryTickMs = now;
    if (now - _rxSummaryTickMs < 60000) return;
    _rxSummaryTickMs = now;
    final r = _radioSnapshot;
    final frames = _rxAprsFrames;
    final bytes = _rxAprsBytes;
    _rxAprsFrames = 0;
    _rxAprsBytes = 0;
    if (frames == 0 && (r['rxEmitted'] as int? ?? 0) == 0 &&
        (r['scanResults'] as int? ?? 0) == 0) {
      return; // nothing heard and nothing to say — don't spend a ring line
    }
    LogService.instance.add(
      'perf: ble5-rx aprs=$frames/${bytes}B emitted=${r['rxEmitted']} '
      'adverts=${r['scanResults']} noSink=${r['rxNoSink']} '
      'marker=${r['rxMarker']} dedup=${r['rxDedup']} '
      'scanning=${r['scanning']}',
    );
  }

  void _onBle5Aprs(Ble5Frame f) {
    if (f.data.isEmpty || _inbound.isClosed) return;
    final key = _hashHex(f.data);
    final now = DateTime.now();
    final seen = _ble5Seen[key];
    if (seen != null && now.difference(seen) < kBleBcastDedup) return;
    _ble5Seen[key] = now;
    MeshService.instance.noteChannelActivity(); // politeness load meter
    // Counted always, logged per frame only under ble.debug. This line was
    // written when the receive path was dead, so "once per unique frame" was
    // zero lines an hour; with the scan actually up near a few stations it is a
    // firehose into a 2000-line ring (docs/performance.md section 3.3). The
    // per-minute summary in _rxSummaryTick carries the same proof.
    _rxAprsFrames++;
    _rxAprsBytes += f.data.length;
    _dbg('BLE5 rx aprs ${f.data.length}B rssi=${f.rssi}');
    // ONE OWNER PER FORM. An XPRS packet goes to the funnel, whatever subtype
    // it arrived on; the legacy compact frame goes to the custody tap, which is
    // the only thing that understands it.
    //
    // Both used to run for every frame, so an XPRS message addressed to us and
    // heard on 0x41 was processed twice: two `heard()` passes (two monitor
    // sightings, gossip fired twice), and `deliverXprs` ran twice — re-doing a
    // signature verify and a sealed-body unseal, two curve operations, before
    // the duplicate was caught. The funnel now does the parking too
    // (`XprsIngest.onCarry`), so the tap has nothing left to add for XPRS.
    PacketGateway.instance.receive(f.data,
        bearer: 'ble', lane: RxLane.advert, peer: f.addr, rssi: f.rssi);
    // arch-ignore: one-receive-door the wapp raw door closes in the next pass; see docs/message-receive.md
    _inbound.add(BleInboundFrame(f.addr, f.rssi, f.data));
  }

  // Verbose BLE transport diagnostics — emitted only when the "BLE debug"
  // setting is on, and routed to LogService so they show in the in-app log and
  // /api/log (not just adb logcat).
  void _dbg(String msg) {
    if (PreferencesService.instanceSync?.bleDebug ?? false) {
      debugPrint('BleService: $msg');
      LogService.instance.add('BLE: $msg');
    }
  }

  // Short stable hex hash of a payload (FNV-1a 32-bit) for dedup / advert keys.
  static String _hashHex(Uint8List b) {
    var h = 0x811c9dc5;
    for (final x in b) {
      h ^= x;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  /// Auto-pair: when we have a large payload waiting (and no link yet), open a
  /// GATT link to the most recently discovered XPRS peer with NO manual
  /// pairing. The SENDER (the side with data) initiates; the receiver stays a
  /// passive server, so the two don't both connect. On-demand only — when
  /// nothing is queued we stay in broadcast mode, and [_bcastTick] drops the
  /// link once the transfer idles. Called both on discovery and when data queues.
  void _maybeAutoPair() {
    if (!(PreferencesService.instanceSync?.bleAutoPair ?? true)) return;
    if (_pendingGatt.isEmpty) return;                         // nothing to send
    final fresh =
        DateTime.now().millisecondsSinceEpoch - _lastPeerMs <= _peerFreshMs;
    if (_ble5) {
      // Native connect path: dial the most-recently discovered peer's address
      // (from the native legacy discovery scan). The SENDER (side with data)
      // dials; the receiver stays a passive native server. Plain characteristics
      // = no pairing. Already serving a central → don't also dial (tie-breaker).
      if (_ngClientUp || _ngServerCentral != null) return;
      if (!fresh || _lastPeerAddr.isEmpty) {
        // Say why the link did not form. A payload waiting for a peer that is
        // never dialled is indistinguishable from one that was sent, and that
        // is how "delivered" messages went missing.
        LogService.instance.add(
            'BLE: ${_pendingGatt.length} payload(s) waiting — no peer to dial '
            '(${_lastPeerAddr.isEmpty ? "none discovered" : "last seen too long ago"})');
        return;
      }
      _ngClientPeer = _lastPeerAddr;
      _dbg('auto-pair: native GATT connect to $_lastPeerCall ($_lastPeerAddr) '
          'for ${_pendingGatt.length} payload(s)');
      Ble5Bus.instance.gattConnect(_lastPeerAddr);
      return;
    }
    // Nothing else can dial: the only non-BLE5 peer source was the legacy
    // company-frame scan, and it is gone. A device without BLE5 has no XPRS
    // BLE lane at all — see the header note.
  }

  // Resume the shared BLE5 extended scan after a GATT connect/transfer ends.
  void _resumeBle5Scan() {
    // NOT gated on _scanRefs. That counter belongs to the legacy CentralManager
    // discovery, which wapps take and release; the BLE5 broadcast lane is core —
    // it carries the mesh, Reticulum and every XPRS beacon, and it is not a
    // wapp-owned resource. Gating it here meant that once the refs hit zero (a
    // wapp engine restarting is enough) the extended scan could never come back.
    if (_ble5) unawaited(Ble5Bus.instance.startScan());
  }

  /// Periodic broadcast housekeeping: prune the dedup table and drop GATT links
  /// that have gone idle, so the radio returns to the connectionless lane.
  void _bcastTick() {
    // Prune the BLE5 single-frame dedup table.
    if (_ble5Seen.isNotEmpty) {
      final now = DateTime.now();
      _ble5Seen.removeWhere((_, t) => now.difference(t) > kBleBcastDedup);
    }
    // Drop an idle auto-paired GATT link so the radio returns to the
    // connectionless broadcast (APRS + RNS announces) when no transfer is active.
    // Only the CLIENT side disconnects (the dialer); the server lets the central
    // leave. On BLE5 this is the native client link.
    final linkUp = _ngClientUp || (_gatt?.isConnected ?? false);
    if (linkUp && _gattActivityMs > 0) {
      final idle = DateTime.now().millisecondsSinceEpoch - _gattActivityMs;
      if (idle > _gattIdleMs) {
        _dbg('GATT idle ${idle ~/ 1000}s — disconnecting to resume broadcast');
        if (_ngClientUp) {
          unawaited(Ble5Bus.instance.gattDisconnect());
        } else {
          unawaited(_gatt!.disconnect());
        }
      }
    }
    // A central that connected to OUR server and then went quiet used to keep
    // the scan off indefinitely: we only ever dropped the link we dialled
    // ourselves, never one someone else opened. A phone sat deaf for minutes —
    // hearing no beacons, no announces, nobody — because of an idle connection
    // it did not initiate. Serving a transfer is worth the radio; sitting on an
    // idle link is not.
    final servingIdle = (_ngServerCentral != null ||
            (_gattServer?.clientIds.isNotEmpty ?? false)) &&
        _gattActivityMs > 0 &&
        DateTime.now().millisecondsSinceEpoch - _gattActivityMs > _gattIdleMs;
    if (servingIdle && !_ngClientUp) {
      _resumeBle5Scan();
      unawaited(_applyScan());
    }
  }

  // ── Kept alive by the service, not by the UI ────────────────────────────
  //
  // Every timer in this file belongs to the Flutter isolate, and Android stops
  // giving that isolate CPU when the app is not on screen: with the phone in
  // doze a 2-second Timer fires when it feels like it, and the sweep that
  // re-arms a dead scan or drains a pending payload simply stops happening.
  // The native foreground service ticks on its own thread every 2 s regardless,
  // so the same work is driven from there and the Dart timer stays as a
  // fallback for the platforms that have no such service.
  bool _serviceTickArmed = false;
  int _lastServiceTickMs = 0;

  void _armServiceTick() {
    if (_serviceTickArmed || !Platform.isAndroid) return;
    _serviceTickArmed = true;
    AndroidForegroundService.instance.addTickListener(_onServiceTick);
  }

  void _onServiceTick() {
    _lastServiceTickMs = DateTime.now().millisecondsSinceEpoch;
    _bcastTick();
    _scanWatchdog();
    _gattEndpointWatchdog();
    _refreshRadioSnapshot();
    _rxSummaryTick();
  }

  /// The native radio counters, refreshed on the 2 s tick and cached.
  ///
  /// gattStatus() is synchronous and has many callers, and radioStatus() is a
  /// platform-channel round trip — so the snapshot is pulled here, on a tick
  /// that already exists, and read from the cache. docs/ble5.md section 6 has
  /// claimed these were surfaced for a long time; they were not, and that is
  /// why a deaf radio and an empty room looked identical.
  Map<String, dynamic> _radioSnapshot = const {};
  bool _radioSnapshotBusy = false;

  void _refreshRadioSnapshot() {
    if (!_ble5 || _radioSnapshotBusy) return;
    _radioSnapshotBusy = true;
    unawaited(Ble5Bus.instance.radioStatus().then((m) {
      _radioSnapshot = m;
    }).catchError((_) {}).whenComplete(() {
      _radioSnapshotBusy = false;
    }));
  }

  /// The Dart fallback: skipped while the service tick is doing the work, so a
  /// foreground device isn't running both.
  void _dartTick() {
    final age = DateTime.now().millisecondsSinceEpoch - _lastServiceTickMs;
    if (_lastServiceTickMs != 0 && age < 6000) return;
    _bcastTick();
    _scanWatchdog();
    _gattEndpointWatchdog();
    _refreshRadioSnapshot();
    _rxSummaryTick();
  }

  /// Re-arm anything the system stopped behind our back. Android kills a long
  /// BLE scan without telling the app — the callback stays registered and no
  /// result ever arrives again — and a device that stops scanning stops hearing
  /// its neighbour entirely.
  void _scanWatchdog() {
    // The BLE5 scan is re-armed unconditionally — see _resumeBle5Scan for why
    // _scanRefs must not gate it. This runs off the native BgService heartbeat
    // (_onServiceTick), so it keeps healing with the screen off.
    if (_ble5) unawaited(Ble5Bus.instance.startScan()); // no-op when already on
    // The legacy discovery scan IS ref-counted: nobody asked for it, nobody
    // pays for it.
    if (_scanRefs > 0 && _central != null && !_scanning) unawaited(_applyScan());
  }

  /// Bring up (and keep up) the native GATT endpoint: server + legacy
  /// connectable advert + legacy discovery scan, all three from one call.
  ///
  /// CORE, deliberately NOT gated on `_scanRefs` — same reason `_scanWatchdog`
  /// is not. This used to be reachable only from [startScan], whose only
  /// production caller is a wapp's `hal_ble_scan_start`, and whose
  /// `_central == null` early return skipped it even then. A phone whose chat
  /// wapp had Bluetooth off aired only the NON-connectable extended set: no
  /// registered GATT server, no connectable advert, no discovery scan, so
  /// nothing could dial it and it learned no dialable address for anyone else.
  /// Measured on C61 while TANK2, on the same build with the wapp running, had
  /// all three. The 1:1 custody lane is a transport, so it comes up with the
  /// transport.
  ///
  /// Idempotent on both sides — the native server is created once and kept,
  /// and the advert is not restarted while healthy (a restart rotates the
  /// address, docs/ble5.md section 2) — so this is safe to call on a tick.
  void _armGattEndpoint() {
    if (!_ble5) return;
    final cs = ProfileService.instance.activeProfile?.callsign ?? '';
    unawaited(Ble5Bus.instance.startServer(cs.isEmpty ? 'AURORA' : cs));
  }

  int _lastGattArmMs = 0;

  /// Re-arm the endpoint on the heartbeat. Paced at 30 s: the native call is a
  /// no-op when nothing is wrong, but it is still a platform-channel round
  /// trip and the tick runs every 2 s.
  void _gattEndpointWatchdog() {
    if (!_ble5) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastGattArmMs < 30000) return;
    _lastGattArmMs = now;
    _armGattEndpoint();
  }

  /// Hold the foreground service for as long as BLE is in use, so the radio
  /// keeps running with the app off screen. Ref-counted with every other
  /// holder (the Reticulum node, background wapps), so releasing ours does not
  /// stop a service somebody else still needs.
  Future<void> _holdService() async {
    if (!Platform.isAndroid || _serviceHeld) return;
    _serviceHeld = true;
    try {
      await AndroidForegroundService.instance.hold('ble');
    } catch (_) {}
  }

  Future<void> _releaseService() async {
    if (!_serviceHeld) return;
    _serviceHeld = false;
    try {
      await AndroidForegroundService.instance.release('ble');
    } catch (_) {}
  }

  bool _serviceHeld = false;

  // ── scan duty cycle by power tier ────────────────────────────────────────
  //
  // The scan is NEVER stopped for power (docs/ble5.md 4: stopping it during a
  // GATT link measured 10-of-10 down to 0-of-10). What changes is how wide the
  // window between looks is: BALANCED while somebody is looking or the phone
  // is on a charger, LOW_POWER on battery with the screen off, where the
  // courier re-transmits and store-and-forward absorb the slower hearing
  // (docs/mesh.md 2).
  //
  // Two safeguards. Delivery in flight — a GATT link up, or any PowerState
  // hold — keeps BALANCED regardless of tier. And the mode is only ever
  // applied on a tier CHANGE (PowerState holds a one-minute dwell), because
  // changing it restarts the scan and Android throttles an app to about five
  // scan starts per thirty seconds.
  static const int _scanModeLowPower = 0;
  static const int _scanModeBalanced = 1;
  int _appliedScanMode = _scanModeBalanced;
  bool _scanTierArmed = false;

  void _armScanTier() {
    if (_scanTierArmed || !Platform.isAndroid || !_ble5) return;
    _scanTierArmed = true;
    PowerState.instance.tier.addListener(_applyScanTier);
    _applyScanTier();
  }

  void _applyScanTier() {
    if (!_ble5) return;
    final saving = PowerState.instance.isBackgroundSaving &&
        !PowerState.instance.hasActiveHold &&
        !gattLinkUp;
    final want = saving ? _scanModeLowPower : _scanModeBalanced;
    if (want == _appliedScanMode) return;
    _appliedScanMode = want;
    debugPrint('BLE5: scan mode -> ${want == _scanModeLowPower ? 'low-power' : 'balanced'} '
        '(tier ${PowerState.instance.tier.value.name})');
    LogService.instance.add(
      'BLE5: scan mode ${want == _scanModeLowPower ? 'low-power' : 'balanced'} '
      '(tier ${PowerState.instance.tier.value.name})',
    );
    unawaited(Ble5Bus.instance.setScanMode(want));
  }

  Future<bool> startScan() async {
    await _ensure();
    await _holdService();
    _armServiceTick();
    _armScanTier();
    // Start the shared BLE5 extended scan (also feeds Reticulum). Independent of
    // the legacy _central scan, which still runs for legacy/ESP32 peers.
    if (_ble5) await Ble5Bus.instance.startScan();
    if (_central == null) return _ble5; // BLE5-only is still usable
    _scanRefs++;
    // The adapter may not report poweredOn immediately after init (Android
    // reads state asynchronously); wait briefly so the first scan isn't lost.
    await _awaitPoweredOn();
    await _applyScan();
    // Become a connectable peer for large-file GATT transfer. On BLE5 the entire
    // endpoint is NATIVE: one coordinated GATT server + legacy connectable advert
    // + legacy discovery scan (avoids the dual-plugin handle-cache confusion that
    // dropped writes and broke notify). On non-BLE5 devices, fall back to the
    // ble_peripheral server + a legacy connectable presence beacon. No-op on
    // Linux/BlueZ.
    final cs = ProfileService.instance.activeProfile?.callsign ?? '';
    if (_ble5) {
      // On BLE5 this is already up from _initBle5 and healed on the tick
      // (_armGattEndpoint); the call is idempotent and kept here so a wapp
      // asking for a scan does not have to wait for the next heartbeat.
      _armGattEndpoint();
    } else if (_gattServer?.isRunning != true) {
      unawaited(_gattServer?.start(cs, advertise: true) ?? Future<void>.value());
    }
    return true;
  }

  Future<void> _awaitPoweredOn() async {
    final c = _central;
    if (c == null) return;
    for (var i = 0; i < 20; i++) {
      if (c.state == BluetoothLowEnergyState.poweredOn) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> stopScan() async {
    if (_scanRefs > 0) _scanRefs--;
    await _applyScan();
    if (_scanRefs == 0) await _releaseService();
  }

  // Called on app resume: if we still want to scan, force a fresh discovery in
  // case Android quietly stopped it while we were paused (our _scanning flag
  // would otherwise stay true and _applyScan would never restart it).
  Future<void> _reArmScan() async {
    if (_scanRefs <= 0 || _central == null) return;
    if (_scanning) {
      try { await _central!.stopDiscovery(); } catch (_) {}
      _scanning = false;
    }
    await _applyScan();
  }

  Future<void> _applyScan() async {
    final c = _central;
    if (c == null) return;
    // Pause scanning while any GATT link is up (we are a client of a peer, OR a
    // peer is connected to our server) — scan and connection contend on a single
    // radio and the link drops otherwise. This is what kept the phone<->desktop
    // link from holding (the serving side kept scanning).
    // Serving a peer earns the radio only while the transfer is ALIVE. An idle
    // central that stays connected must not keep us deaf — see _bcastTick.
    final serving = (_gattServer?.clientIds.isNotEmpty ?? false) ||
        _ngServerCentral != null;
    final serverBusy = serving &&
        (_gattActivityMs == 0 ||
            DateTime.now().millisecondsSinceEpoch - _gattActivityMs <=
                _gattIdleMs);
    final want =
        _scanRefs > 0 && !_gattLinkUp && !_ngClientUp && !serverBusy;
    try {
      if (want && !_scanning && c.state == BluetoothLowEnergyState.poweredOn) {
        await c.startDiscovery();
        _scanning = true;
      } else if (!want && _scanning) {
        await c.stopDiscovery();
        _scanning = false;
      }
    } catch (e) {
      debugPrint('BleService: scan toggle failed: $e');
    }
  }

  // ── Outbound advertising ──────────────────────────────────────────
  // BLE here is receive-first: a node listens (scans) continuously and only
  // transmits a frame as a brief burst when it actually has something to send.
  // Peers are listening, so a short burst is enough; we don't hold the radio
  // advertising indefinitely.
  // enqueueWappAdvert is GONE, with the hal_ble_advertise that called it.
  //
  // It took bytes a wapp handed over and SNIFFED them to choose the subtype:
  //
  //     final isXprs = XprsPacket.parse(...) != null;
  //     enqueueAdvert(payload, subtype: isXprs ? xprs : aprs);
  //
  // which is exactly the guess `enqueueAdvert`'s required `subtype:` exists to
  // prevent -- its own comment says a default "is what let both happen
  // quietly" -- reintroduced one call later with a parse in place of a
  // constant. A wapp does not put bytes on this radio now: it says what it
  // wants said, and the core composes the packet and names its own subtype.

  /// Air [payload] under [subtype], routing by size.
  ///
  /// The subtype is REQUIRED and has no default. It used to be hardcoded to
  /// `aprs`, which meant every caller aired under a byte that says "compact
  /// APRS frame" whatever it was actually sending. That has now cost the same
  /// bug twice: Reticulum packets were aired under it and "received by
  /// nobody" (see [sendOverGatt]), and the custody re-air put XPRS wires on
  /// it, where a station's `on_ble` drops them on its first line because the
  /// subtype is not `0x58`. A default is what let both happen quietly, so
  /// there is no default.
  void enqueueAdvert(Object owner, Uint8List payload,
      {required int subtype, Duration ttl = const Duration(seconds: 10)}) {
    _ensure();
    // Size router. SMALL → connectionless one-to-many broadcast (one sender,
    // many listeners, aired ONCE, never per-peer). LARGE → point-to-point GATT
    // (a binary file / RNS resource), which auto-pairs a transient link.
    // The BLE5 cap is THIS controller's real advert ceiling (many chips carry
    // only ~247 B, far under the 450 B spec-side default) — an over-cap frame
    // is rejected by the stack, not truncated, so it must go GATT instead.
    final smallCap = _ble5Adverts ? Ble5Bus.instance.maxPayload : kBleBcastMax;
    // Mesh custody tap on our own outbound 1:1s: parked in-transit so the
    // GATT plane also owes delivery. BEFORE the size router — encrypted 1:1s
    // exceed the advert cap and never reach the broadcast path at all.
    //
    // It answers true for the one case where the street should not pay: a 1:1
    // to an Android we hear ourselves, both ways, right now. That message is
    // handed over the session lane instead, and aired after all if the lane has
    // not delivered it in two minutes (MeshCustodyDelegate.sweepSuppressed).
    if (MeshCustodyDelegate.onAirFrame(payload, outbound: true)) return;
    if (payload.length > smallCap) {
      _gattSend(payload);
      return;
    }
    // BLE5 path (preferred): a whole APRS message fits ONE extended advert, so
    // register it as a single frame on the shared bus (no chunking, no NACK).
    // Keyed by payload hash so the wapp's periodic re-advertise refreshes it.
    if (_ble5Adverts) {
      final key = '${subtype.toRadixString(16)}:${_hashHex(payload)}';
      final keys = _ble5Keys.putIfAbsent(owner, () => <String>{});
      final fresh = keys.add(key);
      if (keys.length > 64) keys.remove(keys.first);
      if (fresh) _dbg('BLE5 advert ${payload.length}B key=$key');
      // HONOUR the answer. A frame the controller refuses is aired nowhere;
      // ignoring the return left the app broadcasting into nothing, with
      // `ble5` still true, for the rest of the process. A refusal means this
      // payload does not fit the medium — send it the way an over-cap payload
      // is meant to go.
      unawaited(Ble5Bus.instance
          .advertiseFrame(key, subtype, payload, ttl: ttl)
          .then((aired) {
        if (aired) return;
        LogService.instance.add(
            'BLE5: ${payload.length}B refused by the controller '
            '(cap ${Ble5Bus.instance.maxPayload}B) — routing point-to-point');
        _gattSend(payload);
      }));
      return;
    }
    // No BLE5, no broadcast. The legacy 0x50 chunk dialect that used to run
    // here is retired: every station drops a subtype that is not 0x58 on the
    // first line of `on_ble`, and `_enqueueBroadcast` did not even carry the
    // subtype — it aired an XPRS wire under no type byte at all, to nobody.
    // Say so rather than broadcasting into nothing, which is the exact fault
    // this file records twice already.
    _warnThrottled('advert dropped: no BLE5 extended advertising on this '
        'device, and the legacy chunk dialect is retired');
  }

  // Large payloads await a GATT link; auto-pair opens one on the next discovered
  // peer, then [_flushPendingGatt] sends them. Bounded so a peer that never
  // appears can't grow this unbounded.
  final List<Uint8List> _pendingGatt = [];
  // Most recently discovered connectable XPRS peer. Android dedups scan
  // results (a peer is reported once, then suppressed), so we remember the last
  // one and dial it when data is queued — not only on a fresh discovery event.
  String _lastPeerCall = '';
  String _lastPeerAddr = ''; // BLE MAC for the native connect path (from beacon)
  int _lastPeerMs = 0;
  static const int _peerFreshMs = 60000;
  // Native GATT (BLE5 devices): the whole transfer endpoint is native — server +
  // client + legacy connectable advert + legacy discovery scan, one coordinated
  // stack. _ngClientPeer is the address we dialed; _ngServerCentral is the
  // address of a central connected to our server.
  bool _ngClientUp = false;
  String? _ngClientPeer;
  String? _ngServerCentral;

  /// Marks a GATT payload as a Reticulum packet rather than a wapp parcel.
  /// Two bytes: unlikely as a parcel prefix, and cheap on a link this narrow.
  static const List<int> _rnsGattTag = [0xA7, 0x52];

  /// Handler for Reticulum packets that arrive over the GATT link. Set by the
  /// RNS radio; without it those packets are dropped rather than misdelivered.
  void Function(Uint8List frame)? onGattRnsFrame;

  Uint8List? _stripRnsTag(Uint8List data) {
    if (data.length <= _rnsGattTag.length) return null;
    for (var i = 0; i < _rnsGattTag.length; i++) {
      if (data[i] != _rnsGattTag[i]) return null;
    }
    return Uint8List.sublistView(data, _rnsGattTag.length);
  }

  /// Send [payload] over the GATT link, or queue it until one exists.
  ///
  /// This is the entry point for anything that is NOT an APRS advert — the RNS
  /// radio in particular. Routing RNS through [enqueueAdvert] aired it under the
  /// APRS subtype, which the peer's RNS handler never reads, so every packet
  /// that took that path was received by nobody.
  void sendOverGatt(Uint8List payload) {
    _ensure();
    final tagged = Uint8List(_rnsGattTag.length + payload.length)
      ..setAll(0, _rnsGattTag)
      ..setAll(_rnsGattTag.length, payload);
    _gattSend(tagged);
  }

  /// True when a GATT link is up in either role — we dialled a peer, or a peer
  /// dialled us. The RNS radio asks before deciding whether an over-cap packet
  /// can rely on the point-to-point route alone.
  bool get gattLinkUp => _connectedPeers().isNotEmpty;

  /// Send a large payload point-to-point over GATT. If a link is up, enqueue it
  /// to the connected peer(s); otherwise stash it and let auto-pair open a link.
  void _gattSend(Uint8List payload) {
    // A connected peer is not necessarily a PARCEL peer: the MSP-only dongle
    // holds a link during custody sessions and never receipts a parcel. The
    // queue learns which addresses are parcel-deaf; sending to one anyway
    // burned the whole retry ladder per message and kept the radio busy.
    final peers =
        _connectedPeers().where((p) => !_queue.isParcelDeaf(p)).toList();
    if (peers.isNotEmpty) {
      for (final id in peers) {
        _queue.enqueue(BLEOutgoingMessage(payload: payload, targetDeviceId: id));
      }
      LogService.instance
          .add('BLE: ${payload.length}B -> GATT, ${peers.length} peer(s)');
      return;
    }
    _pendingGatt.add(payload);
    if (_pendingGatt.length > 16) {
      _pendingGatt.removeAt(0);
      LogService.instance.add(
          'BLE: queue full — dropped the oldest pending payload');
    }
    LogService.instance.add('BLE: ${payload.length}B queued for a GATT link '
        '(${_pendingGatt.length} waiting)');
    _maybeAutoPair(); // dial the last-seen peer now (Android won't re-report it)
  }

  final Object _testOwner = Object();

  /// GATT auto-pair status (for diagnostics / the remote API).
  Map<String, dynamic> gattStatus() => {
        'autoPair': PreferencesService.instanceSync?.bleAutoPair ?? true,
        'ble5': _ble5,
        'native': _ble5,
        'clientLinkUp': _ngClientUp || (_gatt?.isConnected ?? false),
        'clientPeer': _ngClientPeer ?? _gatt?.peerId,
        'serverClients': _ngServerCentral != null
            ? [_ngServerCentral!]
            : (_gattServer?.clientIds.toList() ?? <String>[]),
        'pendingGatt': _pendingGatt.length,
        'lastPeer': _lastPeerAddr.isEmpty ? null : _lastPeerAddr,
        'idleMs': _gattActivityMs == 0
            ? null
            : DateTime.now().millisecondsSinceEpoch - _gattActivityMs,
        'legacyFallback': _legacyFallback,
        'advertRefusals': _advertRefusals,
        if (_advertLastError != null) 'advertLastError': _advertLastError,
        // What the radio can actually carry, one request away instead of a
        // stack dump away. The whole BLE story turned on this number.
        'maxPayload': _ble5Adverts ? Ble5Bus.instance.maxPayload : kBleBcastMax,
        // Reception, from the radio itself. rxNoSink > 0 means adverts arrived
        // and Dart was not listening; scanning=false with wantScan=true means
        // the native scan is refusing to register. Without these two the only
        // symptom of either is "nothing ever arrives".
        ..._radioSnapshot,
        'scanRefs': _scanRefs,
        'wantScan': Ble5Bus.instance.wantScan,
        'busScanning': Ble5Bus.instance.scanning,
        'msSinceLastFrame': Ble5Bus.instance.msSinceLastFrame,
        'advertLegacy': _advertLegacy,
        'adapterRestartsSeen': _adapterRestarts,
        'advertFailures': Ble5Bus.instance.advertFailures,
        if (Ble5Bus.instance.advertLastError != null)
          'busLastError': Ble5Bus.instance.advertLastError,
      };

  /// Test helper: send [size] bytes point-to-point over GATT. Larger than the
  /// broadcast cap, so it routes through the auto-pairing GATT path.
  void gattSendTest(int size) {
    final n = size < 1 ? 1 : (size > 8192 ? 8192 : size);
    final blob = Uint8List(n);
    for (var i = 0; i < n; i++) {
      blob[i] = 0x41 + (i % 26); // A..Z filler
    }
    _dbg('gattSendTest: ${n}B');
    enqueueAdvert(_testOwner, blob,
        subtype: Ble5Subtype.aprs, ttl: const Duration(seconds: 30));
  }

  /// Flush stashed large payloads to the freshly-connected peer.
  void _flushPendingGatt() {
    if (_pendingGatt.isEmpty) return;
    // EITHER role delivers. This used to look only at the link WE dialled, so a
    // message queued on a device that a peer then dialled sat in this list for
    // ever — silently, while the two phones held a perfectly good link. The
    // send callback already routes by role (client → peer's FFF1, server →
    // notify the central), so any connected peer will do.
    final peer = [
      if (_ngClientUp && _ngClientPeer != null) _ngClientPeer!,
      if (_ngServerCentral != null) _ngServerCentral!,
      if (_gatt?.peerId != null) _gatt!.peerId!,
      ...?_gattServer?.clientIds,
    ].where((p) => !_queue.isParcelDeaf(p)).firstOrNull;
    if (peer == null) return;
    for (final p in _pendingGatt) {
      _queue.enqueue(BLEOutgoingMessage(payload: p, targetDeviceId: peer));
    }
    LogService.instance.add(
        'BLE: flushed ${_pendingGatt.length} queued payload(s) to $peer');
    _pendingGatt.clear();
  }

  void clearAdverts(Object owner) {
    // Drop this owner's BLE5 broadcast frames from the shared bus.
    final ble5Keys = _ble5Keys.remove(owner);
    if (ble5Keys != null) {
      for (final k in ble5Keys) {
        Ble5Bus.instance.removeFrame(k);
      }
    }
  }

  /// Completes when [_initBle5] has answered whether this device does BLE5.
  final Completer<void> _ble5Probe = Completer<void>();
}

/// Re-arms the BLE scan when the app returns to the foreground. Android can
/// silently stop a scan while the app is paused (screen off); this forces a
/// fresh discovery on resume so reception recovers without a manual toggle.
class _BleLifecycleObserver extends WidgetsBindingObserver {
  _BleLifecycleObserver(this._svc);
  final BleService _svc;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ignore: invalid_use_of_protected_member, unawaited_futures
      _svc._reArmScan();
    }
  }
}
