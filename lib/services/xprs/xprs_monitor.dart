/*
 * xprs_monitor — what this device has heard on the air, kept so a person can
 * look at it.
 *
 * Passive and read-only. It decides nothing, transmits nothing and is on no
 * delivery path: the transport has already handled a packet by the time it
 * lands here. That is what keeps it on the right side of "transports are core"
 * — it observes, it does not route.
 *
 * Two things are exposed to a wapp (docs/XPRS.md section 10.6):
 *
 *   stations — who has been heard, over which bearer, how recently
 *   traffic  — the last few hundred packets, including the ones addressed to
 *              other people, which is most of what a mesh carries
 *
 * INTERNET TRAFFIC NEVER ENTERS THIS RING, and not by filtering it out later.
 * The bearer is recorded where the packet arrives, only radio and local
 * bearers call [offer], and [kBearers] refuses anything else. A packet that
 * came over a hub cannot be in here to be leaked by a caller who forgot.
 */
import 'dart:convert';

import '../receive/core_state.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// Bearers a sighting may claim.
///
/// Deliberately a subset of the XPRS `link:` vocabulary: `internet` is absent,
/// because this is the record of what arrived over the air or over a local
/// network, and an entry claiming otherwise would make the whole view a lie.
const Set<String> kBearers = {
  'ble', 'lan', 'espnow', 'lora', 'wifi', 'vhf', 'uhf', 'hf',
};

/// One packet, as heard.
class XprsSighting {
  final int tsMs;
  final String bearer;
  final int rssi;
  final String from;
  final String to;
  final String type;
  final String id;

  /// Whether `d:` named us. False for the traffic that is merely passing.
  final bool mine;
  final String wire;

  const XprsSighting({
    required this.tsMs,
    required this.bearer,
    required this.rssi,
    required this.from,
    required this.to,
    required this.type,
    required this.id,
    required this.mine,
    required this.wire,
  });

  Map<String, dynamic> toJson() => {
        'ts': tsMs ~/ 1000,
        'bearer': bearer,
        'rssi': rssi,
        'from': from,
        'to': to,
        'type': type,
        'id': id,
        'mine': mine,
        'wire': wire,
      };
}

/// A station we have heard, and the most recent thing it told us.
class XprsStation {
  XprsStation(this.callsign, this.bearer, this.firstMs)
      : lastMs = firstMs,
        packets = 0;

  final String callsign;

  /// The bearer the LAST packet arrived over. Kept for the many readers that
  /// want one word for "how did I hear this".
  String bearer;

  /// EVERY bearer this station has been heard on, each with the moment it was
  /// last heard there. One station is commonly reachable several ways at once
  /// -- a phone on the LAN that is also advertising over BLE5, a dongle on
  /// both BLE5 and ESP-NOW -- and a single `bearer` field could only ever name
  /// the most recent, flipping between them packet by packet and hiding the
  /// rest. The per-bearer timestamp is what lets a reader age each one out on
  /// its own: BLE5 going quiet does not mean the LAN did.
  final Map<String, int> bearers = {};

