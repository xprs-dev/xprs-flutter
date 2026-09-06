/*
 * mesh_service — the BLE street-mesh node (docs/mesh.md, milestone M1).
 *
 * Owns the mesh control plane: builds and airs this node's route beacon on
 * the shared BLE5 extended-advert bus (subtype 0x4D) and ingests neighbors'
 * beacons into the distance-vector table. M1 scope: see the street — no data
 * plane yet (custody transfer/SCF land in M2, politeness/scoring in M3).
 *
 * Beacon cadence: a fixed base interval, plus one early "triggered update"
 * (debounced) when the table reports a topology change, so 2-hop routes
 * converge in seconds instead of a full beacon period. Scan-only devices
 * (no extended advertising, e.g. C61) run everything except the transmit —
 * they are leaves: they see the street but the street can't route via them.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';

import '../../connections/bluetooth/ble5_bus.dart';
import '../../profile/profile_service.dart';
import '../../profile/storage_paths.dart';
import '../../util/media_archive.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import '../xprs/xprs_airtime.dart';
import '../xprs/xprs_archive.dart';
import '../xprs/xprs_groups.dart';
import '../xprs/xprs_catchup.dart';
import '../xprs/xprs_files.dart';
import '../xprs/xprs_history_server.dart';
import '../xprs/xprs_ingest.dart';
import '../xprs/xprs_gossip.dart';
import '../xprs/xprs_group_keys.dart';
import '../xprs/xprs_publisher.dart';
import '../xprs/xprs_outbox.dart';
import '../xprs/xprs_receipt.dart';
import '../xprs/xprs_bridge.dart';
import '../xprs/xprs_digipeat.dart';
import '../xprs/xprs_forwarder.dart';
import '../../util/nostr_crypto.dart';
import 'mesh_transfer_scheduler.dart';
import '../xprs/xprs_lan.dart';
import '../xprs/xprs_monitor.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_sig.dart';
import '../receive/core_state.dart';
import '../receive/packet_gateway.dart';
import '../xprs/xprs_vocab.dart';
import 'mesh_beacon.dart';
import 'mesh_courier.dart';
import 'mesh_custody.dart';
import 'mesh_frame.dart';
import 'mesh_bulk_spool.dart';
import 'mesh_store.dart';
import 'mesh_table.dart';

class MeshService {
  MeshService._();
  static final MeshService instance = MeshService._();

  // Politeness (docs/mesh.md §7): the beacon interval adapts to channel
  // load — quiet streets get chatty beacons, saturated streets get
  // presence-only whispers. _beaconInterval is the quiet-street floor.
  static const Duration _beaconInterval = Duration(seconds: 30);
  static const Duration _beaconTtl = Duration(seconds: 70);
  static const Duration _triggerDebounce = Duration(seconds: 4);

  final DateTime _startedAt = DateTime.now();
  final Battery _battery = Battery();

  // `lifetime:` (docs/XPRS.md section 10.5): cumulative service seconds saved
  // by every PREVIOUS run; the current figure is this plus the uptime. Loaded
  // once (a re-entrant start() must not fold the running uptime back into the
  // base, or the total double-counts), saved from the sweep timer.
  int _lifeBaseSec = -1;

  MeshTable? _table;
  bool _canAdvertise = false;
  bool _running = false;
  Timer? _beaconTimer;
  Timer? _lanBeaconTimer;
  Timer? _sweepTimer;
  Timer? _triggerTimer;
  bool _powered = false;
  int _batteryPct = 100;
  int _beaconsSent = 0, _beaconsHeard = 0;

  // Channel-load meter: BLE5 frames heard in a sliding minute (fed by
  // BleService for every inbound frame, any subtype). Drives politeness.
  final List<DateTime> _heardStamps = [];

  /// Called by the transport for every inbound BLE5 frame.
  void noteChannelActivity() {
    final now = DateTime.now();
    _heardStamps.add(now);
    if (_heardStamps.length > 600) _heardStamps.removeRange(0, 100);
  }

  /// Frames/second heard over the last minute.
  double channelLoad() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    _heardStamps.removeWhere((t) => t.isBefore(cutoff));
    return _heardStamps.length / 60.0;
  }

  /// Politeness tier: 0 quiet, 1 busy, 2 saturated (docs/mesh.md §7).
  /// Powered nodes back off LAST (they are the useful chatter).
  int politenessTier() {
    final load = channelLoad();
    final saturated = _powered ? 5.0 : 3.0;
    final busy = _powered ? 2.0 : 1.0;
    if (load >= saturated) return 2;
    if (load >= busy) return 1;
    return 0;
  }

  /// Effective beacon interval for the current tier.
  Duration beaconIntervalNow() => switch (politenessTier()) {
        2 => const Duration(minutes: 5),
        1 => const Duration(seconds: 90),
        _ => _beaconInterval,
      };

  /// Battery dial policy: on low battery (and not charging) the node stops
  /// PULLING work for others; its own outbound mail still moves.
  bool dialBudgetLow() => !_powered && _batteryPct < 20;

  bool get isRunning => _running;

  /// Bump-on-change revision so UI layers can cheaply poll for updates.
  int revision = 0;

  /// Set by BleService: a beacon sighting reports that this peer is NEARBY.
  ///
  /// It does NOT report where to dial it, and the claim that it did — "a GATT
  /// connect needs only the address" — was wrong. The address a beacon carries
  /// is the extended advertising set's MAC, and that set is deliberately
  /// non-connectable (`Ble5.kt`), so a connect to it ends in
  /// `GATT_CONNECTION_TIMEOUT(147)` thirty seconds later. Only the peer's own
  /// connectable presence advert or a completed MSP HELLO gives a dialable
  /// address; see `BleService._verifiedAddr` and
  /// `MeshCustodyDelegate.undialableReason`.
  void Function(String callsign, String addr)? onPeerSighting;

  /// The live table (null before start). M2 custody reads routes/neighbors.
  MeshTable? get table => _table;

  /// Our mesh identity ('' before the profile loads).
  String get tableCallsign => _table?.selfCallsign ?? '';

  /// Start the mesh node. Idempotent; safe to call again when the profile
  /// (callsign) changes — the table is rebuilt for the new identity.
  Timer? _startRetry;

  Future<void> start({required bool canAdvertise}) async {
    final cs = (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    if (cs.isEmpty) {
      // BLE can come up before the profile finishes loading on slow devices —
      // a silent no-op here would leave the mesh dead for the whole session.
      _startRetry ??= Timer(const Duration(seconds: 10), () {
        _startRetry = null;
        // ignore: discarded_futures
        start(canAdvertise: canAdvertise);
      });
      return;
    }
    if (_running && _table?.selfCallsign == cs) {
      // Only ever RAISE this on a repeat start: a later caller that knows less
      // (the BLE5 probe had not answered when it ran) must not mute a node that
      // is already transmitting.
      if (canAdvertise && !_canAdvertise) setCanAdvertise(true);
      return;
    }
    _table = MeshTable(cs);
    // The Reticulum receive lane tests "addressed to us" against
    // XprsArchive.selfCallsign (xprs_ingest.dart reticulum()). Set it HERE, the
    // instant the callsign is known — NOT only in the prefs/try block below.
    // Otherwise a 1:1 arriving over Reticulum during init (or when prefs is
    // null, or if MeshStore.init throws before the cascade) sees an empty self,
    // is misrouted as a third-party carry, and is refused with
    // "rns refused (no declaration)". The cascade below re-sets the same value.
    XprsArchive.instance.selfCallsign = cs;
    _canAdvertise = canAdvertise;
    _running = true;

    // The custody store lives beside the other cross-wapp state
    // (…/data/mesh.sqlite3) and re-opens when the profile changes.
    final prefs = PreferencesService.instanceSync;
    // The owner's standing answer on carrying for other people (default yes).
    if (prefs != null) {
      MeshStore.instance.carryForOthers = prefs.meshCarryForOthers;
    }
    if (prefs != null && _lifeBaseSec < 0) _lifeBaseSec = prefs.meshLifetimeSec;
    if (prefs != null) {
      try {
        MeshStore.instance
            .init(wappsDataStorage(prefs).getAbsolutePath('mesh.sqlite3'));
        MeshStore.instance.sweep();
        // The heard-traffic spool (docs/XPRS.md sections 24 and 31.3) lives
        // beside the custody store and re-opens with it on profile change.
        // Its key resolver is wired by RnsService, which owns the keys.
        XprsArchive.instance
          ..selfCallsign = cs
          ..maxBytes = prefs.xprsArchiveMaxMb * 1024 * 1024
          ..maxAgeDays = prefs.xprsArchiveMaxDays
          // The spool is the only thing that checks a signature, and it does it
          // off the receive path where that work belongs. The air view badges a
          // station from ITS verdict rather than repeating the curve work on
          // the isolate that draws.
          ..onVerdict = XprsMonitor.instance.recordVerdict
          ..init(wappsDataStorage(prefs)
              .getAbsolutePath('xprs_archive.sqlite3'));
        // A key binding lives in memory and a `t:identity` is re-announced only
        // every thirty minutes (18.1), so a restart used to leave this station
        // unable to seal a private message (9.2) or check a signature for up to
        // half an hour -- while the archive it just opened already held the
        // announcements that say so. Replay them; they are signed, so the
        // binding is re-derived rather than trusted, and no airtime is spent.
        XprsIngest.rebindFromArchive();
        // And the same for closed groups: keys first (above), then the acts
        // those keys check. A roster lives in memory, so without this every
        // group a station belongs to disappears on restart (26.4).
        final acts = XprsArchive.instance
            .query(types: const ['moderate'], limit: 512)
            .map((r) => r['wire'])
            .whereType<String>()
            .toList()
            .reversed
            .toList();
        final n = XprsGroups.instance.hydrate(acts);
        if (n > 0) LogService.instance.add('XPRS: replayed $n group act(s)');
        XprsHistoryServer.instance.install();
        XprsGossip.instance
            .init(wappsDataStorage(prefs).getAbsolutePath('xprs_gossip.sqlite3'));
        // The groups this station ADMINISTERS -- their private keys (26.1).
        // Profile-scoped and re-opened on profile change like the others, and
        // encrypted for the same reason the profile's own nsec is: 26.6 says a
        // leaked group key is permanent and cannot be rotated, because the
        // callsign derives from it.
        XprsGroupKeys.instance.init(
            wappsDataStorage(prefs).getAbsolutePath('xprs_groups.sqlite3'));
        if (prefs.xprsSuperArchiver) {
          // The super budget (36.9.4): the table stops being pocket-sized.
          XprsGossip.instance.maxBytes = 256 * 1024 * 1024;
        }
        // 36.8.1: deliver the moment the recipient is heard. The funnel
        // reports every direct hearing; this receiver throttles per
        // callsign, checks for held mail, and fires the right lane --
        // the session scheduler for BLE peers, a verbatim re-air for
        // bearers with no session (LAN, rns).
        XprsIngest.onDirectHeard = _onDirectHeard;
        // Mail for a third party off the rns lane: park it exactly as the
        // radio lanes do (custody, 36.7), then let 36.8.1 move it toward
        // the recipient's declared mailbox or freshest gossip gateway.
        XprsIngest.onCarry = (wire, target) {
          MeshCustodyDelegate.onAirFrame(
              Uint8List.fromList(utf8.encode(wire)),
              outbound: false);
          unawaited(XprsForwarder.instance.maybeForward(target, wire,
              selfBase: NostrCrypto.bareCallsign(tableCallsign)));
        };
        // Two handlers want t:result: the history poller and the file fetch.
        // Chained rather than replaced — the hook is a single slot, and a
        // second assignment would silently unhook the first.
        // A verified receipt ends custody — here and on every other holder
        // that hears it (§13.7.1, §36.8.1). Before this nothing composed or
        // consumed one, so a parked row had no terminal state and the store
        // grew to its quota: measured at 1739 parked, 0 purged, 0 delivered.
        XprsIngest.onReceipt = (p) {
          final r = XprsReceipt.release(p, selfCallsign: tableCallsign);
          if (r == null) return; // unverifiable changes nothing (13.7.1)
          final id = r.id;
          final n = MeshStore.instance.purgeAm(id);
          if (n > 0) {
            XprsReceiptCounters.released += n;
            MeshCustodyCounters.purged += n;
            LogService.instance.add(
                'Mesh: receipt from ${p['f']} released $n held copy of $id');
          }
          // Remember it even when we held nothing: a copy that reaches us
          // AFTER the receipt must not be parked all over again.
          MeshStore.instance.recordReceivedAm(id);

          // AND TELL WHOEVER SENT IT. Releasing custody is only half of what
          // a receipt is for: the other half is the sender learning that the
          // message arrived, and being able to stop retrying it. Until now a
          // verified receipt purged a store row and stopped, so the tick a
          // person sees was asserted by the wapp rather than reported by the
          // core (docs/message-receive.md section 10).
          XprsOutbox.instance.noteReceipt(id,
              state: r.state, peer: (p['f'] ?? '').trim().toUpperCase());
        };
        // A reachability test answers on the lane it arrived on (§36.0: the
        // packet that just came over it is the freshest evidence of a working
        // path back). The funnel composes and signs; airing is the publisher's.
        // The bridge shares the digipeater's §13 decision and its one way onto
        // a bearer, so a relayed packet is decided and aired in one place
        // whichever of the two carried it.
        XprsBridge.instance.relayable = _relayable;
        XprsBridge.instance.air = airOnLane;
        XprsIngest.onAnswerPing = (wire, bearer) {
          unawaited(XprsPublisher.instance
              .publishWire(wire, verbatim: true, prefer: bearer));
        };
        XprsIngest.onResult = (p) {
          XprsCatchup.instance.onResult(p);
          XprsFileFetch.instance.onResult(p);
        };
        // The catch-up watermark moves when a row is WRITTEN, not when it is
        // queued — see XprsArchive.onStored.
        XprsArchive.instance.onStored = XprsCatchup.instance.noteRow;
        // A message addressed to us, heard on ANY bearer, goes to the courier
        // for verification, unsealing and delivery to the inbox. Before this
        // the only route ran through the BLE 0x41 custody tap, so anything a
        // station replayed on 0x58 — which is every history replay — was
        // archived and never seen again.
        XprsIngest.onDeliver = (p, bearer) {
          // Where a partial page stopped: a `206` continuation asks for what
          // came BEFORE the oldest record the station managed to send.
          final tsMs = xprsParseTs(p['ts']);
          if (tsMs != null) {
            XprsCatchup.instance.noteReplay(p['f'] ?? '', tsMs);
          }
          // This IS the funnel's delivery hook (XprsIngest.onDeliver): the
          // packet has already come through the door to get here.
          // arch-ignore: one-receive-door this is the funnel's own delivery hook
          MeshCourier.instance.deliverXprs(MeshFrame.fromXprs(p), via: bearer);
        };
        // Poll every station in reach once a minute, off the native heartbeat
        // so it survives a pocket (docs/performance.md section 8.2).
        XprsCatchup.instance.start(cs);
        MeshBulkSpool.instance.init(
            wappsDataStorage(prefs).getAbsolutePath('mesh/bulk'),
            MediaArchive.forDirectory(
                wappsDataStorage(prefs).getAbsolutePath('')));
        MeshBulkSpool.instance.sweep();
        // The XPRS bracket around the bulk lane (section 25.2.2): the closing
        // `code:200` is aired from the sender's FILE_OK, and a requester's
        // wait ends when the bytes land and verify on this side.
        MeshBulkSpool.instance.onOriginHandedOver =
            XprsFileServer.instance.noteHandedOver;
        MeshBulkSpool.instance.onInboundComplete =
            XprsFileFetch.instance.noteInboundComplete;
        MeshBulkSpool.instance.inboundClaim =
            XprsFileFetch.instance.claimInbound;
        MeshBulkSpool.instance.selfCallsign = () => tableCallsign;
      } catch (e) {
        LogService.instance.add('Mesh: store init failed: $e');
      }
    }

    Ble5Bus.instance.onFrame(Ble5Subtype.mesh, _onFrame);
    Ble5Bus.instance.onFrame(Ble5Subtype.xprs, _onXprsFrame);
    // What to do with a packet once the funnel has seen it -- repeating and
    // beacon reading -- for every bearer, not just this radio.
    PacketGateway.onXprsPacket = _onXprsHeard;
    // Leaves listen too: extended SCANNING is a separate controller capability
    // from extended advertising, so a phone that can't beacon (e.g. C61) may
    // still hear the street. Idempotent; harmless where unsupported.
    // Bounded: these calls hop to the native BLE worker thread, and an await
    // that never returns leaves the mesh unstarted, silent, and with no log
    // line to say so. Timing out here still leaves the node running — the scan
    // is re-armed by the service watchdog anyway.
    try {
      await Ble5Bus.instance
          .startScan()
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    } catch (_) {}

    // The LAN bearer (docs/lan.md): UDP 4242, broadcast, and the only bearer a
    // desktop has. Deliberately NOT gated on `canAdvertise`, which is a
    // statement about the BLE radio — a machine that cannot beacon over
    // Bluetooth is on the wire like everything else in the building.
    unawaited(XprsLan.instance.start(selfCallsign: cs));
    _lanBeaconTimer?.cancel();
    // 300 s, matching the dongle's LAN cadence, first after 20 s — long enough
    // for an interface to have an address worth broadcasting from.
    _lanBeaconTimer = Timer(const Duration(seconds: 20), () {
      _sendXprsLanBeacon();
      _lanBeaconTimer =
          Timer.periodic(const Duration(seconds: 300), (_) => _sendXprsLanBeacon());
    });

    _beaconTimer?.cancel();
    // Adaptive cadence: a fixed 10 s tick decides whether the politeness
    // interval has elapsed (the interval itself moves with channel load).
    var lastBeacon = DateTime.fromMillisecondsSinceEpoch(0);
    _beaconTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (DateTime.now().difference(lastBeacon) >= beaconIntervalNow()) {
        lastBeacon = DateTime.now();
        _sendBeacon();
      }
    });
    _sweepTimer?.cancel();
    var sweepTick = 0;
    _sweepTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_table?.sweep() ?? false) revision++;
      if (++sweepTick % 10 == 0) {
        MeshStore.instance.sweep(); // TTL + quota
        MeshBulkSpool.instance.sweep();
      }
      // lifetime: accumulate service time every 15 min (section 10.5). A kill
      // loses at most that tail, same trade the dongle makes with its NVS.
      if (sweepTick % 15 == 0 && _lifeBaseSec >= 0) {
        PreferencesService.instanceSync?.meshLifetimeSec =
            _lifeBaseSec + DateTime.now().difference(_startedAt).inSeconds;
      }
    });

    // Track power state for the cond byte (desktops report `unknown` = mains).
    try {
      final st = await _battery.batteryState;
      _powered = st != BatteryState.discharging;
      _batteryPct = await _battery.batteryLevel;
      _battery.onBatteryStateChanged.listen((st) async {
        _powered = st != BatteryState.discharging;
        try {
          _batteryPct = await _battery.batteryLevel;
        } catch (_) {}
      });
    } catch (_) {
      _powered = true; // no battery API → assume powered (desktop)
    }

    try {
      await _sendBeacon().timeout(const Duration(seconds: 5), onTimeout: () {});
    } catch (_) {}
    LogService.instance.add(
        'Mesh: started as $cs (${_canAdvertise ? "relay-capable" : "scan-only leaf"})');
  }

  /// An XPRS frame on subtype `0x58` — a discovery beacon, or carried mail.
  ///
  /// Only the beacon is handled here. Mail addressed to us is already picked up
  /// by [MeshCustodyDelegate.onAirFrame] on the transport's inbound path, which
  /// is where custody decisions belong.
  void _onXprsFrame(Ble5Frame f) {
    // The radio's whole job: hand the bytes over with a label. Parsing,
    // the funnel and everything after it are the gateway's.
    PacketGateway.instance.receive(f.data,
        bearer: 'ble', lane: RxLane.advert, peer: f.addr, rssi: f.rssi);
  }

  /// What this station does with an XPRS packet once the funnel has seen it:
  /// repeat it (§13.1) and read it as a beacon. Registered on
  /// [PacketGateway.onXprsPacket] so it runs for a packet heard on ANY
  /// bearer, not only the one radio that used to call it directly.
  void _onXprsHeard(
      XprsPacket p, String bearer, String peer, int rssi, String wire) {
    final t = _table;
    if (t == null) return;
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty || from == t.selfCallsign.toUpperCase()) return;

    // 13.1: "repeats a packet on the medium it heard it". BLE is the one
    // bearer where not doing so leaves stations unreachable outright — two
    // phones out of range of each other have no other path — so unlike the
    // wired bearers this is on by default. Every hearing goes in, duplicates
    // included, because 13.2.1's cancel is driven by hearing the packet
    // again while our own copy waits.
    // Two different jobs, and the bearer is what separates them: repeat it on
    // the medium it came from (§13.1), and carry it to the media it has not
    // been on. Until `heard` took a bearer, only a degenerate version of the
    // first was possible.
    digipeater.heard(p, wire, bearer);
    XprsBridge.instance.heard(p, wire, bearer);

    // The rest of this is beacon handling, and only a beacon is a beacon.
    if (p.type != 'observation') return;
    _xprsBeaconsHeard++;
    // A reading without `link:` is unanswerable and discarded (section 10.6.1);
    // one about another bearer is not evidence about this radio.
    if (!xprsReadingIsScoped(p) || p['link'] != 'ble') return;

    final peers = xprsPeers(p);
    final heard = (p['hears'] ?? '')
        .split(',')
        .where((c) => c.isNotEmpty)
        .toList();
    LogService.instance.add(
        'Mesh: XPRS beacon from $from ($rssi dBm) — '
        '${heard.length} of ${peers ?? heard.length} peers listed');
    // The sender is by definition directly heard, so this is a sighting like
    // any other: it registers the address for dialling -- unless the packet
    // carries `via:`, in which case the address we heard it from is the
    // RELAYER's and the author may be nowhere near. Filing it under the
    // author's callsign is how the C61 spent a session believing X1VCVM lived
    // at X1WATT's address ("dropped the bad dial address" is the HELLO
    // correcting it, one dial too late).
    if ((p['via'] ?? '').trim().isEmpty) onPeerSighting?.call(from, peer);

    // `lx:` says where to write to this station (section 10.6). Hearing it is
    // not the same as being able to address it: that needs a Reticulum path,
    // which carries the peer's key and comes from an announce. So when we hold
    // no path, ask for one — ONCE, through the transport's per-destination
    // backoff, which turns this into a single question rather than a storm. The
    // peer answers with its announce and the next message goes direct instead of
    // being parked for store-and-carry.
    // The beacon states BOTH who is speaking and where to write to them, so it
    // is the one place that pairing is free and authoritative. Pass the callsign
    // along with the address: without it the host knows an LXMF destination it
    // cannot name, and every UI built on the directory falls back to showing
    // raw hex where a callsign belongs.
    final lx = p['lx'];
    if (lx != null && lx.length == 32) onPeerAddress?.call(lx, from);
  }

  /// A neighbour published its LXMF delivery address in a beacon and we hold no
  /// path to it. The owner turns this into a (throttled) path request, and
  /// records [callsign] as the name for [destHex].
  void Function(String destHex, String callsign)? onPeerAddress;

  /// This station's own LXMF delivery destination, for the beacon's `lx:`.
  /// Supplied by the owner — the mesh does not reach into Reticulum itself
  /// (docs/architecture.md: the transports own their own layer).
  String? Function()? ourLxmfDest;

  int _xprsBeaconsHeard = 0;

  /// XPRS discovery beacons heard from other stations.
  int get xprsBeaconsHeard => _xprsBeaconsHeard;

  void _onFrame(Ble5Frame f) {
    final t = _table;
    if (t == null) return;
    final b = MeshBeacon.decode(f.data);
    if (b == null) return;
    _beaconsHeard++;
    final isNew = !t.neighbors.containsKey(b.callsign);
    final changed = t.ingest(b, rssi: f.rssi);
    // Only when the table actually moved. A beacon that says nothing new is
    // the common case -- they repeat on a cadence -- and republishing on every
    // one would be the 2-second poll it replaces, with extra steps.
    if (changed || isNew) CoreState.instance.changed(CoreState.meshTopology);
    if (isNew && t.neighbors.containsKey(b.callsign)) {
      LogService.instance.add(
          'Mesh: heard ${b.callsign} (${b.deviceClass.label}, ${f.rssi} dBm, reaches ${b.dv.length})');
    }
    if (f.addr.isNotEmpty) onPeerSighting?.call(b.callsign, f.addr);
    // M2: the beacon's have-bloom says what its owner already received —
    // purge any mail we're carrying FOR that owner that it claims to have.
    if (b.have.isNotEmpty) {
      final purged = MeshStore.instance.applyPeerBloom(b.callsign, b.have);
      if (purged > 0) {
        LogService.instance
            .add('Mesh: ${b.callsign} have-bloom purged $purged parked msg(s)');
      }
    }
    revision++;
    if (changed && _canAdvertise) {
      // Triggered update: topology changed — beacon early (debounced) so the
      // street converges fast, without letting a beacon storm feed itself.
      _triggerTimer ??= Timer(_triggerDebounce, () {
        _triggerTimer = null;
        _sendBeacon();
      });
    }
  }

  /// Is [callsign] a station we can hand a 1:1 to over the radio in the room,
  /// instead of sending it out to the internet?
  ///
  /// Asked of the TRANSPORT, not of `MeshTable`: the table is fed only by the
  /// 0x4D mesh beacon and this node does not air one (see [_sendBeacon]), so
  /// `neighbors` is empty between two phones and every answer taken from it is
  /// "no". The transport answers from the peer's own MSP HELLO caps plus its
  /// dial freshness — see `MeshCustodyDelegate.pointToPointOk`.
  ///
  /// The same predicate decides whether the message is COUPLED to the radio at
  /// all (`RnsService.sendLxmf` arms the courier) and whether its broadcast is
  /// then suppressed. One condition, so the two cannot disagree and strand a
  /// message that was armed but never handed over.
  bool isDirectNeighbour(String callsign) {
    if (callsign.isEmpty) return false;
    final ask = MeshSessionManager.instance.hooks.canTakeCustody;
    if (ask == null) return false;
    return ask(callsign.toUpperCase());
  }

  /// The wire to re-air for a held packet, with this station added to `via:`,
  /// or null when section 13 says it may not travel further.
  ///
  /// Section 36.8.1 is explicit that a custody hand-off is a relay in every
  /// respect that matters: "the author's packet travels byte for byte with the
  /// author's signature, `via:` gains the holder's callsign, the section 13.1
  /// budget and the section 13.2 loop check apply". The release used to re-air
  /// verbatim, which meant a receiver could not tell a relayed copy from a
  /// direct one -- the exact ambiguity that broke path evidence in
  /// `private-messages.md` section 6 -- and a re-heard copy parked all over
  /// again because nothing in it said we had already carried it.
  ///
  /// `xprsMayRelay` and `xprsWouldLoop` have existed, tested, with zero callers
  /// since they were written. These are the callers.
  /// 13.2.1's queue for the BLE radio. Wired to the same `_relayable` the
  /// 36.8.1 release uses, so the hop budget and the loop check are decided in
  /// one place whether a packet is being carried or merely repeated.
  late final XprsDigipeater digipeater = XprsDigipeater(
    relayable: _relayable,
    enabled: _mayRepeatOn,
    air: airOnLane,
  );

  /// Whether §13.1's repeat is allowed on [lane] right now.
  ///
  /// Per medium, because the media are not alike: Bluetooth is the one bearer
  /// where refusing to repeat leaves two phones in a room unable to reach each
  /// other at all, while a LAN repeat is cheap and a LoRa one is duty-cycled.
  /// The operator's switch and the publisher's bearer state both land here.
  bool _mayRepeatOn(String lane) {
    switch (lane) {
      case 'ble':
      case 'ble5':
        return digipeatBle && XprsPublisher.instance.isBearerEnabled('ble5');
      case 'lan':
        return digipeatLan && XprsPublisher.instance.isBearerEnabled('lan');
      default:
        // Reticulum is not a medium we repeat onto (§13.11.3), and no phone
        // has a LoRa radio. An unknown lane is not repeated rather than
        // guessed at.
        return false;
    }
  }

  /// THE ONE PLACE A RELAYED OR BRIDGED WIRE REACHES A BEARER.
  ///
  /// Both the digipeat and the bridge come through here, so airtime, the
  /// operator's switches and the bearer's own refusal are decided once. It
  /// used to reach into `XprsPublisher.bearers`, match `b.name != 'ble5'` and
  /// call `send` itself — which is how the repeat became BLE-only.
  Future<bool> airOnLane(String wire, String lane,
      {String slot = 'digi'}) async {
    final want = lane == 'ble' ? 'ble5' : lane;
    for (final b in XprsPublisher.instance.bearers) {
      if (b.name != want) continue;
      if (!XprsPublisher.instance.isBearerEnabled(b.name)) return false;
      if (!await b.active) return false;
      final ok = await b.send(wire, part: 1, slot: slot) == XprsSendResult.sent;
      // §31.1: "a beacon is not free", and neither is a repeat. Airtime is
      // charged in _fanOut, which this path deliberately does not use — so a
      // digipeat and a bridge were spending the shared budget without ever
      // appearing in it. Charged here, once, for every wire that leaves by
      // this door.
      if (ok) XprsAirtime.instance.charge([b.name]);
      return ok;
    }
    return false;
  }

  /// The operator's switches. On by default: a phone already listens on both
  /// Bluetooth and the LAN to know who is around, so the packet is in memory
  /// either way and only the airing costs anything.
  bool digipeatBle = true;
  bool digipeatLan = true;

  String? _relayable(String wire) {
    final p = XprsPacket.parse(wire);
    if (p == null) return null;
    final self = NostrCrypto.bareCallsign(tableCallsign).toUpperCase();
    if (self.isEmpty) return null;
    // An author is not one of its own relays.
    //
    // 13 defines `via:` as "the list of callsigns that RELAYED the packet",
    // and a station does not relay what it wrote. Without this the 36.8.1
    // release put us in the `via:` of our own mail, which is wrong three
    // ways: it spends one of the three hops 13.1 allows before the packet has
    // been relayed at all; it makes 13.2's loop check refuse our own retry;
    // and — the one that cost a night on the bench — it makes an ORIGIN copy
    // read as relayed, so every digipeater in earshot treats the author
    // repeating itself as somebody else having carried it and cancels its own
    // queued repeat under 13.2.1. That is exactly the rule a second hop
    // depends on.
    //
    // Unchanged, NOT refused: this routine is also how the 36.8.1 release airs
    // held mail, and some of that mail is our own. Refusing it would mean our
    // own outbound never left custody. An author re-sending its own packet
    // airs it exactly as written.
    if ((p['f'] ?? '').trim().toUpperCase() == self) return p.encode();
    // 13.2.2: when the sender named the relays, only a named one repeats it.
    //
    // On a bearer where every station hears every other, 13.2.1 leaves exactly
    // one relay standing and which one is a matter of whose random wait was
    // shortest — which is why a second hop could never be arranged before this.
    // A station not named stays quiet; the list being spent means nobody
    // relays, which is the terminal state and not an error.
    if (xprsRelay(p).isNotEmpty && !xprsRelayNextIs(p, self)) return null;
    if (xprsWouldLoop(p, self)) return null; // 13.2: it came through us already
    if (!xprsMayRelay(p)) return null; // 13.1: the type's budget is spent
    final out = xprsAppendVia(p, self);
    // Neither the identifier nor the signature changes -- both are computed
    // with `via:` removed (sections 5 and 9.1) -- but the packet does get
    // longer, and one that no longer fits stays put.
    return out.fits ? out.encode() : null;
  }

  MeshDeviceClass _deviceClass() {
    if (Platform.isAndroid || Platform.isIOS) return MeshDeviceClass.phone;
    return MeshDeviceClass.computer;
  }

  /// Stop (or resume) claiming we can advertise. Called when the controller
  /// refuses our advertising set: a node that cannot transmit is a scan-only
  /// leaf, and saying otherwise is how a mute device reported itself healthy.
  void setCanAdvertise(bool can) {
    if (_canAdvertise == can) return;
    _canAdvertise = can;
    LogService.instance.add(
        'Mesh: now ${can ? "relay-capable" : "scan-only (radio refuses to advertise)"}');
  }

  int _beaconsFailed = 0;

  /// Beacons the radio refused to air. `beaconsSent` counts only the ones that
  /// actually went out.
  int get beaconsFailed => _beaconsFailed;

  /// Say we are here. ONE beacon goes out, and it is the XPRS one.
  ///
  /// The binary mesh beacon used to be aired alongside it, carrying a
  /// distance-vector digest and a have-bloom. It is gone from the air for two
  /// reasons.
  ///
  /// The radio is the first. It is not full duplex — one antenna, time-shared —
  /// so every millisecond spent advertising is a millisecond deaf, and a device
  /// that advertises continuously misses roughly half of what is said to it.
  /// The transmit window is now a few seconds a minute (Ble5.kt), and two
  /// beacons competing for that window halve the chance either is heard.
  ///
  /// The second is that an advert is the wrong carrier for that content anyway:
  /// the DV digest and the bloom are exchanged IN FULL over an MSP session,
  /// acknowledged, whenever two stations have something to move. A beacon's job
  /// is to say "I am here, this is my callsign, this is what I am holding" —
  /// enough for a peer to decide to open a link. That is exactly what the XPRS
  /// beacon says (docs/XPRS.md section 10.6).
  Future<void> _sendBeacon() async {
    await _sendXprsBeacon();
  }

  /// The discovery beacon, as XPRS (docs/XPRS.md section 10.6).
  ///
  /// ```
  /// t:observation f:X1A67X link:ble peers:12 hears:X1RD89,X32DVA,CT1ABC-9
  /// ```
  ///
  /// This is the half of discovery that is readable: who I am and who I can
  /// reach. It rides its own subtype (`0x58`, ASCII 'X') so nothing has to sniff
  /// a frame to know what it is, and so the chat wapp and the ESP32 — which
  /// speak neither — ignore it instead of trying to parse it.
  ///
  /// The binary beacon above keeps the DV digest and the have-bloom, and that is
  /// not a retreat: those two exist *because* they are compressed. A DV entry is
  /// 4 bytes here and about 10 characters as text, and the bloom is a flat 128
  /// bytes, so at this controller's ceiling text fits either the routing table
  /// or the bloom and never both.
  /// Put this station's beacon on the air now, on every lane it beacons on.
  /// For the moment the radio underneath came back: the rotation's frames
  /// were rebuilt from what was registered, but the beacon is re-registered
  /// only every 30 s, and a neighbour that lost us should hear us first.
  void reannounce() {
    unawaited(_sendXprsBeacon());
  }

  Future<void> _sendXprsBeacon() async {
    final t = _table;
    if (t == null || !_canAdvertise) return;
    final self = t.selfCallsign.trim();
    if (self.isEmpty) return;

    var envelope =
        XprsPacket.parse('t:observation f:$self link:ble peers:0 hears:x');
    if (envelope == null) return;

    // `mail:` is how this station says it is holding messages for other people
    // (section 10.6.5), and it is why carried mail no longer needs a broadcast
    // of its own: a neighbour that can reach a recipient opens a session, and
    // everybody else spends nothing. Omitted at zero — a field that is almost
    // always 0 is not worth transmitting.
    final held = MeshStore.instance.ready ? MeshStore.instance.pendingCount() : 0;
    if (held > 0) envelope = envelope.with_('mail', '$held');

    // `lx:` — WHERE TO WRITE TO US: this station's LXMF delivery destination.
    //
    // Knowing a callsign is on the air is not enough to address it. That needs a
    // Reticulum path, which is learned from an ANNOUNCE, and announces were
    // losing the advert channel to traffic: measured between two phones with no
    // internet, one heard its neighbour's beacon every few seconds and its
    // announce once in five minutes, so `/api/rns/route` for that peer stayed
    // null and every message fell back to store-and-carry.
    //
    // The beacon already says who is here; this says where to write. A hearer
    // that holds no path asks for one (a single throttled path request), and the
    // peer answers with the announce that carries its key. 36 bytes on a
    // 76-byte beacon, well inside the smallest measured advert ceiling (184).
    final lx = ourLxmfDest?.call();
    if (lx != null && lx.length == 32) envelope = envelope.with_('lx', lx);

    // `uptime:`/`lifetime:` — this station's stability account (section 10.5),
    // for whoever is choosing a relay or a mailbox. Added BEFORE the
    // neighbour fit below so their bytes count against the advert budget.
    final upSec = DateTime.now().difference(_startedAt).inSeconds;
    envelope = envelope.with_('uptime', xprsFmtDuration(upSec));
    if (_lifeBaseSec >= 0) {
      envelope =
          envelope.with_('lifetime', xprsFmtDuration(_lifeBaseSec + upSec));
    }

    // `serve:archive` (section 24): this station keeps a spool and answers
    // cmd:history. The claim is "ask me", never a depth (31.3). Before the
    // neighbour fit, so its bytes count against the advert budget.
    if ((PreferencesService.instanceSync?.xprsServeHistory ?? true) &&
        XprsArchive.instance.ready) {
      // `super` beside `archive`, never instead of it (24, 36.9.4).
      envelope = envelope.with_(
          'serve',
          (PreferencesService.instanceSync?.xprsSuperArchiver ?? false)
              ? 'archive,super'
              : 'archive');
    }

    // Most relevant first, and this station's idea of relevant (section
    // 10.6.3): a powered, stationary relay outranks a passing phone that
    // happens to be loud right now, then how reliably we hear it, then signal.
    // WHO WE ACTUALLY HEAR, from the monitor — the same source the LAN beacon
    // uses, and for the same reason.
    //
    // This read `MeshTable.neighbors`, which is filled only by the 0x4D mesh
    // beacon that `_sendBeacon` deliberately does not air (two beacons halve
    // the chance either is heard in a five-second-a-minute window). The table
    // is therefore permanently empty, so **this station has never told anyone
    // who it hears** — `hears:` was absent from every BLE beacon it ever sent,
    // and `peers:` read 0 while the monitor knew otherwise.
    //
    // What that cost is the whole point of the field. §36.9.4's gossip resolves
    // "who can reach X" from other stations' `hears:` claims, and §36.8.1's
    // forwarder hands mail to whoever claims X. With no claim ever made, a
    // BLE-only station could not learn that this station reaches the LAN, so
    // mail for a LAN-only peer had nowhere to go but a lottery: hope the
    // carrier happened to overhear the one advert. Measured on the bench —
    // TANK2 had heard zero beacons naming X16JK8 and its gossip named only
    // itself as the gateway.
    final fresh = XprsMonitor.instance.directlyHeard();

    // SIGNED, like the LAN beacon and for the same reason: an unsigned beacon
    // is a callsign anybody can write.
    //
    // This one was not, and `hears:` is what that cost. §36.9.4's gossip
    // refuses an unsigned claim outright (`refusedUnsigned`), so even once the
    // list was populated it fed nothing — a BLE-only station would hear this
    // beacon, drop the claim, and still not know who reaches the LAN. Both
    // halves are needed: something true to say, and a signature that lets the
    // hearer act on it.
    //
    // Room is reserved before the fit, exactly as the LAN builder does: ` sig:`
    // plus 60 base85 characters is 65 bytes, and a `hears:` list sized against
    // the full advert would push the signed packet over the ceiling.
    final d = xprsProfileScalar();
    final budget = Ble5Bus.instance.maxPayload - (d != null ? 65 : 0);

    // `peers:` is the true total even when `hears:` is cut to fit. Without it a
    // short list cannot be told from a small mesh (section 10.6.4).
    final fit = xprsNeighbourFit(fresh, envelope, budget);
    var p = envelope.with_('peers', '${fit.peers}');
    p = fit.hears.isEmpty
        ? XprsPacket(p.fields.where((f) => f.key != 'hears').toList())
        : p.with_('hears', fit.hears.join(','));
    if (d != null) p = xprsSign(p, d);

    // No `busy:` or `txtime:` yet. Section 10.6 defines both over the last hour
    // and this node measures neither — `channelLoad` is a short sliding window
    // of adverts per second, which is a different quantity. Publishing it under
    // those names would be a wrong number rather than a missing one.
    try {
      final bytes = Uint8List.fromList(utf8.encode(p.encode()));
      // `aired` now means the bytes REACHED THE CONTROLLER, not that the bus
      // accepted them into its frame map. Those were the same value until the
      // bench measured 2002 beacons "sent" here against zero on the air in an
      // independent 185s capture — every number below was counting
      // registrations. See Ble5.advertiseFrame.
      final aired = await Ble5Bus.instance
          .advertiseFrame('xprs', Ble5Subtype.xprs, bytes, ttl: _beaconTtl);
      // §31.1: "a beacon is not free". This path goes straight to the advert
      // bus rather than through the publisher, so it charges the shared budget
      // here — otherwise the one packet a station sends most often would be the
      // one packet the budget never sees. Charged only on a real airing: a
      // ledger that bills for transmissions that did not happen throttles the
      // station for nothing.
      if (aired) XprsAirtime.instance.charge(const ['ble5']);
      // Ours, so it goes in our own log either way (section 36.5) — the
      // bearer says whether a radio actually took it.
      XprsIngest.own(p.encode(), bearer: aired ? 'ble' : 'none');
      if (aired) {
        _xprsBeaconsSent++;
      } else {
        _xprsBeaconsFailed++;
        if (_xprsBeaconsFailed == 1 || _xprsBeaconsFailed % 10 == 0) {
          LogService.instance.add(
              'Mesh: radio refused the XPRS beacon (${bytes.length}B, cap '
              '${Ble5Bus.instance.maxPayload}B, $_xprsBeaconsFailed so far)');
        }
      }
    } catch (e) {
      LogService.instance.add('Mesh: XPRS beacon tx failed: $e');
    }
  }

  /// The same discovery beacon, on the wire in the building (`docs/lan.md`).
  ///
  /// ```
  /// t:observation f:X1A67X link:lan peers:3 hears:X3WWAJ,X1BOA3 sig:<60 characters>
  /// ```
  ///
  /// Separate from the Bluetooth one rather than a parameter on it, because
  /// almost everything about it differs: `link:` names a different bearer, and
  /// section 10.6.1 is explicit that a reading about one radio is not evidence
  /// about another; the neighbours are the ones heard on the wire, not the mesh
  /// table (which a desktop has nothing in); and the byte budget is the format's
  /// own 250 rather than whatever the BLE controller will carry.
  ///
  /// **Signed**, which the Bluetooth beacon is not: signing is the default
  /// (section 9.1) and only the advert ceiling argues against it. Here there is
  /// room, and an unsigned beacon is a callsign anybody can write — an indexer
  /// deciding whether to spend airtime on us has nothing else to go on.
  /// Fire-and-forget wrapper: airing now awaits the bearer, and neither the
  /// timer nor the startup path has anything to do with the answer.
  void _sendXprsLanBeacon() => unawaited(_airLanBeacon());

  Future<void> _airLanBeacon() async {
    if (!XprsLan.instance.up) return;
    final self = (_table?.selfCallsign ?? '').trim();
    if (self.isEmpty) return;

    var envelope = XprsPacket.parse('t:observation f:$self link:lan');
    if (envelope == null) return;

    final held = MeshStore.instance.ready ? MeshStore.instance.pendingCount() : 0;
    if (held > 0) envelope = envelope.with_('mail', '$held');

    final upSec = DateTime.now().difference(_startedAt).inSeconds;
    envelope = envelope.with_('uptime', xprsFmtDuration(upSec));
    if (_lifeBaseSec >= 0) {
      envelope =
          envelope.with_('lifetime', xprsFmtDuration(_lifeBaseSec + upSec));
    }
    if ((PreferencesService.instanceSync?.xprsServeHistory ?? true) &&
        XprsArchive.instance.ready) {
      // `super` beside `archive`, never instead of it (24, 36.9.4).
      envelope = envelope.with_(
          'serve',
          (PreferencesService.instanceSync?.xprsSuperArchiver ?? false)
              ? 'archive,super'
              : 'archive');
    }

    // Leave room for the signature the fit cannot know about: ` sig:` plus 60
    // base85 characters is 65 bytes, and a `hears:` list sized against the full
    // 250 would push the signed packet over it.
    final d = xprsProfileScalar();
    final budget = XprsPacket.maxBytes - (d != null ? 65 : 0);
    final fit = xprsNeighbourFit(
        XprsMonitor.instance.directlyHeard(), envelope, budget);
    var p = envelope.with_('peers', '${fit.peers}');
    if (fit.hears.isNotEmpty) p = p.with_('hears', fit.hears.join(','));
    if (d != null) p = xprsSign(p, d);

    // Through the one lane door, so the beacon is charged and gated exactly
    // like a repeat or a bridge. Deliberately ONE lane and not the fan-out:
    // this packet claims `link:lan`, which is a statement about the LAN and
    // would be a lie on any other bearer.
    final aired = await airOnLane(p.encode(), 'lan', slot: 'beacon');
    XprsIngest.own(p.encode(), bearer: aired ? 'lan' : 'none');
    if (aired) {
      _xprsLanBeaconsSent++;
    } else {
      _xprsLanBeaconsFailed++;
    }
  }

  int _xprsLanBeaconsSent = 0;
  int _xprsLanBeaconsFailed = 0;

  /// XPRS beacons put on the LAN, and the ones the socket would not take.
  int get xprsLanBeaconsSent => _xprsLanBeaconsSent;
  int get xprsLanBeaconsFailed => _xprsLanBeaconsFailed;

  int _xprsBeaconsSent = 0;
  int _xprsBeaconsFailed = 0;

  /// XPRS discovery beacons the radio accepted.
  int get xprsBeaconsSent => _xprsBeaconsSent;

  /// XPRS beacons the radio refused — aired nowhere.
  int get xprsBeaconsFailed => _xprsBeaconsFailed;

  /// Devices snapshot as `people`-widget sections (consumed verbatim by the
  /// Bluetooth wapp via ui.people.set, same pattern as hal_rns_nodes → graph).
  String peopleSectionsJson() {
    final t = _table;
    final now = DateTime.now();
    if (t == null) {
      return jsonEncode([
        {
          'title': 'Nearby',
          'items': [],
        }
      ]);
    }
    String ago(DateTime d) {
      final s = now.difference(d).inSeconds;
      if (s < 60) return '${s}s';
      if (s < 3600) return '${s ~/ 60}m';
      return '${s ~/ 3600}h';
    }

    final ns = t.neighbors.values.toList()
      ..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
    final neighborItems = [
      for (final n in ns)
        {
          // ASCII only: multibyte glyphs get mangled on the wapp round-trip.
          'id': n.callsign,
          'title': n.callsign,
          'subtitle':
              '${n.deviceClass.label} - ${n.bidirectional ? "link 2-way" : "link one-way"}'
              ' - ${n.lastRssi} dBm - heard ${ago(n.lastHeard)} ago'
              ' - contact ${(n.contactRatio * 100).round()}%',
          'tags': [
            'seen ${ago(n.lastHeard)} ago',
            n.deviceClass.label,
            if (n.cond.powered) 'powered',
            'up ${MeshConditions.uptimeLabels[n.cond.uptimeBucket]}',
            '1 hop',
            'reaches ${n.digest.length}',
          ],
          'buttons': [
            {'icon': 'mail', 'action': 'message', 'tip': 'Send message'}
          ],
        }
    ];

    final rs = t.routes.values.toList()..sort((a, b) => a.cost.compareTo(b.cost));
    final routeItems = [
      for (final r in rs)
        if (!t.neighbors.values.any((n) => meshHashHex(n.hash) == r.destHashHex))
          {
            'id': t.names[r.destHashHex] ?? r.destHashHex,
            'title': t.names[r.destHashHex] ?? '#${r.destHashHex}',
            'subtitle': 'via ${r.viaCallsign} - ${r.cost} hops',
            'tags': [
              'seen ${ago(r.updated)} ago',
              '${r.cost} hops',
              'via ${r.viaCallsign}'
            ],
            // Envelope only when the destination's callsign is known (a bare
            // routing hash can't address a conversation).
            if (t.names.containsKey(r.destHashHex))
              'buttons': [
                {'icon': 'mail', 'action': 'message', 'tip': 'Send message'}
              ],
          }
    ];

    // The people widget appends its own per-section counts to the tab titles.
    return jsonEncode([
      {'title': 'Nearby', 'items': neighborItems},
      {'title': 'Multi-hop', 'items': routeItems},
    ]);
  }

  /// Node status for the wapp header/log.
  String statusJson() {
    final t = _table;
    return jsonEncode({
      'running': _running,
      'callsign': t?.selfCallsign ?? '',
      // What the catch-up poller last did. A sweep that asks nobody logs
      // nothing, so without this a stalled poller and a quiet one are the same
      // from outside -- which is exactly the confusion this cost once.
      'catchup': XprsCatchup.instance.statusJson(),
      'advertising': _canAdvertise,
      'class': _deviceClass().label,
      'powered': _powered,
      'uptime': DateTime.now().difference(_startedAt).inSeconds,
      'neighbors': t?.neighbors.length ?? 0,
      'routes': t?.routes.length ?? 0,
      'beaconsSent': _beaconsSent,
      'beaconsHeard': _beaconsHeard,
      'xprsBeaconsSent': _xprsBeaconsSent,
      'xprsBeaconsHeard': _xprsBeaconsHeard,
      'xprsBeaconsFailed': _xprsBeaconsFailed,
      'channelLoad': double.parse(channelLoad().toStringAsFixed(2)),
      'politeness': ['quiet', 'busy', 'saturated'][politenessTier()],
      'beaconIntervalS': beaconIntervalNow().inSeconds,
      'battery': _batteryPct,
      'revision': revision,
      // Custody counters: relaying asserted as a number, not grepped out of a
      // rolling log that holds twenty minutes on a busy device.
      ...MeshCustodyCounters.toJson(),
    });
  }

  /// 36.8.1's release-on-hearing, throttled: one attempt per callsign per
  /// half minute however chatty their beacons.
  final Map<String, int> _releaseTriedMs = {};

  void _onDirectHeard(String callsign, String bearer) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _releaseTriedMs[callsign] ?? 0;
    if (now - last < 30000) return;
    // Arm the throttle BEFORE the store probe, not only on a hit: this sits
    // on the funnel, every beacon lands here, and pendingFor is a sqlite
    // query on the main isolate. Armed only on a hit, the empty case — which
    // is nearly every packet on a busy bench — paid that query per beacon,
    // forever (docs/performance.md 4.2: a cheap call in a hot loop IS the
    // drain).
    _releaseTriedMs[callsign] = now;
    if (_releaseTriedMs.length > 256) {
      _releaseTriedMs.remove(_releaseTriedMs.keys.first);
    }
    final pending = MeshStore.instance.releasableFor(callsign,
        selfCallsign: tableCallsign);
    if (pending.isEmpty) return;
    LogService.instance.add(
        'Mesh: $callsign heard on $bearer with ${pending.length} to release '
        '(36.8.1)');
    if (bearer == 'ble') {
      // The session lane: clear the backoff and decide now. When that lane has
      // the peer in hand -- a dial just went out, or a session with it is up
      // -- the held mail crosses over the link and the air is left alone.
      if (MeshTransferScheduler.instance.pokeFor(callsign)) return;
      // Otherwise the radio is spoken for (a session with somebody else, a
      // dial in flight, a backoff), and the peer is beaconing at us RIGHT NOW
      // -- so this is when an advert has the best chance of being heard. Fall
      // through and re-air, paced by the store's release backoff (0, 30, 120,
      // 600 s) so a peer that beacons every thirty seconds does not draw the
      // same frame every thirty seconds. Bench 2026-09-04: a 1:1 whose single
      // advert was lost sat in the store for 86 s while the scheduler was
      // busy with a hub, and the target beaconed at us twice in that time.
      LogService.instance.add(
          'Mesh: session lane busy — re-airing for $callsign instead');
    }
    // Re-air the held wires, paced, under the publisher's budgets. The
    // receipt (13.7) is what marks them done -- an aired copy is an attempt,
    // not a delivery.
    unawaited(() async {
      for (final m in pending) {
        // The stored wire is bytes; the publisher speaks text wires. A held
        // frame that is not UTF-8 XPRS (a binary custody blob) stays on the
        // session lane and is skipped here.
        final wire = utf8.decode(m.wire, allowMalformed: true);
        if (!wire.startsWith('t:')) continue;
        // Only mail is released, which is the third place this same rule
        // belongs and the last one to get it. Custody ACCEPTANCE has said it
        // since it was written — "an observation, a status or a poll is aired,
        // not couriered" — and delivery got it when machine packets were
        // arriving as somebody's chat messages. Releasing had no test at all,
        // because until now only a t:message could ever be parked.
        //
        // It becomes load-bearing the moment anything else can be: a directed
        // packet handed to the session lane is parked in this same store, and
        // without this it would be re-aired here as a broadcast, minutes late,
        // which is precisely the airtime the session lane exists to save.
        // A no-op today, by construction, and the guard that keeps it one.
        final held = XprsPacket.parse(wire);
        if (held == null || held.type != 'message') continue;
        final out = _relayable(wire);
        if (out == null) continue;
        // Attempt recorded BEFORE the air, so a throw or a refused bearer
        // still backs the row off rather than re-airing it every 30 s.
        MeshStore.instance.noteReleased(m.key);
        await XprsPublisher.instance.publishWire(out,
            verbatim: true, slot: 'release:${m.key}', prefer: bearer);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }());
  }

  // ── facade for the wapp layer ─────────────────────────────────────────────
  // lib/wapp must not reach into the mesh internals (docs/architecture.md §1):
  // that is how store-and-forward ended up inside a wapp. Everything the wapp
  // layer legitimately needs goes through these three, and the guard
  // (no-transport-in-wapp-layer) keeps it that way.

  /// Parked-mail counts, live transfers and quotas — what the mesh status HAL
  /// endpoint reports.
  Map<String, dynamic> storeStatus() {
    final c = MeshStore.instance.counts();
    return {
      'inTransit': c.inTransit,
      'archived': c.archived,
      'bytes': c.bytes,
      'receivedAms': c.receivedAms,
      'quotaBytes': MeshStore.instance.quotaBytes,
      'spoolPending': MeshBulkSpool.instance.pendingCount(),
      'spoolQuotaBytes': MeshBulkSpool.instance.quotaBytes,
      // Whether this device carries other people's mail (see setQuotaPref's
      // 'scfEnabled'). 1 by default.
      'enabled': MeshStore.instance.carryForOthers ? 1 : 0,
    };
  }

  /// What this device is holding for other people, newest first.
  List<Map<String, dynamic>> held({int limit = 200}) =>
      MeshStore.instance.heldJson(limit: limit, selfCallsign: tableCallsign);

  /// What ANOTHER station is carrying, as plain rows; null when it could not
  /// be reached (or does not serve listings).
  ///
  /// Browsing a neighbour's custody store means dialling it and running an MSP
  /// session — a transport act, and therefore this layer's job rather than the
  /// caller's. The rows come back as data, so a screen can render them without
  /// naming a session type: `{am, target, urg, len, ageS}`, the same shape the
  /// wapp-facing broker uses (mesh_carry_broker.dart).
  Future<List<Map<String, dynamic>>?> carriedBy(String callsign) async {
    final entries = await MeshSessionManager.instance.browseCarried(callsign);
    if (entries == null) return null;
    return [
      for (final e in entries)
        {
          'am': e.am,
          'target': e.target,
          'urg': e.urg,
          'len': e.len,
          'ageS': e.ageS,
        },
    ];
  }

  /// Take custody of [ids] from [callsign] — they transfer over the session
  /// and land in our own store. True when the request went out on a live one.
  Future<bool> takeCustody(String callsign, List<String> ids) =>
      MeshSessionManager.instance.pullCarried(callsign, ids);

  /// Bulk-lane transfers in flight.
  List<Map<String, dynamic>> transfers() =>
      MeshBulkSpool.instance.transfersJson();

  /// How much disk this device offers: `msgQuotaMb` for other people's mail,
  /// `bulkQuotaMb` for the file lane. Returns false on an unknown key.
  bool setQuotaPref(String key, int mb) {
    if (mb < 0) return false;
    switch (key) {
      case 'msgQuotaMb':
        MeshStore.instance.quotaBytes = mb * 1024 * 1024;
      case 'bulkQuotaMb':
        MeshBulkSpool.instance.quotaBytes = mb * 1024 * 1024;
      case 'scfEnabled':
        // Not a quota — a yes/no — but it rides the same one-int channel, so
        // the wapp needs no second HAL to ask for it. 0 = carry nothing for
        // anyone else; anything else = carry (the default).
        MeshStore.instance.carryForOthers = mb != 0;
        unawaited(PreferencesService.instanceSync
            ?.setMeshCarryForOthers(mb != 0) ?? Future<void>.value());
      default:
        return false;
    }
    return true;
  }

  /// A wapp echoed an outgoing 1:1 bubble. The core decides what that means for
  /// delivery (today: queue any attachment it references on the bulk lane).
  void noteConvoOutMessage(Map<String, dynamic> data) =>
      MeshCustodyDelegate.onConvoOutMessage(data);
}
