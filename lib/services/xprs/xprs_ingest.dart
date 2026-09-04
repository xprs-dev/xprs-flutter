/*
 * xprs_ingest — the one funnel every heard XPRS packet passes through.
 *
 * Display, archive and command handling used to be one call each at three
 * different receive sites, which is how they drift apart. Now a receive site
 * calls [heard] and this file decides who gets the packet:
 *
 *   monitor — unchanged, with its own bearer allowlist (internet never enters
 *             the live view, and a custody session is not a sighting)
 *   archive — the persistent spool (xprs_archive.dart), when the owner has it
 *             on, which is the default
 *   history — a `t:command cmd:history d:us` is an ask, not traffic (the
 *             responder registers itself in [onCommand])
 *
 * The Reticulum lane is different on purpose ([reticulum]): radio traffic is
 * bounded by radio range, internet traffic is not, so a packet arriving over
 * a hub is archived ONLY when its author declared this station as a mailbox
 * (`t:mailbox hold:` — docs/XPRS.md section 13.12) or the packet is mail to a
 * station that did. Without that rule a well-connected hub would spool the
 * whole mesh's chatter and fill its disk with strangers (section 36.3: a
 * station pushes to the indexers its operator CHOSE).
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';

import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_archive.dart';
import 'xprs_groups.dart';
import 'xprs_gossip.dart';
import 'xprs_monitor.dart';
import 'xprs_id.dart';
import 'xprs_outbox.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

class XprsIngest {
  XprsIngest._();

  /// Set by XprsHistoryServer so a heard command reaches the responder
  /// without this file importing it (and without the responder having to
  /// listen on three radios itself).
  static void Function(
    XprsPacket p, {
    required String selfBase,
    required String bearer,
  })?
  onCommand;

  /// Every heard `t:result`, for whoever asked the question it answers --
  /// the catch-up poller advances its watermark on these (36.10.1).
  static void Function(XprsPacket p)? onResult;

  /// Set by RnsService, which owns the callsign→key map, so a `t:identity`
  /// heard on any bearer lands in the same place a key learned from an
  /// announce does. Same reasoning as [XprsArchive.keyResolver]: this file
  /// stays free of the node.
  static void Function(String callsign, String pubkeyHex)? onIdentity;

  /// A station heard DIRECTLY (no `via:`), on a bearer a radio person would
  /// recognise. Set by MeshService to the release-on-hearing trigger of
  /// section 36.8.1 -- the receiver throttles and checks for held mail; this
  /// funnel only reports the fact.
  static void Function(String callsign, String bearer)? onDirectHeard;

  /// A `t:message` for a THIRD party, off the Reticulum lane -- somebody is
  /// handing this station mail to hold (36.7) or to move along (36.8.1).
  /// Set by MeshService to the custody park + forwarder.
  static void Function(String wire, String target)? onCarry;

  /// A verified `t:receipt … s:ack` heard on any bearer. Set by MeshService to
  /// the custody release.
  ///
  /// Every carrier holding the named message discards its copy — that is what
  /// drains a chain of custodians instead of delivering the same message five
  /// times (§36.8.1). It fires for a receipt addressed to ANYONE, not only to
  /// us: overhearing somebody else's acknowledgement is precisely how a
  /// third-party copy gets released, and §13.3 says so — "a station that
  /// overhears a receipt for a message it is carrying discards its copy, which
  /// is why a receipt is worth repeating even after the sender has seen it".
  static void Function(XprsPacket p)? onReceipt;

  /// A `t:message` addressed to us, on any bearer. Set by MeshService to the
  /// courier's delivery entry point, which verifies, unseals and hands it to
  /// the ordinary inbox. Injected the same way as [onIdentity] so this file
  /// stays free of the mesh.
  static void Function(XprsPacket p, String bearer)? onDeliver;

  /// Packets refused off the Reticulum lane for want of a declaration —
  /// the observable that says the admission rule is alive.
  static int refusedRns = 0;
  static int _lastRefuseLogMs = 0;

  /// The person, with any device suffix removed: `X1ABCD-1` -> `X1ABCD`
  /// (spec section 3.1). One definition, shared, so the person/device
  /// split cannot drift between the archive, the ingest and the server.
  /// Compose and air the `t:pong` for a heard `t:ping`.
  ///
  /// [bearer] is the lane it arrived on, and the answer prefers it: §36.0's
  /// freshest possible evidence of a working path back is the packet that just
  /// came over it. The publisher falls back to the fan-out when that bearer
  /// cannot carry the reply.
  static void _answerPing(XprsPacket p,
      {required String self, required String bearer}) {
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty || _base(from) == self) return;
    final n = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    var pong = XprsPacket.parse('t:pong f:$self d:$from '
        'ts:${n.year}-${two(n.month)}-${two(n.day)}_'
        '${two(n.hour)}:${two(n.minute)}:${two(n.second)} '
        'r:${xprsIdentifier(p)}');
    if (pong == null) return;
    final d = xprsProfileScalar();
    if (d != null) pong = xprsSign(pong, d);
    if (!pong.fits) return;
    pongsSent++;
    onAnswerPing?.call(pong.encode(), bearer);
  }

  /// Air a composed `t:pong`. Wired by the owner to the publisher, so the
  /// funnel does not reach into a transport itself.
  static void Function(String wire, String bearer)? onAnswerPing;

  /// Reachability tests answered, for the diagnostics.
  static int pongsSent = 0;

  static String _base(String c) => NostrCrypto.bareCallsign(c);

  /// The archive's name for how a packet arrived. A custody session and the
  /// overheard mesh both run over a BLE link — physically local, so they
  /// belong in the spool even though the monitor's sighting ring (rightly)
  /// refuses 'custody' as a bearer a person watches.
  static String _archiveBearer(String bearer) =>
      (bearer == 'mesh' || bearer == 'custody') ? 'ble' : bearer;

  /// Presence: true of a packet that says somebody is there and nothing else.
  ///
  /// These repeat forever by design -- that is what makes them presence -- so
  /// on a pocket device they are the whole storage cost and none of the value.
  /// They still reach XprsMonitor, which is what the graph, the Traffic screen
  /// and the station list read, so nothing on screen depends on spooling them.
  /// Chatter: traffic a station may reasonably decline to spool for strangers.
  ///
  /// **`identity` is deliberately NOT in this set.** It used to be, which meant
  /// a station that was not a super-archiver and had not opted into keeping
  /// chatter stored no key bindings at all — and a key binding is not chatter,
  /// it is the thing that makes every other packet from that station checkable.
  /// Without it this station cannot verify a signature (§9.1 leaves it
  /// `unverified`), cannot seal a private message to them (§9.2), cannot trust
  /// a receipt from them (§13.7.1 — measured on the bench as fifteen
  /// unverifiable receipts on a phone holding zero identities), and has nothing
  /// for `rebindFromArchive` to replay at startup, so the half-hour hole of
  /// §18.1 reopens on every restart.
  ///
  /// §18.1 says why the announcement is repeated at all: "a receiver that has
  /// never heard the announcement cannot check a signature or issue a
  /// challenge". Discarding it is discarding the reason it was sent.
  ///
  /// It is also cheap, and bounded — see `XprsArchive._collapseIdentities`.
  static bool _isPresence(String type) =>
      type == 'observation' || type == 'service';

  /// Whether this packet is worth the write.
  ///
  /// The responder already answers a `cmd:history` from XprsArchive.kXprsTalk
  /// when the asker names no `kind:` -- so without this the archive was
  /// storing, pruning and paying for rows the station had already decided it
  /// would never serve.
  static bool _worthKeeping(XprsPacket p, {required bool forUs}) {
    if (forUs) return true; // our own mail, whatever shape it takes
    if (!_isPresence(p.type)) return true; // conversation, always
    final prefs = PreferencesService.instanceSync;
    // A super-archiver's stock in trade IS the chatter: signed observations
    // are the wires a `cmd:history kind:observation only:X` replay serves
    // (36.9.4's bulk gossip). A super that discards them answers every such
    // ask with a 404 by construction, whatever its gossip table knows —
    // gossip stores digests, and a replay may only re-air original packets
    // (36.1).
    if (prefs?.xprsSuperArchiver ?? false) return true;
    return prefs?.xprsKeepChatter ?? false;
  }

  static bool get _archiveOn =>
      PreferencesService.instanceSync?.xprsArchive ?? true;

  /// A packet heard over the air or over a local link. The complete receive
  /// surface calls this: BLE 0x41, BLE 0x58, and the courier's session lane.
  static void heard(
    XprsPacket p, {
    required String bearer,
    required String selfCallsign,
    int rssi = 0,
  }) {
    XprsMonitor.instance.offer(
      p,
      bearer: bearer,
      selfCallsign: selfCallsign,
      rssi: rssi,
    );

    // Exact-callsign skip, NOT base: our own echo is noise, but another of
    // our devices (X1SELF-2, section 3.1) is a station whose traffic — and
    // whose cmd:history asks — are as real as anyone's.
    final self = selfCallsign.trim().toUpperCase();
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty || from == self) return;

    // A mailbox declaration heard on the street counts exactly like one that
    // arrived over a hub: the author is saying where their mail may rest.
    if (p.type == 'mailbox') XprsArchive.instance.recordMailboxDecl(p);

    // ── Gossip feeds (36.9.4) + the 36.8.1 release trigger ──────────────
    // Cheap checks first (performance.md 4.2): everything below is a map
    // lookup or an indexed upsert; the one curve operation is gated on a
    // hears: list actually being present AND the signer's key being known.
    final gb = _archiveBearer(bearer);
    // Our own radio is its own witness, and only a packet that reached us
    // unrelayed is evidence of that. A copy that came through somebody else
    // says nothing about whether WE can hear its author, so noteDirect and
    // the 36.8.1 release trigger stay behind the `via:` gate.
    if (!p.has('via')) {
      XprsGossip.instance.noteDirect(from, self, bearer: gb);
      try {
        onDirectHeard?.call(from, gb);
      } catch (e) {
        LogService.instance.add('XPRS: direct-heard hook failed: $e');
      }
    }

    // `hears:` is NOT behind that gate, and putting it there was the reason a
    // station could never see more than one hop of its own mesh.
    //
    // 36.9.4 admits "a verified observation whose `link:` names a short-range
    // bearer" -- it says nothing about how the packet reached the reader,
    // because it does not need to. The claim is the OBSERVER's, the signature
    // is what makes it theirs, and a relay cannot alter either: section 9.1
    // computes `sig:` with `via:` removed, so a relayed observation carries
    // exactly the assertion its author signed.
    //
    // Measured on the bench before this changed: the desktop knew
    // "X3GSLC hears X1VCVM" -- the T-Deck publishes that straight onto the
    // LAN -- but never "X1VCVM hears X3GSLC", because the phone is
    // Bluetooth-only and its own observation could only ever arrive relayed.
    // One direction of an asymmetric pair (10.6.5), thrown away at the door,
    // and with it every route TOWARD the phone.
    //
    // Every wall of 36.9.4 stands: the per-signer quota below, verified-only,
    // and L2 still written only when `link:` names a short-range bearer.
    if (p.type == 'observation' &&
        p.has('hears') &&
        XprsGossip.instance.wouldAcceptHears(from)) {
      final hears = (p['hears'] ?? '')
          .split(',')
          .map((c) => c.trim().toUpperCase())
          .where((c) => c.isNotEmpty)
          .toList();
      if (hears.isNotEmpty) {
        // The verify is the expensive step (a curve op, on this isolate)
        // and wouldAcceptHears above has already said the quota will admit
        // the claim — so it runs at most once per signer per quota window,
        // not once per beacon (performance.md 4.2).
        final verified =
            p.has('sig') &&
            xprsVerify(p, XprsArchive.instance.keyResolver?.call(from)) ==
                XprsSigState.verified;
        XprsGossip.instance.noteHears(
          from,
          hears,
          link: p['link'] ?? gb,
          verified: verified,
        );
      }
    }

    // `t:identity` (section 9.3) is a station publishing the key its callsign
    // signs with, and it is the only way to LEARN that binding off the air.
    // Without it every signature from a station we have never met stays
    // `unverified` — not because it is bad, but because nothing here could
    // check it.
    if (p.type == 'identity') _bindIdentity(from, p);

    // An act of authority in a closed group (section 26.3). One packet type
    // carries every one of them, and XprsGroups replays the record.
    //
    // It goes HERE, in the funnel, for the reason everything else does: this
    // is the one place every bearer reaches, so a group's roster is the same
    // whether the act arrived over BLE, LAN, or a custody session. Cheap --
    // the act is stored and the replay is redone only when one arrives, never
    // per message (docs/performance.md 8.7).
    if (p.type == 'moderate') XprsGroups.instance.offer(p);

    // The preference governs the INDEXER — other people's traffic. A packet
    // addressed to us is our own mail and is kept either way.
    final forUs =
        (_base(p['d'] ?? '').isNotEmpty &&
                _base(p['d'] ?? '') == _base(selfCallsign)) ||
            // A group act is addressed to the GROUP, so the test above says no
            // to every one of them and, with the indexer off, the record of a
            // group we belong to was dropped as somebody else's chatter. 26.4
            // replays a roster from those packets and nothing else: keep none
            // and the station forgets every group it is in on restart.
            XprsGroups.instance.concernsUs(p, _base(selfCallsign));
    if ((_archiveOn || forUs) && _worthKeeping(p, forUs: forUs)) {
      // `admit` only QUEUES. Whoever needs to know a row exists listens to
      // `XprsArchive.onStored`, which fires from the flush for rows the
      // transaction actually wrote — a forged packet is dropped there, and a
      // watermark advanced here would have stepped straight over it.
      XprsArchive.instance.admit(p, bearer: _archiveBearer(bearer), rssi: rssi);
    }

    // ANSWER A REACHABILITY TEST, ON WHATEVER BEARER IT ARRIVED ON.
    //
    // §7's `t:ping` / `t:pong` is a core type and the core already answered it
    // — inside xprs_tcp.dart, on the TCP socket, and nowhere else. So a ping
    // heard over BLE, LAN or Reticulum went unanswered, and the chat wapp grew
    // a `?PING`/`?PONG` dialect of its own, in the compact frame, with its own
    // TTL forwarding, to ask the question the core would not answer. Answering
    // here — in the one funnel every bearer reaches — is what makes that
    // dialect redundant rather than merely unwanted.
    //
    // `r:` names the ping's §5 identifier, so the asker can tell its answers
    // apart without a nonce of anybody's invention. Signed, like anything else
    // that speaks as this station.
    if (p.type == 'ping') {
      final to = _base(p['d'] ?? '');
      final self = _base(selfCallsign);
      // Undirected is a question to the room; directed to somebody else is
      // not ours to answer.
      if (self.isNotEmpty && (to.isEmpty || to == self)) {
        _answerPing(p, self: self, bearer: _archiveBearer(bearer));
      }
      return;
    }

    // And DELIVER it. Knowing a message is ours and only filing it is what
    // made a station's history replay invisible: the archive took it and
    // nothing else ever looked. This is the bearer-agnostic place for that —
    // every surface reaches this funnel, so BLE 0x58, BLE 0x41, LAN UDP and
    // TCP are all covered by one call instead of a tap per transport.
    //
    // Cheap checks first: this runs for every inbound packet, and the
    // verification behind it is a curve operation (docs/performance.md 4.2).
    //
    // `forUs` is NOT the question here. It answers "do we keep this", and it
    // says yes to a closed group's traffic on purpose (concernsUs, above) so a
    // group we belong to has a record. Reusing it as the DELIVERY gate made
    // "keep it" and "show it to a person" one decision, and every group post
    // arrived as private correspondence from whoever sent it -- the courier
    // below keys the thread on the SENDER, because by then `d:` is gone.
    // `xprsRendersToPerson` asks the whole question: a message, addressed to a
    // person.
    if (forUs && onDeliver != null && xprsRendersToPerson(p)) {
      try {
        onDeliver!(p, _archiveBearer(bearer));
      } catch (e) {
        LogService.instance.add('XPRS: delivery failed: $e');
      }
    }

    // …and CARRY it when it is somebody else's mail.
    //
    // This is the other half of what the funnel owes, and it was missing on
    // every bearer but one. `onCarry` was called from `XprsIngest.reticulum`
    // and nowhere else, so a station carried mail that arrived over the
    // internet and carried nothing at all that arrived over a radio — while
    // `mesh_service` asserted the opposite in a comment, pointing at a BLE tap
    // that is wired to subtype 0x41 only. XPRS airs on 0x58, so third-party
    // mail heard on the XPRS lane was neither parked nor forwarded, and
    // nothing anywhere said so: custody is invisible when it does not happen,
    // because nothing is refused.
    //
    // Only a 1:1 to a station is custody material — a group is an address
    // several stations read (6.3) and is aired, not couriered.
    if (!forUs && p.type == 'message' && onCarry != null) {
      final target = (p['d'] ?? '').trim();
      if (xprsAddressesStation(target)) {
        try {
          onCarry!(p.encode(), target.toUpperCase());
        } catch (e) {
          LogService.instance.add('XPRS: carry failed: $e');
        }
      }
    }

    try {
      onCommand?.call(
        p,
        selfBase: _base(selfCallsign),
        bearer: _archiveBearer(bearer),
      );
    } catch (e) {
      LogService.instance.add('XPRS: command handling failed: $e');
    }

    if (p.type == 'result') {
      try {
        onResult?.call(p);
      } catch (e) {
        LogService.instance.add('XPRS: result handling failed: $e');
      }
    }

    // A receipt releases held mail — ours and other people's. Deliberately not
    // gated on `forUs`: §13.3 has a carrier discard its copy on OVERHEARING the
    // acknowledgement, which is the only way a chain of custodians drains.
    if (p.type == 'receipt') {
      try {
        onReceipt?.call(p);
      } catch (e) {
        LogService.instance.add('XPRS: receipt handling failed: $e');
      }
    }
  }

  /// Identity packets verified in the current minute, and when that started.
  /// Verification is a curve operation and this runs on the receive path, so a
  /// station cannot be made to spend the afternoon checking invented callsigns.
  static int _idChecks = 0;
  static int _idWindowMs = 0;
  static const int _idChecksPerMinute = 20;

  /// Record a `k:npub…` against the callsign that signed for it.
  ///
  /// **Verified against the key it carries**, which is the whole point: a
  /// station saying "this is my key" must prove it holds that key, and it can,
  /// because the packet is signed with it. An unsigned or badly signed identity
  /// binds nothing.
  ///
  /// That still does not prove the CALLSIGN is theirs — nothing on an open
  /// bearer can — so the binding is [first-wins]: a later packet naming the
  /// same callsign with a different key is ignored. Overwriting would let
  /// anyone re-point a callsign by shouting last, and since the archive DROPS
  /// packets whose signature fails against the key it holds, that is enough to
  /// make a station's genuine traffic look forged and be thrown away.
  /// Re-bind every `t:identity` the archive already holds.
  ///
  /// The key bindings live in memory, and a `t:identity` is re-announced only
  /// every thirty minutes (18.1). So a station that restarts has no key for
  /// anybody until the next round of announcements -- and could not seal a
  /// private message (9.2), verify a signature, or check a nickname for up to
  /// half an hour, having heard and STORED the very packet that says so.
  ///
  /// The stored packets are signed, so replaying them through the same binding
  /// path costs nothing in trust: [_bindIdentity] verifies each one against the
  /// key it carries exactly as it did when the packet arrived off the air, and
  /// first-wins still applies. No airtime is spent.
  static int rebindFromArchive({int limit = 200}) {
    var n = 0;
    try {
      // Oldest first, so first-wins reproduces the order the packets actually
      // arrived in rather than inverting it.
      final rows = XprsArchive.instance
          .query(types: const ['identity'], limit: limit)
          .reversed;
      for (final r in rows) {
        final wire = r['wire'];
        if (wire is! String) continue;
        final p = XprsPacket.parse(wire);
        if (p == null || p.type != 'identity') continue;
        final from = p['f'];
        if (from == null || from.isEmpty) continue;
        // The rate limiter below guards the AIR, where identities arrive from
        // strangers; this replay is our own disk and is bounded by `limit`.
        _idChecks = 0;
        _idWindowMs = DateTime.now().millisecondsSinceEpoch;
        _bindIdentity(from, p);
        n++;
      }
    } catch (e) {
      LogService.instance.add('XPRS: could not re-bind identities — $e');
    }
    if (n > 0) {
      LogService.instance.add(
        'XPRS: re-bound $n stored identity announcement(s)',
      );
    }
    return n;
  }

  static void _bindIdentity(String callsign, XprsPacket p) {
    final hook = onIdentity;
    final npub = p['k'];
    if (hook == null || npub == null || !npub.startsWith('npub1')) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _idWindowMs > 60000) {
      _idWindowMs = now;
      _idChecks = 0;
    }
    if (++_idChecks > _idChecksPerMinute) return;

    try {
      final hex = NostrCrypto.decodeNpub(npub);
      if (hex.length != 64) return;
      final pub = Uint8List.fromList(HEX.decode(hex));
      if (xprsVerify(p, pub) != XprsSigState.verified) {
        LogService.instance.add(
          'XPRS: identity from $callsign does not sign for its own key',
        );
        return;
      }
      hook(callsign, hex);
    } catch (_) {
      // A malformed npub is a malformed field, and section 4 says skip it.
    }
  }

  /// One of OUR wires, at the moment it was put on a bearer — or attempted and
  /// carried by none, in which case [bearer] is `none`. Archived with `own=1`
  /// so a `cmd:history` asked of the author can replay the author, which is
  /// the whole reason a station keeps its own log (section 36.5).
  ///
  /// **This is the single recorder for outbound traffic, and it is not
  /// optional.** It ignores the `xprsArchive` preference on purpose: that
  /// preference governs whether this station indexes OTHER people's traffic,
  /// where the storage cost and the choice actually live. Switching the
  /// indexer off must not stop a station keeping its own log.
  ///
  /// Every transmit primitive calls this. A new bearer that does not is a
  /// bearer whose traffic silently leaves no trace.
  static void own(String wire, {required String bearer}) {
    final p = XprsPacket.parse(wire);
    if (p == null) return;
    // Our own log stays complete for everything a `cmd:history` asked of US
    // could replay -- section 36.5, and the reason this ignores the indexer
    // preference. Our own PRESENCE is the exception: nobody has ever asked a
    // phone to replay its own beacons, and on the bench they were 139 of the
    // newest 200 rows in this device's archive.
    // Remember a 1:1 we sent, so a `t:receipt r:<id>` naming it has something
    // to advance. Keyed on the §5 identifier, so the copy that went out over
    // Reticulum and the copy that went out over BLE are one row.
    if (p.type == 'message' && xprsAddressesStation(p['d'] ?? '')) {
      XprsOutbox.instance
          .noteSent(xprsIdentifier(p), (p['d'] ?? '').trim().toUpperCase());
    }
    if (!_worthKeeping(p, forUs: false)) return;
    XprsArchive.instance.admit(p, bearer: _archiveBearer(bearer), own: true);
  }

  /// An XPRS datagram off the Reticulum 'xprs' tag. Never shown as a sighting
  /// (the monitor's no-internet invariant is structural, and this lane does
  /// not call it), and archived only under the declaration rule above.
  ///
  /// [bearer] is where the datagram actually travelled, which the Reticulum
  /// node knows from the interface it arrived on: a phone on the same LAN, a
  /// board over Bluetooth or LoRa, or `rns` when it genuinely came off a hub.
  /// It is the ARCHIVE label only -- what a person is shown about a message.
  /// Every policy below still asks the Reticulum lane's questions (declaration
  /// gate, `link:`-decides gossip, the command lane's reply route), because
  /// this lane's rules are about how the packet was HANDED OVER, not about
  /// which radio carried it.
  static void reticulum(
    String from,
    Uint8List payload, {
    String bearer = 'rns',
  }) {
    final p = XprsPacket.parse(utf8.decode(payload, allowMalformed: true));
    if (p == null) return;
    final self = _base(
      XprsArchive.instance.selfCallsign.isEmpty
          ? ''
          : XprsArchive.instance.selfCallsign,
    );
    final fromC = _base(p['f'] ?? '');
    if (fromC.isEmpty || (self.isNotEmpty && fromC == self)) return;
    // A station reached us over Reticulum: on the list, under that name and
    // no other (the air is [heard]'s, and stays so).
    XprsMonitor.instance.noteRemote(fromC);

    // The hub lane serves too (docs/XPRS.md 36.0: the archiver role does not
    // change with the bearer). Commands and results route to the same hooks
    // every radio feeds -- until they did, a cmd:history that crossed the
    // internet was at best archived and never answered, and the server's
    // "refuse rns" counter guarded a path nothing reached. The DECLARATION
    // gate below is deliberately untouched: it governs what this station
    // spools off the internet, not what it will say.
    if (self.isNotEmpty) {
      if (p.type == 'command') {
        try {
          onCommand?.call(p, selfBase: self, bearer: 'rns');
        } catch (e) {
          LogService.instance.add('XPRS: rns command handling failed: $e');
        }
      } else if (p.type == 'result') {
        try {
          onResult?.call(p);
        } catch (e) {
          LogService.instance.add('XPRS: rns result handling failed: $e');
        }
      }
    }

    // `t:identity` binds callsign to key (9.3), and it is a publication a
    // gateway passes verbatim (36.1). Without this the internet lane could
    // never verify anything: a mailbox declaration arriving over the hubs
    // was refused for want of a key that had also arrived over the hubs --
    // two strangers meeting on the internet could not bootstrap at all.
    if (p.type == 'identity') _bindIdentity(fromC, p);

    // A RECEIPT OFF THE INTERNET LANE. This branch did not exist, so a
    // `t:receipt` arriving over Reticulum released nothing and was not even
    // counted -- and Reticulum is exactly the lane a receipt takes for a
    // message that was delivered over it. The custody a receipt is supposed
    // to end therefore stayed parked whenever the two stations were talking
    // over the internet rather than over a radio.
    //
    // Same hook the radio lane uses, and ungated on "addressed to us" for the
    // same reason: §13.3 has a carrier discard its copy on OVERHEARING an
    // acknowledgement, which is how a chain of custodians drains instead of
    // delivering the same message five times.
    if (p.type == 'receipt') {
      try {
        onReceipt?.call(p);
      } catch (e) {
        LogService.instance.add('XPRS: receipt handling failed (rns): $e');
      }
      return;
    }

    // Gossip off the internet lane (36.9.4): a replayed observation arriving
    // over the hubs is exactly the "asker verifies and caches into its own
    // L3" step — the answer to a super-archiver ask lands HERE, not on any
    // radio, and without this feed the ask was paid for and the answer
    // discarded. noteHears' walls hold unchanged: an unverified claim feeds
    // nothing, and L2 stays radio-truth-only because the packet's own
    // `link:` decides — this lane's fallback is 'rns', which is not a
    // short-range bearer, so an internet arrival with no radio claim can
    // never write the durable layer.
    if (p.type == 'observation' &&
        p.has('hears') &&
        XprsGossip.instance.wouldAcceptHears(fromC)) {
      final hears = (p['hears'] ?? '')
          .split(',')
          .map((c) => c.trim().toUpperCase())
          .where((c) => c.isNotEmpty)
          .toList();
      if (hears.isNotEmpty) {
        // Quota peek first, verify second — same order as the radio lane,
        // same reason (performance.md 4.2).
        final verified =
            p.has('sig') &&
            xprsVerify(p, XprsArchive.instance.keyResolver?.call(fromC)) ==
                XprsSigState.verified;
        XprsGossip.instance.noteHears(
          fromC,
          hears,
          link: p['link'] ?? 'rns',
          verified: verified,
        );
      }
    }

    if (p.type == 'mailbox') {
      // Acting on it requires a verified signature (13.12); recordMailboxDecl
      // enforces that. A declaration naming us is itself worth keeping.
      if (XprsArchive.instance.recordMailboxDecl(p) && _archiveOn) {
        XprsArchive.instance.admit(p, bearer: bearer);
      }
      return;
    }
    final toC = _base(p['d'] ?? '');

    // Addressed to us: our own mail, kept with no declaration from anyone and
    // regardless of the indexer preference. The declaration rule below exists
    // to stop this station spooling the whole Reticulum lane on other
    // people's behalf; it was never meant to refuse our own post.
    //
    // A closed group we belong to counts as ours for exactly the same reason,
    // and by the same test the air lane uses. Without this a group post that
    // arrived ONLY over Reticulum fell past here to the declaration rule and,
    // with the indexer preference off, was dropped -- so the room would have
    // gone quiet for anybody not also in LAN or BLE range. It survived on the
    // bench only because the LAN copy arrived too.
    if (toC.isNotEmpty && toC == self ||
        XprsGroups.instance.concernsUs(p, self)) {
      XprsArchive.instance.admit(p, bearer: bearer);
      // AND DELIVER IT. This lane archived a message addressed to us and
      // stopped, because `onDeliver` was wired on the radio lane and had no
      // counterpart here at all -- so a 1:1 that arrived over Reticulum was
      // filed in the spool and never reached a person, with no log line and
      // no counter to say so. The bearer a message came in on is not
      // supposed to decide whether it is shown; that is the whole point of
      // one funnel, and this branch was the proof it was not one.
      //
      // Same gate as the radio lane, deliberately: `xprsRendersToPerson`
      // asks the whole question -- a message, addressed to a person -- so a
      // group post that `concernsUs` keeps is still archived and NOT
      // delivered as private correspondence.
      if (onDeliver != null && xprsRendersToPerson(p)) {
        try {
          onDeliver!(p, bearer);
        } catch (e) {
          LogService.instance.add('XPRS: delivery failed (rns): $e');
        }
      }
      return;
    }

    // Mail for a third party: the custody question, not the archive one.
    // The park-or-not decision (budgets, quotas, 31.3) belongs to the
    // receiver; this lane only reports that mail arrived seeking a holder.
    //
    // A group is not mail: it has no mailbox to carry toward, and
    // `docs/store-and-forward.md` is explicit that groups are never carried.
    if (p.type == 'message' && xprsAddressesStation(toC) && toC != self) {
      try {
        onCarry?.call(p.encode(), toC);
      } catch (e) {
        LogService.instance.add('XPRS: rns carry hook failed: $e');
      }
    }

    if (!_archiveOn) return;

    // A super-archiver keeps the chatter (36.12.1): observations and
    // identities are the wires its bulk-gossip replays serve, they are
    // publications a gateway passes verbatim (36.1), and on a super they
    // mostly ARRIVE over this lane — the boards dial in over Reticulum.
    // The declaration rule below guards against spooling other people's
    // MAIL off the internet; presence is not mail, and a super that
    // refused it could never answer `kind:observation` about anyone.
    final superKeeps =
        (PreferencesService.instanceSync?.xprsSuperArchiver ?? false) &&
        (p.type == 'observation' ||
            p.type == 'identity' ||
            p.type == 'service');

    // A status is this network's public post (section 27), and a reaction is
    // how it earns its place (6.5). Both are PUBLICATIONS -- meant to be
    // passed on and read by strangers -- so the declaration rule, which
    // exists to stop this station spooling other people's MAIL off the
    // internet, does not apply to them. Without this the launcher only ever
    // saw what the radio heard, and a station one hop away over a hub was
    // invisible.
    // What a publication IS on this lane: something written for everybody.
    // A status (27) and the reaction that judges it (6.5) always are, and so
    // is a `t:message` with NO `d:` -- that is the broadcast chat every
    // station is meant to read, the Global chat room in the chat wapp. The
    // declaration rule exists to stop this station spooling other people's
    // MAIL off the internet, and mail is precisely the case that HAS a `d:`;
    // it is still gated, still routed through custody. Without this, two
    // stations on different internet connections could see each other's
    // presence and never each other's words.
    final publication =
        p.type == 'status' ||
        p.type == 'reaction' ||
        (p.type == 'message' && toC.isEmpty);

    final admitted =
        superKeeps ||
        publication ||
        XprsArchive.instance.hasActiveDecl(fromC) ||
        (toC.isNotEmpty && XprsArchive.instance.hasActiveDecl(toC));
    if (!admitted) {
      refusedRns++;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastRefuseLogMs > 60000) {
        _lastRefuseLogMs = now;
        LogService.instance.add(
          'XPRS archive: rns refused (no declaration from $fromC — '
          '$refusedRns refused so far)',
        );
      }
      return;
    }
    // Same rule as the radio lanes: the watermark moves from
    // `XprsArchive.onStored`, once the row exists.
    XprsArchive.instance.admit(p, bearer: bearer);
  }
}