  /// The bearers heard within [window], newest first -- INCLUDING packets that
  /// reached us relayed. Good for "how did I hear this station"; not evidence
  /// of a path TO it. See [bearersDirect].
  List<String> bearersFresh(int nowMs, int windowMs) {
    final live = bearers.entries.where((e) => nowMs - e.value <= windowMs).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in live) e.key];
  }

  /// Bearers this station SAYS IT IS ON, from the `link:` of its own beacon.
  ///
  /// Section 10.6.1: "a station reports once per bearer", and `link:` names
  /// which one -- `lora`, `ble`, `wifi`, `espnow`, `lan`. That is the station's
  /// own statement about its own radio, and it is the only trustworthy evidence
  /// of a path TO it, which section 36.0 requires before choosing one path over
  /// another.
  ///
  /// The arrival bearer is NOT that evidence, and the difference cost a bench
  /// run: a message addressed to a phone with its WiFi off went out over the LAN
  /// alone and reached nobody, because a third station had re-aired that phone's
  /// beacon onto the LAN and the arrival bearer was recorded as if the phone
  /// itself had been there.
  ///
  /// `via:` cannot be used to tell the two apart either, however much it looks
  /// like the right field: nothing transmits it yet (section 37, "`via:`
  /// instead of rewriting `f:` | not implemented"), so a re-aired packet is
  /// byte-identical to a direct one. A beacon's `link:` survives re-airing with
  /// its meaning intact, because it describes the sender rather than the hop.
  final Map<String, int> bearersDeclared = {};

  /// `link:` words as they appear on the wire, mapped to the bearer names the
  /// publisher uses. Reticulum has no `link:` word -- it is the internet path,
  /// not a radio a station stands on.
  static const Map<String, String> linkToBearer = {
    'ble': 'ble5',
    'lan': 'lan',
    'lora': 'lora',
  };

  /// Bearer names (publisher spelling) this station declared itself on inside
  /// [windowMs], newest first.
  List<String> declaredBearersFresh(int nowMs, int windowMs) {
    final live = bearersDeclared.entries
        .where((e) => nowMs - e.value <= windowMs)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in live)
        if (linkToBearer[e.key] != null) linkToBearer[e.key]!
    ];
  }

  int firstMs;
  int lastMs;
  int packets;
  int rssi = 0;

  /// From the sender's last beacon (sections 10.6.4 and 10.6.5), when it sent
  /// one. Null means it has not said, which is different from zero.
  int? peers;
  int? mail;

  /// The sender's stability account (section 10.5), verbatim `qty` text like
  /// `26h` / `38day`. A claim, not a measurement — shown as said.
  String? uptime;
  String? lifetime;

  /// What it says it does for other stations (section 24, `serve:`). This is
  /// how an indexer is told from a phone: `index` in here and nowhere else.
  List<String> services = const [];

  /// The last value this station reported for each measurement key it has
  /// ever sent (section 10.4 telemetry, section 23.3 supply). Kept as the text
  /// on the wire, unit included -- `14.2C`, not `14.2`.
  final Map<String, String> readings = {};

  /// An archiver's `count:` — how many RECORDS it holds (section 24.0.1).
  ///
  /// Not callsigns. The distinction is the whole value of the field: a poller
  /// remembers this number and asks for history when it moves, and a count of
  /// senders does not move when six known stations say six new things. This
  /// doc used to say callsigns, which is what section 36.9's *directory* is
  /// about, and the two are different questions.
  ///
  /// Null means the station has not said. That is a real answer and not the
  /// same as zero: a station that cannot cheaply produce a record count omits
  /// the field rather than publishing a constant, and a poller that sees
  /// nothing falls back to its period.
  int? count;

  /// Who it says it hears directly (section 10.6.3). Finding our own callsign
  /// in here is this station telling us, on the air, that it can hear us.
  List<String> hears = const [];

  /// What this station's signatures have turned out to be (section 9.1).
  ///
  /// Counted rather than reduced to one word, because they say different
  /// things: a station can sign some packets and not others, and one forgery
  /// among a hundred good packets is the fact worth surfacing, not an average.
  /// [sigForged] is never decremented — somebody used this callsign to sign
  /// something they could not have signed, and that does not stop being true
  /// because the next packet was fine.
  int sigVerified = 0, sigUnverified = 0, sigForged = 0, sigUnsigned = 0;

  /// The one word for a badge. Forged wins over everything.
  XprsSigState? get sigHeadline {
    if (sigForged > 0) return XprsSigState.forged;
    if (sigVerified > 0) return XprsSigState.verified;
    if (sigUnverified > 0) return XprsSigState.unverified;
    if (sigUnsigned > 0) return XprsSigState.unsigned;
    return null;                       // nothing judged yet: say nothing
  }

  /// The last time we heard this station with no `via:` — from its own
  /// transmitter rather than through a relay.
  ///
  /// A relayed copy carries the originator in `f:` exactly like a direct one,
  /// so without this every "who do I hear" list would quietly include stations
  /// on the far side of a digipeater, which section 10.6.3 forbids.
  int lastDirectMs = 0;
}

class XprsMonitor {
  XprsMonitor._();
  static final XprsMonitor instance = XprsMonitor._();

  /// How many sightings are kept. A few hundred is a couple of minutes of a
  /// busy street, which is what a person looking at a live trace wants; the
  /// point of this view is what is happening now.
  static const int ringMax = 200;

  /// A station stops being listed after this long without a packet. Longer
  /// than the slowest beacon interval (5 minutes at the saturated politeness
  /// tier) so a quiet-but-present station does not flicker out.
  static const Duration staleAfter = Duration(minutes: 11);

  /// How long a station that has gone quiet stays LISTED after [staleAfter]
  /// -- "heard this hour", the second section of [stationsJson].
  ///
  /// [_stations] is the core's "in earshot" and every reachability decision
  /// (catch-up, file fetch, the mesh scheduler) reads it as such, so its
  /// window is not widened. But a person opening "New chat" is asking a
  /// wider question -- who was around, not only who beaconed in the last
  /// eleven minutes -- and a phone that went quiet fifteen minutes ago is
  /// still the phone on the next desk. Kept separately, for the list only.
  static const Duration rememberedFor = Duration(hours: 1);
  static const int rememberedMax = 128;

  final List<XprsSighting> _ring = [];
  final Map<String, XprsStation> _stations = {};

  /// Stations swept out of [_stations]: when they were last heard, and on
  /// what. Read by [stationsJson] only.
  final Map<String, ({int lastMs, String bearer})> _recent = {};

  /// XPRS stations whose packets reached us over Reticulum -- the internet
  /// lane -- within [rememberedFor]. NOT the air: [offer] refuses that
  /// bearer and always will. Kept apart, under its own name, so a list that
  /// says "over the air" stays true and a list that says "on Reticulum" can
  /// exist at all. Fed by [noteRemote] from the Reticulum ingest; read by
  /// [stationsJson] only.
  final Map<String, int> _remote = {};

  /// Bumped whenever something changed, so a wapp can skip a redraw. Same
  /// trick `MeshService.revision` uses.
  int revision = 0;

  /// One change to the table or the ring.
  ///
  /// Every mutation went through a bare `revision++`, which recorded that
  /// something moved and told nobody — so the only way for a wapp to find out
  /// was to ask on a timer, and the `xprs` wapp asked every three seconds
  /// whether these numbers had changed, re-encoding two hundred sightings each
  /// time to find out. Now the counter and the announcement are the same act,
  /// and they cannot drift apart.
  void _bump() {
    revision++;
    CoreState.instance.changed(CoreState.monitor);
  }

  List<XprsSighting> get ring => List.unmodifiable(_ring);
  Map<String, XprsStation> get stations => Map.unmodifiable(_stations);

  /// Record a packet that arrived over [bearer].
  ///
  /// Silently ignores a bearer outside [kBearers] — including `internet`. A
  /// caller that gets this wrong loses the sighting rather than putting a
  /// misleading one in front of somebody.
  /// Test seam: forget every station. The monitor is a singleton, so without
  /// this test 2 inherits test 1's air.
  void debugReset() {
    _stations.clear();
  }

  void offer(
    XprsPacket p, {
    required String bearer,
    required String selfCallsign,
    int rssi = 0,
    int? nowMs,
  }) {
    if (!kBearers.contains(bearer)) return;
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty) return;
    final self = selfCallsign.trim().toUpperCase();
    if (from == self) return; // our own packet, heard back

    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final to = (p['d'] ?? '').trim().toUpperCase();

    _ring.add(XprsSighting(
      tsMs: now,
      bearer: bearer,
      rssi: rssi,
      from: from,
      to: to,
      type: p.type,
      id: xprsIdentifier(p),
      mine: to.isNotEmpty && to == self,
      wire: p.encode(),
    ));
    if (_ring.length > ringMax) _ring.removeRange(0, _ring.length - ringMax);

    final st = _stations.putIfAbsent(from, () => XprsStation(from, bearer, now));
    _recent.remove(from); // heard again: back in earshot
    st.bearer = bearer;
    st.bearers[bearer] = now;
    // The station's own `link:` (10.6.1) -- what IT says it is on, which
    // survives being re-aired by somebody else. See `bearersDeclared`.
    //
    // Stamped with the packet's OWN `ts:` (4.8: "when the packet was composed"),
    // never with the moment we heard it. A beacon re-aired by a third station
    // arrives now and was composed then, and stamping it `now` makes an hour-old
    // claim look current -- which is how a phone whose WiFi had been off for an
    // hour still read as "on the LAN" and had a private message sent there and
    // nowhere else. A station with no clock (10.7) sends no `ts:`, and its
    // sighting is stamped on arrival because that is the best that exists.
    final link = p['link'];
    if (link != null && link.isNotEmpty) {
      final composed = xprsParseTs(p['ts']) ?? now;
      final was = st.bearersDeclared[link];
      // Newest claim wins; an out-of-order re-airing never ages one backwards.
      if (was == null || composed > was) st.bearersDeclared[link] = composed;
    }
    st.lastMs = now;
    // Keep the latest of anything it measured. A weather station's temp and a
    // tracker's battery arrive on ordinary packets, not a special type, so
    // this reads whatever the packet happens to carry.
    for (final k in kXprsReadings) {
      final v = p[k];
      if (v != null && v.isNotEmpty) st.readings[k] = v;
    }
    st.rssi = rssi;
    st.packets++;
    // A beacon says how many it can reach and whether it is holding mail; an
    // ordinary message says neither, and must not erase what the beacon said.
    final peers = xprsPeers(p);
    if (peers != null) st.peers = peers;
    if (p.has('mail')) st.mail = xprsMail(p);
    if (p.has('uptime')) st.uptime = p['uptime'];
    if (p.has('lifetime')) st.lifetime = p['lifetime'];
    // `serve:`, `count:` and `hears:` follow the same rule: a beacon or a
    // service advertisement states them, an ordinary message states neither,
    // and a message must not erase what the advertisement said.
    if (p.has('serve')) st.services = xprsServices(p);
    // Only from a packet where `count:` means the archive size. On
    // `t:file kind:folder` it is the number of files in a listing (6.7.3), and
    // reading that as an archive size would have a folder announcement move a
    // station's news counter.
    if (p.has('count') && p.type != 'file') {
      st.count = int.tryParse(p['count'] ?? '');
    }
    if (p.has('hears')) st.hears = xprsHears(p);
    // No `via:` means this arrived from the sender's own transmitter.
    if (!p.has('via')) st.lastDirectMs = now;

    _bump();
  }

  /// The callsigns this station can hear directly, most recent first — what
  /// `hears:` is for (section 10.6.3).
  ///
  /// Directly heard only, so a station known only through a relay is absent;
  /// and heard within [within], because a list is a claim about now. "Most
  /// recent first" is this station's idea of relevant, which the format leaves
  /// to the sender: a desktop on a wire has no signal or contact ratio to rank
  /// by, so recency is the honest ordering.
  List<String> directlyHeard({Duration within = staleAfter, int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final fresh = _stations.values
        .where((s) =>
            s.lastDirectMs > 0 && now - s.lastDirectMs <= within.inMilliseconds)
        .toList()
      ..sort((a, b) => b.lastDirectMs.compareTo(a.lastDirectMs));
    return fresh.map((s) => s.callsign).toList();
  }

  /// What the archive made of a packet's signature (section 9.1).
  ///
  /// Fed by [XprsArchive], which verifies at flush — deliberately off the
  /// receive path, because a verify is a curve operation and this one is
  /// already paid for there. The monitor does no crypto of its own; it would
  /// be the same work twice, on the isolate that draws.
  ///
  /// A station heard only over the internet is not in [_stations] at all, so a
  /// verdict for one is dropped here rather than creating a sighting the air
  /// view never had.
  void recordVerdict(String callsign, XprsSigState state) {
    final st = _stations[callsign.trim().toUpperCase()];
    if (st == null) return;
    switch (state) {
      case XprsSigState.verified:
        st.sigVerified++;
      case XprsSigState.forged:
        st.sigForged++;
      case XprsSigState.unverified:
        st.sigUnverified++;
      case XprsSigState.unsigned:
        st.sigUnsigned++;
    }
    _bump();
  }

  /// Drop stations that have gone quiet. Called before rendering.
  void sweep({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final before = _stations.length;
    final gone = [
      for (final e in _stations.entries)
        if (now - e.value.lastMs > staleAfter.inMilliseconds) e.key
    ];
    for (final k in gone) {
      final s = _stations.remove(k)!;
      _recent[k] = (lastMs: s.lastMs, bearer: s.bearer);
    }
    _recent.removeWhere((_, r) => now - r.lastMs > rememberedFor.inMilliseconds);
    while (_recent.length > rememberedMax) {
      _recent.remove(_recent.keys.first);
    }
    _remote.removeWhere((_, t) => now - t > rememberedFor.inMilliseconds);
    if (_stations.length != before) _bump();
  }

  /// Stations heard within the last [rememberedFor] but not within
  /// [staleAfter] -- what [stationsJson]'s second section lists.
  Map<String, ({int lastMs, String bearer})> get recent =>
      Map.unmodifiable(_recent);

  /// An XPRS packet from [callsign] arrived over Reticulum. Remembered for
  /// [rememberedFor] as "on Reticulum" -- the third section of
  /// [stationsJson] -- and nowhere else: not the traffic ring, not the
  /// in-earshot table, not the this-hour memory. A station also heard on the
  /// air is listed as local and not here; the air is the better answer.
  void noteRemote(String callsign, {int? nowMs}) {
    final c = callsign.trim().toUpperCase();
    if (c.isEmpty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    _remote.remove(c); // re-insert: the map keeps insertion order, oldest first
    _remote[c] = now;
    while (_remote.length > rememberedMax) {
      _remote.remove(_remote.keys.first);
    }
    _bump();
  }

  Map<String, int> get remote => Map.unmodifiable(_remote);

  void clear() {
    _ring.clear();
    _stations.clear();
    _recent.clear();
    _remote.clear();
    _bump();
  }

  /// The stations, shaped as people-widget sections so the wapp renders them
  /// without parsing — the same contract `hal_mesh_devices` uses.
  String stationsJson({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    sweep(nowMs: now);
    final list = _stations.values.toList()
      ..sort((a, b) => b.lastMs.compareTo(a.lastMs));

    final items = list.map((s) {
      final tags = <String>[
        _ago(now - s.lastMs),
        s.bearer.toUpperCase(),
        if (s.peers != null) 'peers ${s.peers}',
        if (s.mail != null && s.mail! > 0) 'mail ${s.mail}',
        if (s.uptime != null) 'up ${s.uptime}',
        if (s.lifetime != null) 'life ${s.lifetime}',
      ];
      final sub = StringBuffer(s.bearer.toUpperCase());
      if (s.rssi != 0) sub.write(' - ${s.rssi} dBm');
      sub.write(' - ${s.packets} packet${s.packets == 1 ? "" : "s"}');
      return {
        'id': s.callsign,
        'title': s.callsign,
        'subtitle': sub.toString(),
        'tags': tags,
      };
    }).toList();

    // The second section: heard this hour, not in the last eleven minutes.
    // The same shape, so a wapp walks both the same way; fewer tags, because
    // a signal strength from forty minutes ago is not a fact about now.
    final recent = _recent.entries.toList()
      ..sort((a, b) => b.value.lastMs.compareTo(a.value.lastMs));
    final earlier = recent
        .map((e) => {
              'id': e.key,
              'title': e.key,
              'subtitle': e.value.bearer.toUpperCase(),
              'tags': [_ago(now - e.value.lastMs), e.value.bearer.toUpperCase()],
            })
        .toList();
    // The third section: reached us over Reticulum this hour, and not heard
    // on the air at all -- a station on the air is listed there, once.
    final remote = _remote.entries
        .where((e) => !_stations.containsKey(e.key) && !_recent.containsKey(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final onRns = remote
        .map((e) => {
              'id': e.key,
              'title': e.key,
              'subtitle': 'RNS',
              'tags': [_ago(now - e.value), 'RNS'],
            })
        .toList();
    return jsonEncode([
      {'title': 'Heard over the air (${items.length})', 'items': items},
      if (earlier.isNotEmpty)
        {'title': 'Heard this hour (${earlier.length})', 'items': earlier},
      if (onRns.isNotEmpty)
        {'title': 'On Reticulum (${onRns.length})', 'items': onRns},
    ]);
  }

  /// The ring, oldest first, as the wapp's traffic log.
  String trafficJson() => jsonEncode(_ring.map((s) => s.toJson()).toList());

  /// Counters for `/api/status`, so this is checkable without a wapp.
  Map<String, dynamic> statusJson() => {
        'revision': revision,
        'stations': _stations.length,
        'recent': _recent.length,
        'remote': _remote.length,
        'sightings': _ring.length,
        'bearers': {
          for (final b in kBearers)
            if (_stations.values.any((s) => s.bearer == b))
              b: _stations.values.where((s) => s.bearer == b).length,
        },
      };

  static String _ago(int ms) {
    final s = ms ~/ 1000;
    if (s < 60) return 'seen ${s}s ago';
    if (s < 3600) return 'seen ${s ~/ 60}m ago';
    return 'seen ${s ~/ 3600}h ago';
  }
}
