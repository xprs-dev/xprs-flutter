/*
 * MeshCourier — the core's store-and-forward lane.
 *
 * Delivery is a transport problem, not a chat feature. When the core cannot
 * reach a destination directly, it hands a copy to whatever device is nearby
 * and lets the mesh carry it (docs/mesh.md §6). Wapps do not participate: they
 * hand the core a message, and the core calls them back when one arrives.
 *
 * Two halves:
 *
 *   OUT  [arm] every 1:1 the core sends. Twenty seconds later, if the message
 *        is still sitting in the retry queue, there is no working path — a peer
 *        on the LAN or reachable through a hub acknowledges in well under a
 *        second — so a compact copy goes on the air for any custodian to hold.
 *        Deciding up front does not work: the observed-node list calls a device
 *        "seen" because a hub replayed its announce cache, and a learned path
 *        outlives the peer that taught it by hours. Both were measured against
 *        a phone with its radios switched off.
 *
 *   IN   frames addressed to us — overheard on air or handed over an MSP
 *        session by a custodian — are verified, decrypted, and injected into
 *        the LXMF inbox as though they had arrived over Reticulum. The wapp
 *        that owns the conversation renders it through the path it already
 *        uses; nothing about custody reaches it.
 *
 * Wire: XPRS (docs/XPRS.md).
 *
 *   t:message f:FROM d:TO ts:2026-08-08_14:26:40 sig:<60> m:body
 *   t:message f:FROM d:TO ts:2026-08-08_14:26:40 x:<sealed> sig:<60>
 *
 * The envelope is deliberately public — a carrier that cannot read who a
 * message is for cannot decide whom to hand it to — while the body is sealed to
 * the recipient's key whenever we hold one.
 *
 * Three fields of the old compact frame are gone. `am:` because the identifier
 * is derived from the packet (section 5), so nothing announces its own id and a
 * relayed copy keeps the one it was born with. `sd:` because the sender's LXMF
 * address is a pure function of their public key, which is safer than trusting
 * an address written on the wire by whoever sent it. `np:` because a sealed
 * body already proves who the copy is for.
 *
 * We EMIT only XPRS. We still READ the compact frame (see mesh_frame.dart),
 * because the chat wapp and the ESP32 dongle still speak it and custody sees
 * every advert on the air. That half goes away when they are ported.
 */
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:crypto/crypto.dart' show sha256;

import '../../connections/bluetooth/ble_service.dart';
import '../../util/xprs_crypto.dart';
import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../../profile/profile_service.dart';
import '../reticulum/rns_service.dart';
import '../xprs/xprs_vocab.dart';
import '../xprs/xprs_ingest.dart';
import '../xprs/xprs_body.dart';
import '../xprs/xprs_publisher.dart';
import '../xprs/xprs_receipt.dart';
import '../xprs/xprs_id.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_parts.dart';
import '../xprs/xprs_sig.dart';
import 'mesh_custody.dart';
import 'mesh_frame.dart';
import 'mesh_store.dart';
import 'mesh_service.dart';

/// One message waiting to find out whether it needs a carrier.
class _Armed {
  _Armed(this.destHex, this.text, this.armedMs,
      {this.waitFirst = true, this.private = true});
  final String destHex;
  final String text;
  final int armedMs;

  /// The form the SENDER chose for this one message (docs/XPRS.md section 9.2).
  /// Private is the default for a direct message (9.4). It travels with the
  /// message rather than being remembered per peer, because the wire form is
  /// per packet and either side may switch at any point.
  final bool private;

  /// Give the Reticulum lane its head start before handing the message to a
  /// carrier. False when we can hear the recipient's own radio: there is
  /// nothing to wait for, and waiting is the whole delay.
  final bool waitFirst;
  bool aired = false;
}

class MeshCourierCounters {
  static int armed = 0;
  static int aired = 0;
  static int refusedTooLong = 0;

  /// Messages we declined to air because the sender asked for privacy and we
  /// could not provide it. Counted rather than silently downgraded — see the
  /// refusal branch in `_air`.
  static int refusedNoSeal = 0;

  /// Sealed messages that reached us and would not open. Shown to the operator
  /// rather than dropped, so this is a diagnostic and not a loss count.
  static int ingestSealedUnreadable = 0;
  static int refusedNoIdentity = 0;
  static int ingested = 0;
  static int ingestDropped = 0;

  static Map<String, dynamic> json() => {
        'armed': armed,
        'aired': aired,
        'refusedTooLong': refusedTooLong,
        'refusedNoIdentity': refusedNoIdentity,
        'ingested': ingested,
        'ingestDropped': ingestDropped,
      };
}

class MeshCourier {
  MeshCourier._();
  static final MeshCourier instance = MeshCourier._();

  /// Wait before airing a copy. The direct-link attempt inside sendLxmf gives
  /// up at 10s, so this is "the send has definitively failed", not a guess.
  static const Duration wait = Duration(seconds: 20);

  /// Stop caring: past this the retry ladder owns the message.
  static const Duration giveUp = Duration(minutes: 15);

  /// A frame a custodian cannot take whole is worse than no frame at all: the
  /// ESP32 parks up to BLEMESH_SCF_FRAME_MAX (252), so anything larger would be
  /// carried for days by the phones and dropped by the dongle you were counting
  /// on. Refuse at 240 and say so.
  static const int maxWire = 240;

  final List<_Armed> _armed = [];
  Timer? _pump;

  /// Also used by the ingest side to keep the same seen-set as the wapp bubble
  /// dedup would: a message that reaches us twice (aired copy + custody
  /// handover) must appear once.
  final Set<String> _ingested = <String>{};

  /// Has this message already been handed to the wapp, EVER (within the
  /// store's ~24h received window)?
  ///
  /// The in-memory set alone was a process-lifetime guard over a persistent
  /// stream: held mail is re-aired until a receipt ends custody, and the spool
  /// replays across a restart, so the same message was ingested again after
  /// every launch -- landing in the conversation a second time, bumping the
  /// unread count and raising another notification for something the user had
  /// already read. MeshStore's received_ams ring is the durable half, and is
  /// already the "we have this one" record the beacon bloom is built from.
  bool _alreadyDelivered(String key) =>
      _ingested.contains(key) || MeshStore.instance.wasReceived(key);

  /// Remember it only once it has actually reached the wapp. A packet held for
  /// a key that has not arrived yet must stay deliverable.
  void _noteDelivered(String key) {
    _ingested.add(key);
    if (_ingested.length > 512) _ingested.remove(_ingested.first);
    MeshStore.instance.recordReceivedAm(key);
  }

  /// Note a 1:1 the core just sent over LXMF. Cheap and unconditional — the
  /// pump decides, twenty seconds later, whether it needed a carrier.
  void armLxmf({
    required String destHex,
    required String text,
    bool waitFirst = true,
    bool private = true,
  }) {
    if (destHex.isEmpty || text.isEmpty) return;

    // ONE MESSAGE, ONE ARMING. `sendLxmf` arms twice for the same send: once
    // eagerly when it can hear the recipient's own radio, and once
    // unconditionally at the end. Both carry the same text, and on the
    // plaintext path each arming SEALED IT AGAIN -- fresh nonce, fresh
    // timestamp, so one message became two packets with two §5 identifiers.
    // `sendLxmf`'s own comment says the second copy "is deduplicated on the
    // derived identifier", which was true right up until the identifier
    // stopped being derived from anything stable.
    //
    // The eager arming wins where they differ: it exists because the peer is
    // in earshot right now, and waiting twenty seconds to discover that is
    // the delay it was added to remove.
    final dup = _armed.indexWhere(
        (e) => e.destHex == destHex && e.text == text && e.private == private);
    if (dup >= 0) {
      if (!waitFirst && _armed[dup].waitFirst) {
        _armed[dup] = _Armed(destHex, text, _armed[dup].armedMs,
            waitFirst: false, private: private);
      }
      return;
    }

    _armed.add(_Armed(destHex, text, DateTime.now().millisecondsSinceEpoch,
        waitFirst: waitFirst, private: private));
    MeshCourierCounters.armed++;
    _pump ??= Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  void _tick() {
    _retryUnresolved();
    if (_armed.isEmpty && _unresolved.isEmpty) {
      _pump?.cancel();
      _pump = null;
      return;
    }
    if (_armed.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _armed.removeWhere((a) {
      final age = now - a.armedMs;
      if (a.waitFirst && age < wait.inMilliseconds) return false;
      if (age > giveUp.inMilliseconds) return true;
      // Delivered while we waited: nothing to hand on.
      if (RnsService.instance.lxmfPendingFor(a.destHex) <= 0) return true;
      _air(a);
      return true;
    });
  }

  void _air(_Armed a) {
    final ble = BleService.instance;
    if (!ble.poweredOn) return;
    final self = MeshService.instance.tableCallsign.trim();
    if (self.isEmpty) return;

    final peer = RnsService.instance.identityFor(a.destHex);
    final call = (peer['callsign'] ?? '').trim();
    if (call.isEmpty) {
      MeshCourierCounters.refusedNoIdentity++;
      LogService.instance.add(
          'Courier: no callsign for ${_short(a.destHex)} — nothing to address '
          'a carrier with');
      return;
    }
    final npub = (peer['npub'] ?? '').trim();

    // ALREADY A PACKET? CARRY IT, DO NOT RE-AUTHOR IT.
    //
    // `sendLxmf` arms this courier with whatever it was asked to send, and on
    // the publisher's path that is a finished XPRS wire -- `_ReticulumBearer`
    // is called once per part (§6.6) and hands each part's own encoded
    // packet. Sealing that as the BODY of a fresh `t:message` wrapped a
    // packet inside a packet, and did it once per part, so one 3-part message
    // became nine or more on the air, each with fresh ciphertext, a fresh
    // timestamp and therefore a fresh §5 identifier.
    //
    // Measured on the bench (2026-09-01): 40 messages produced 394 packets
    // carrying 394 distinct identifiers. Nothing downstream could collapse
    // them -- a `t:receipt` names ONE identifier, so an acknowledgement freed
    // one copy of thirty, custody never drained, the store overflowed and the
    // row cap shed real mail. §31.1 says it plainly: a retry is not a new
    // packet. Neither is a carried copy.
    //
    // `deliverXprs` still unwraps nested wires on the way in, which is how
    // this stayed invisible: the receiver was quietly repairing what the
    // sender broke. That recovery stays for peers still running the old
    // build; it is no longer something we rely on.
    final already = carriableAsIs(a.text);
    if (already != null) {
      _park([already.bytes], call: already.to, sealed: already.sealed);
      return;
    }

    // Build the body in the form the SENDER chose for this one message
    // (docs/XPRS.md section 9.2 -- `x:` sealed, `m:` plain; the wire form is
    // the whole statement and nothing is negotiated).
    final built = xprsBuildDirect(
      head: XprsPacket.parse('t:message f:$self d:$call ts:${_nowIso()}')!,
      text: a.text,
      private: a.private,
      recipientKeyHex: npub,
    );
    if (!built.ok) {
      // A private message NEVER quietly becomes a plain one. Section 36.8 is
      // why this is correctness and not caution: "Sealed mail travels on the
      // strength of the seal ... Clear mail is released only to a declared
      // holder or fetched by the recipient itself. Plaintext is disclosure."
      // Every carrier that touches the two treats them differently, so airing
      // the clear text would put the message under release rules its author
      // did not choose -- and say nothing about having done so.
      //
      // The copy stays where it is. LXMF still holds it, the retry ladder still
      // runs, and the recipient's next identity announcement (9.3) supplies the
      // key that makes a sealed copy possible.
      MeshCourierCounters.refusedNoSeal++;
      LogService.instance.add(
          'Courier: not airing $call in the clear — ${_why(built.refusal!)}');
      // Section 18.1: ask for the key rather than waiting up to thirty minutes
      // for the next announcement. The message stays held; the next attempt
      // seals it.
      if (built.refusal == XprsSealRefusal.noRecipientKey) {
        unawaited(XprsPublisher.instance.askIdentity(call));
      }
      return;
    }
    // One wire unless the body had to split (6.6); parts are aired in order.
    _park([for (final p in built.packets) Uint8List.fromList(utf8.encode(p.encode()))],
        call: call, sealed: built.privacy == XprsPrivacy.sealed);
  }

  /// Park [wires] for custody and file our own copy.
  ///
  /// Shared by both routes into the store: a message this station composed,
  /// and a finished packet it is carrying unchanged. One implementation, so
  /// the two cannot drift into parking under different rules.
  /// Drop everything armed or held and stop the pump.
  ///
  /// For tests, and named the way `XprsMonitor` and `XprsGossip` name theirs.
  /// Arming starts a five-second timer that ends in `_air`, which reaches for
  /// the radio; a unit test that leaves one running has a live timer touching
  /// singletons long after the test that made it has finished.
  @visibleForTesting
  void debugReset() {
    _pump?.cancel();
    _pump = null;
    _armed.clear();
    _unresolved.clear();
  }

  /// The bytes to carry when [text] is ALREADY a finished packet, or null
  /// when it is a person's words that still have to be made into one.
  ///
  /// Only a `t:message` addressed to a station qualifies: a group post is
  /// aired, not couriered (§6.3), and a status or a command is not custody
  /// material at all. Carrying the bytes unchanged is what keeps the §5
  /// identifier — and therefore every dedup, receipt and custody release —
  /// pointing at one message instead of one per attempt.
  static CarriedWire? carriableAsIs(String text) {
    final wire = text.trim();
    final p = XprsPacket.parse(wire);
    if (p == null || p.type != 'message') return null;
    final to = (p['d'] ?? '').trim();
    if (!xprsAddressesStation(to)) return null;
    return CarriedWire(
      bytes: Uint8List.fromList(utf8.encode(wire)),
      to: to.toUpperCase(),
      sealed: p.has('x'),
    );
  }

  void _park(List<Uint8List> wires,
      {required String call, required bool sealed}) {
    final over = wires.where((w) => w.length > maxWire).toList();
    if (over.isNotEmpty) {
      MeshCourierCounters.refusedTooLong++;
      LogService.instance.add(
          'Courier: ${over.first.length}B is more than a carrier can hold '
          '($maxWire) — not aired');
      return;
    }
    // PARKED, not aired.
    //
    // This used to broadcast the message itself: registered on the advert bus
    // for five minutes and refreshed twice inside that, so a passer-by might
    // catch a copy. That spent the shared channel on a message almost every
    // listener had no use for, and spent it again on every refresh, while the
    // bus rotates through all registered frames — so each extra copy also stole
    // airtime from the beacons that make the mesh work at all.
    //
    // The beacon now says `mail:N` instead (docs/XPRS.md §10.6.5). A neighbour
    // that can actually reach the recipient opens a session and takes custody;
    // everybody else spends nothing. Six bytes on a frame already on the air,
    // in place of a repeating broadcast per message.
    //
    // Parking is explicit here because it used to be a side effect of
    // `enqueueAdvert` — the custody tap parked our own outbound copy on its way
    // to the radio. No advert, no tap, so the copy is offered directly.
    for (final wire in wires) {
      MeshCustodyDelegate.onAirFrame(wire, outbound: true);
      // Ours: it goes in our own log whether or not a carrier ever picks it up.
      // `custody` is where it is, not a radio it went out on.
      XprsIngest.own(utf8.decode(wire), bearer: 'custody');
    }
    MeshCourierCounters.aired++;
    final bytes = wires.fold<int>(0, (n, w) => n + w.length);
    LogService.instance.add(
        'Courier: no path to $call — ${bytes}B parked for custody '
        '(${sealed ? "sealed" : "plain"}'
        '${wires.length > 1 ? ", ${wires.length} parts" : ""}), '
        'beacon will advertise it');
  }

  static String _why(XprsSealRefusal r) => switch (r) {
        XprsSealRefusal.noRecipientKey =>
          'no key for them yet (their t:identity has not been heard)',
        XprsSealRefusal.noOwnKey => 'this station has no key to seal with',
        XprsSealRefusal.cipherFailed => 'the cipher failed',
        XprsSealRefusal.amateurBand =>
          'a sealed body may not go onto amateur spectrum (9.4)',
        XprsSealRefusal.tooLong => 'it does not fit, even split',
      };

  /// `YYYY-MM-DD_HH:MM:SS` in UTC (docs/XPRS.md section 4.8).
  static String _nowIso() {
    final t = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// The signature covers `callsign|<everything before " ~">` — the same
  /// canonical form the chat wapp signs and the host verifier checks, so a
  /// carried copy and a directly-delivered one verify identically.
  bool _verify(String npub, String from, String core, String sigStr) {
    try {
      final pubHex = NostrCrypto.decodeNpub(npub);
      final sig = XprsCrypto.b85decode(sigStr);
      if (pubHex.isEmpty || sig == null || sig.length != 48) return false;
      final m = Uint8List.fromList(
          sha256.convert(utf8.encode('$from|$core')).bytes);
      return XprsCrypto.verify(
          m, sig, Uint8List.fromList(HEX.decode(pubHex)));
    } catch (_) {
      return false;
    }
  }

  // The signing key lives in ONE place now: xprsProfileScalar (xprs_sig.dart),
  // shared with the XPRS publisher.
  BigInt? _privScalar() => xprsProfileScalar();

  // ── inbound ───────────────────────────────────────────────────────────────

  /// Ingest an XPRS packet addressed to us.
  ///
  /// Shorter than the compact path it replaces, and not by accident: the
  /// identifier is derived rather than carried, the source address is derived
  /// from the sender's key rather than trusted off the wire, and the signature
  /// covers the packet rather than a hand-built canonical string.
  bool _ingestXprs(MeshFrame f, {required String via}) {
    final p = f.packet!;
    // Show it on the air view before deciding anything about it. `via` is the
    // transport's own word for how it arrived ('mesh' overheard, or a session);
    // anything the monitor does not recognise as a radio or local bearer is
    // dropped there rather than mislabelled here.
    XprsIngest.heard(p,
        bearer: via == 'mesh' ? 'ble' : via,
        selfCallsign: MeshService.instance.tableCallsign);
    return deliverXprs(f, via: via);
  }

  /// Deliver an XPRS packet already known to be addressed to us, WITHOUT
  /// showing it to the ingest funnel first.
  ///
  /// The split exists because the funnel is now the thing that calls this.
  /// [XprsIngest.heard] is the one surface every bearer reaches — BLE 0x58,
  /// BLE 0x41, LAN UDP, TCP — and until now it archived a message addressed to
  /// us and delivered nothing, because the only route to [RnsService.injectLxmf]
  /// ran through the 0x41 handler's custody tap. A station replaying our mail
  /// on 0x58, which is what every history replay is, dead-ended in the spool.
  /// Calling [ingest] from the funnel would recurse, since [_ingestXprs] starts
  /// by calling the funnel; this entry point is the same code with that first
  /// step removed.
  /// Parts of split messages waiting for their set to complete (section 6.6).
  /// One table for the whole courier: a set is keyed on `(f, ts)`, so copies of
  /// the same part arriving over different bearers land in the same set.
  final XprsPartTable _parts = XprsPartTable();

  /// How many carried messages we have handed to a person, for the diagnostic
  /// line below.
  int _delivered = 0;
  int _held = 0;
  int _joined = 0;

  bool deliverXprs(MeshFrame f, {required String via, int depth = 0}) {
    var p = f.packet!;
    // Cheapest possible first (docs/performance.md 4.2). Everything below is a
    // curve operation or a store write, and this method is reached twice for
    // the same packet by design: the funnel delivers through `onDeliver`, and a
    // caller that already had the frame calls in directly. The duplicate used
    // to be caught further down, AFTER a signature verify and a sealed-body
    // unseal had both run a second time.
    if (_alreadyDelivered('id:${f.id}')) return false;

    // Only a person's text reaches a person.
    //
    // This function ends in RnsService.injectLxmf, which is the inbox chat
    // renders as correspondence and notifies on — so whatever arrives here
    // becomes a chat bubble and an Android notification titled with the
    // sender's callsign. A `cmd:history` ask, a `t:result`, a receipt or an
    // observation is machine traffic: it must cross the air freely and must
    // never reach a screen.
    //
    // The rule is not new and this is the half that was missing. The custody
    // ACCEPTANCE side already says it, at mesh_custody.dart's `_isCarriable`:
    // "Only a 1:1 message is custody material ... an observation, a status or
    // a poll is aired, not couriered." The delivery side never tested it, and
    // MSP custody handover (mesh_custody.dart, the `custody delivery from`
    // branch) calls straight into `ingest` with no type check at all, so any
    // packet type a peer handed over arrived as somebody's message.
    //
    // Neither guard already in the tree could catch it: the host's LXMF filter
    // sits on the RECEIVE side, and chat's own `t:` prefix test cannot help
    // because injectLxmf passes the bare `m:` VALUE, not the wire.
    //
    // Not sos or warning, though both are worth a person's attention: 13.1
    // gives them nine relays precisely so they are AIRED rather than carried,
    // so they do not travel this path and widening it would deliver nothing.
    if (!xprsRendersToPerson(p)) return false;

    final senderNpub = _npubForCallsign(f.from);

    // A carried packet passed through hands we do not control. When we hold the
    // sender's key a bad signature is not a glitch, it is someone else's words
    // under their callsign, and it stops here. Unsigned or unknown-key mail is
    // still delivered: most stations have never announced a key.
    //
    // PARTS ARE NOT VERIFIED HERE. Section 9.1.1 puts the signature of a
    // split PLAIN message on its last part, computed over the packet the
    // parts REASSEMBLE into — verifying that sig against the part's own
    // bytes judged every signed split message forged, dropped its last
    // part after the custody layer had already acked it, and left the set
    // incomplete forever (observed live: 18 sets stuck, zero bubbles). The
    // joined packet is verified after reassembly below. A SEALED part needs
    // no signature check at all: its `x:` only opens against the sender's
    // announced key (ECDH), so a successful unseal is a stronger proof of
    // authorship than the schnorr line — and an unopenable one is held, not
    // shown.
    // THE VERDICT TRAVELS WITH THE MESSAGE.
    //
    // It used to be computed here, acted on, and thrown away — so a wapp that
    // wanted to mark a bubble "verified" had no way to know, and chat grew a
    // SECOND signature scheme (`~<sig>` over its own canonical form, checked
    // with hal_verify) layered inside `m:`, running beside the §9.1 `sig:` the
    // core had already checked and could not report.
    var sigState = p.has('sig') ? XprsSigState.unverified : XprsSigState.unsigned;
    if (p.has('sig') && !p.has('n') && senderNpub.isNotEmpty) {
      final pubHex = NostrCrypto.decodeNpub(senderNpub);
      final state = pubHex.isEmpty
          ? XprsSigState.unverified
          : xprsVerify(p, Uint8List.fromList(HEX.decode(pubHex)));
      sigState = state;
      if (state == XprsSigState.forged) {
        MeshCourierCounters.ingestDropped++;
        LogService.instance.add(
            'Courier: forged signature on a packet claiming to be from '
            '${f.from} — dropped');
        return false;
      }
    }

    // The body, in whichever form it arrived (section 9.2: `x:` sealed, `m:`
    // plain — read off the wire, never from remembered state).
    final read = xprsReadBody(p, senderKeyHex: senderNpub);
    var body = read.clear ?? '';
    // An unsplit sealed body that opened is authenticated by the unseal (9.2:
    // it only opens against the sender's announced key). The split case says
    // the same thing after reassembly, below.
    if (read.privacy == XprsPrivacy.sealed && read.readable) {
      sigState = XprsSigState.verified;
    }
    if (read.privacy == XprsPrivacy.sealed && !read.readable) {
      // It arrived, and we cannot read it. Both of those are facts the operator
      // is owed, and this used to report neither: the packet was counted and
      // dropped, so a message sent to this station simply never existed here.
      //
      // Show it as a sealed message we hold and cannot open. The usual cause is
      // benign and self-correcting — their `t:identity` (9.3) has not been heard
      // yet, and it is re-announced every 30 minutes (18.1).
      MeshCourierCounters.ingestSealedUnreadable++;
      LogService.instance.add(
          'Courier: sealed packet from ${f.from} we cannot open — shown as '
          'unreadable, not dropped');
      // Section 18.1: ask them for the binding instead of waiting up to thirty
      // minutes for the next announcement. This is the receiving half of the
      // same remedy the sender uses when it cannot seal -- and it is the half
      // that matters here, because the message ALREADY arrived: without it a
      // station can be sealed to by a peer whose key it will not hold for half
      // an hour, and every message in between is unreadable.
      unawaited(XprsPublisher.instance.askIdentity(f.from));
      body = '[sealed — no key for ${f.from} yet]';
    }
    // SECTION 6.6: A PARTIAL MESSAGE IS NEVER DISPLAYED.
    //
    // A long message — and a sealed one reaches the limit sooner, being ~40%
    // larger than the text it replaces (13.6) — is split into up to nine parts
    // that each carry `n:i/total` and the full envelope. Every part is a
    // `t:message`, so every part passed the test above and was delivered as its
    // own chat entry: one message from a neighbour arrived as four lines of
    // `n:3/4 x:TH`. Draining a backlog turned that into hundreds of them.
    //
    // `XprsPartTable` already implements this clause in full — keyed on
    // `(f, ts)`, any order, repeats ignored, 10-minute hold, reassembled
    // identifier — and had no caller anywhere in the tree. This is that caller.
    // Reassembly is core by architecture (docs/architecture.md): a wapp is
    // handed a message, never the parts of one.
    if (p.has('n')) {
      // A sealed part we could not open is offered as null: the set then cannot
      // complete, which is correct — half a message with a hole in it is not
      // the message, and the placeholder text must never be joined in as if it
      // were the sender's words.
      final whole = _parts.offer(p,
          clear: (read.privacy == XprsPrivacy.sealed && !read.readable)
              ? null
              : read.clear);
      // Section 9.1.1: the sig a part carried covers the REASSEMBLED plain
      // packet (joined m:, no n:). Now that the set is whole, that is the
      // packet we can finally hold the signature against. Sealed sets were
      // authenticated by the unseal itself (see the note above).
      if (whole != null &&
          whole.privacy == XprsPrivacy.plain &&
          whole.sig != null &&
          senderNpub.isNotEmpty) {
        final pubHex = NostrCrypto.decodeNpub(senderNpub);
        if (pubHex.isNotEmpty) {
          final state = xprsVerify(whole.packet.with_('sig', whole.sig!),
              Uint8List.fromList(HEX.decode(pubHex)));
          sigState = state;
          if (state == XprsSigState.forged) {
            MeshCourierCounters.ingestDropped++;
            LogService.instance.add(
                'Courier: forged signature on a reassembled message claiming '
                'to be from ${f.from} — dropped');
            return false;
          }
        }
      }
      if (whole != null) {
        _joined++;
        if (_joined <= 4 || _joined % 32 == 0) {
          LogService.instance.add(
              'Courier: joined ${p['n']} from ${f.from} '
              '(${whole.text.length}B)');
        }
      }
      if (whole == null) {
        _held++;
        if (_held <= 3 || _held % 20 == 0) {
          LogService.instance.add(
              'Courier: holding part ${p['n']} from ${f.from} — '
              '${_parts.pending} set(s) incomplete');
        }
        return false; // still short: held, not shown
      }
      p = whole.packet;
      body = whole.text;
      // §9.2: a sealed body opens only against the sender's announced key, so a
      // successful unseal is a stronger proof of authorship than the signature
      // line — say so rather than reporting "unsigned".
      if (whole.privacy == XprsPrivacy.sealed) sigState = XprsSigState.verified;
      // The set is identified by the packet the parts reassemble into, so the
      // same message completing twice (aired copy, then custody handover)
      // collapses onto one entry.
      if (_alreadyDelivered('id:${xprsIdentifier(p)}')) return false;
    }
    if (body.isEmpty) return false;

    // (The identifier check that used to sit here is now the first line of this
    // method — the copy heard on air and the copy handed over in a session
    // still collapse onto one entry, they just do it before paying for a
    // signature verify and an unseal.)

    // No `sd:` to trust: the sender's delivery address is derived from the key
    // they published, which cannot be forged without the private half.
    final srcHex = RnsService.instance.lxmfDestForCallsign(f.from);
    if (srcHex.isEmpty) {
      // The author's key is not resolvable RIGHT NOW — which is the ordinary
      // case for carried mail: it arrives precisely because the sender is
      // away. Dropping here lost the message forever (the custodian archived
      // its copy on our ack). Hold it and retry when the sender's announce
      // returns. Nothing was remembered above, so a later custody redelivery
      // can still retry instead of collapsing into the dedup.
      if (_unresolved.length < 32 &&
          !_unresolved.any((u) => u.id == f.id)) {
        // Everything the direct delivery below hands to the inbox travels
        // with the held record: the section 5 identifier (what a read receipt
        // names), the sender's CALLSIGN (what the chat keys the conversation
        // on), and the signature verdict. A held packet used to be delivered
        // with none of them -- `call` empty -- and a chat that keeps to XPRS
        // stations, rightly, dropped it at the door. Bench 2026-09-04: the
        // message reached the phone in 43 s, waited 23 s for the key, and was
        // then delivered to nobody.
        _unresolved.add(_UnresolvedMail(
            f.id, f.from, body, via, xprsIdentifier(p), sigState.name));
        _pump ??= Timer.periodic(const Duration(seconds: 5), (_) => _tick());
        LogService.instance.add(
            'Courier: holding a carried packet from ${f.from} until its '
            'key is heard (${_unresolved.length} waiting)');
      }
      return false;
    }

    // A CARRIED BODY THAT IS ITSELF A WIRE IS PROTOCOL, NOT CORRESPONDENCE.
    //
    // The courier carries whatever it was given, and what it is given is
    // sometimes an XPRS packet wrapped as mail: an outer sealed packet whose
    // plaintext is another wire. Measured on the bench, reassembled and handed
    // to a person verbatim:
    //   "x:iSQKF1iM... t:message f:X3ARK d:X1VCVM ts:... n:4/4 sig:..."
    // That is where every raw-wire chat bubble came from, and it is also why a
    // real message never appeared: the text the user typed is sealed INSIDE
    // that inner packet, and nothing ever opened it.
    //
    // So unwrap instead of displaying. The inner packet goes back through the
    // funnel exactly as if it had been heard on the air; when it is addressed
    // to us it lands here again with its own body, which is the person's words
    // and not a wire, and is delivered normally. Terminates because the second
    // pass has a plain body, and a repeat collapses on the identifier dedup.
    // UNWRAP a packet that was carried inside another one.
    //
    // The courier carries whatever it was given, and that is sometimes an XPRS
    // packet wrapped as mail: an outer sealed packet whose plaintext is
    // another wire. The words the user typed are sealed INSIDE that inner
    // packet, so unwrapping is how the message is found at all.
    //
    // This is only the RECOVERY. Whether protocol may be shown to a person is
    // not decided here any more — `RnsService` refuses it at the inbox door,
    // which is the one place every displayed message passes through. A wire
    // that cannot be recovered simply falls through and is refused there.
    {
      final inner = xprsNormaliseWire(body);
      // Deliver the inner packet HERE rather than handing it to the ingest
      // funnel. Routing it to XprsIngest looked tidier and lost the message:
      // the funnel is about what to do with a packet heard on the air — relay
      // it, count it, answer it — and nothing in it brings a 1:1 back to this
      // method. Bench: "joined 1/4 (192B)" with no delivery after it, and
      // ECHO1 never reached the screen.
      //
      // Recursing terminates: each pass strips one layer, and the layer that
      // holds the person's words has a plain body, which fails the wire test
      // above and is injected. [depth] is a belt against a crafted packet that
      // nests wires all the way down.
      final f2 = (inner != null && depth < 4)
          ? MeshFrame.parse(Uint8List.fromList(utf8.encode(inner)))
          : null;
      if (f2 != null && f2.isXprs) {
        return deliverXprs(f2, via: via, depth: depth + 1);
      }
    }

    // DIAGNOSTIC (cheap, coalesced): what actually reaches a person. A carried
    // message that never appeared on screen was indistinguishable from one
    // that was never delivered, because the only thing not logged anywhere on
    // this path was the content itself. Truncated, and rate-limited to one
    // line per 20 so a backlog drain cannot flood the ring
    // (docs/performance.md section 8.7).
    _delivered++;
    if (_delivered <= 3 || _delivered % 20 == 0) {
      // Length, never the words. This line exists to tell "delivered" from
      // "shown", which it does just as well without putting somebody's private
      // message into a log that /api/log serves over the LAN.
      LogService.instance.add(
          'Courier: #$_delivered to a person from ${f.from} '
          '(${body.length}B of text)');
    }
    RnsService.instance.injectLxmf(
        sourceHex: srcHex,
        content: body,
        title: '',
        via: via,
        // The packet this text came out of — reassembled and unsealed, so this
        // is the identifier the SENDER's outbox is keyed on and the one a read
        // receipt has to name.
        id: xprsIdentifier(p),
        call: f.from,
        sig: sigState.name);
    // REMEMBER it. `_alreadyDelivered` is checked on the way in, but nothing
    // ever recorded the delivery, so the guard read a flag no one set and the
    // same packet was delivered again on every arrival — once per bearer, and
    // again for every re-aired copy. Invisible until the receipt made it
    // audible: three identical `s:ack`s for one message inside 150 ms, which is
    // airtime spent to say the same thing three times (§31.1).
    _noteDelivered('id:${f.id}');
    MeshCourierCounters.ingested++;
    LogService.instance
        .add('Courier: delivered a carried packet from ${f.from} (via $via)');

    // It reached a person. Say so — §13.7.1, and it is the ONLY thing that
    // ends custody: this receipt releases the copy every carrier between us is
    // still holding, and stops the sender's retry ladder.
    //
    // The publisher picks the lane from the sender's own `link:` evidence
    // (§36.0), which is the freshest path we have back to them. Composed only
    // when §13.7.1 allows: not for a group, not for a broadcast, not for a
    // stranger, and never unsigned.
    _acknowledge(p);

    // "Frames that ended at us, the target." This counter existed but was only
    // incremented on the MSP session lane, so a message delivered off the AIR
    // — the ordinary case for carried mail — never moved it, and the bench read
    // `delivered 0` after a day of delivering. The session lane counts itself
    // (mesh_custody `msgReceived`), so only the air path is counted here.
    if (via != 'custody') MeshCustodyCounters.delivered++;
    return true;
  }

  void _acknowledge(XprsPacket p) {
    final self = MeshService.instance.tableCallsign;
    final r = XprsReceipt.compose(p, selfCallsign: self);
    if (r == null) return;
    // Keep the packet: §13.7's other state, `s:read`, can only be composed
    // once a person opens the message, and by then the only thing the wapp can
    // name it by is its §5 identifier. Remembered HERE because a message that
    // earned an `s:ack` is exactly the set that may later earn an `s:read`.
    XprsReceipt.remember(p);
    XprsReceiptCounters.sent++;
    unawaited(XprsPublisher.instance.publishWire(r.encode(),
        slot: 'ack:${r['r']}', verbatim: true));
  }

  /// Carried mail whose author we cannot address yet. Retried from [_tick];
  /// a day is plenty — after that the sender is not coming back soon and the
  /// content is only growing stale.
  final List<_UnresolvedMail> _unresolved = [];

  void _retryUnresolved() {
    if (_unresolved.isEmpty) return;
    final now = DateTime.now();
    _unresolved.removeWhere((u) {
      if (now.difference(u.since) > const Duration(hours: 24)) return true;
      final srcHex = RnsService.instance.lxmfDestForCallsign(u.from);
      if (srcHex.isEmpty) return false;
      _noteDelivered('id:${u.id}');
      RnsService.instance.injectLxmf(
          sourceHex: srcHex,
          content: u.body,
          title: '',
          via: u.via,
          id: u.packetId,
          call: u.from,
          sig: u.sig);
      MeshCourierCounters.ingested++;
      LogService.instance.add(
          'Courier: delivered a held packet from ${u.from} — its key arrived');
      return true;
    });
  }

  /// A frame addressed to us arrived — overheard on air, or handed over by a
  /// custodian in an MSP session. Verify it is ours, unwrap it, and give it to
  /// the wapp through the ordinary inbox. Returns true when it was ingested.
  bool ingest(Uint8List wire, {required String via}) {
    final f = MeshFrame.parse(wire);
    if (f == null) return false;
    final self = MeshService.instance.tableCallsign.trim();
    if (self.isEmpty || f.to.toUpperCase() != self.toUpperCase()) return false;
    if (f.isXprs) return _ingestXprs(f, via: via);

    final (from, to, text) = (f.from, f.to, f.body);
    var rest = text;
    final am = _take(rest, 'am:');
    if (am != null) rest = am.rest;
    final sd = _take(rest, 'sd:');
    if (sd != null) rest = sd.rest;
    final np = _take(rest, 'np:');
    if (np != null) rest = np.rest;

    // Anyone can write our callsign on an envelope. Only mail naming our own
    // key is ours — a mislabelled copy must not surface as our conversation.
    if (np != null && np.value.isNotEmpty) {
      final mine = _selfNpub();
      if (mine.isNotEmpty && np.value != mine) {
        MeshCourierCounters.ingestDropped++;
        return false;
      }
    }

    // Trailing " ~sig" is the sender's, not part of the message.
    var body = rest;
    var sig = '';
    final tilde = body.lastIndexOf(' ~');
    if (tilde > 0) {
      sig = body.substring(tilde + 2);
      body = body.substring(0, tilde);
    }

    final senderNpub = _npubForCallsign(from);
    // A carried message passed through hands we do not control, so when we hold
    // the sender's key the signature is not decoration: a frame that fails it is
    // someone else's words under their callsign. Unsigned/unknown-key mail is
    // still delivered — most peers have never beaconed us a key — but a BAD
    // signature is a forgery and stops here.
    if (sig.isNotEmpty && senderNpub.isNotEmpty) {
      if (!_verify(senderNpub, from, rest.substring(0, tilde), sig)) {
        MeshCourierCounters.ingestDropped++;
        LogService.instance
            .add('Courier: forged signature on a message claiming to be '
                'from $from — dropped');
        return false;
      }
    }
    if (body.startsWith('ENC1:')) {
      final clear = _open(senderNpub, body.substring(5));
      if (clear == null) {
        MeshCourierCounters.ingestDropped++;
        LogService.instance
            .add('Courier: sealed message from $from we cannot open');
        return false;
      }
      body = clear;
    }
    if (body.isEmpty) return false;

    final key = am?.value.isNotEmpty == true
        ? 'am:${am!.value}'
        : 'c:${sha256.convert(utf8.encode('$from|$body'))}';
    if (_alreadyDelivered(key)) return false;
    _noteDelivered(key);

    // Key the conversation by the sender's LXMF delivery address, so it lands
    // in the thread the user already has with that person rather than opening a
    // callsign-shaped one nothing can render. `sd:` is what the sender told us;
    // failing that, what our own directory knows about that callsign.
    final srcHex = (sd?.value.isNotEmpty == true)
        ? sd!.value
        : RnsService.instance.lxmfDestForCallsign(from);
    if (srcHex.isEmpty) {
      MeshCourierCounters.ingestDropped++;
      LogService.instance.add(
          'Courier: message from $from with no address to answer — dropped');
      return false;
    }

    RnsService.instance.injectLxmf(
      sourceHex: srcHex,
      content: body,
      title: '',
      via: via,
    );
    MeshCourierCounters.ingested++;
    LogService.instance
        .add('Courier: delivered a carried message from $from (via $via)');
    return true;
  }

  String _selfNpub() =>
      (ProfileService.instance.activeProfile?.npub ?? '').trim();

  String _npubForCallsign(String call) {
    final pub = RnsService.instance.pubkeyForCallsign(call);
    if (pub == null || pub.isEmpty) return '';
    try {
      return NostrCrypto.encodeNpub(pub);
    } catch (_) {
      return '';
    }
  }

  String? _open(String senderNpub, String blobB64) {
    if (senderNpub.isEmpty) return null;
    try {
      final d = _privScalar();
      final pubHex = NostrCrypto.decodeNpub(senderNpub);
      if (d == null || pubHex.isEmpty) return null;
      final pad = (4 - blobB64.length % 4) % 4;
      final blob = base64Url.decode(blobB64 + ('=' * pad));
      final pt = XprsCrypto.decryptFrom(
          d, Uint8List.fromList(HEX.decode(pubHex)), blob);
      if (pt == null) return null;
      return utf8.decode(pt);
    } catch (_) {
      return null;
    }
  }

  static String _short(String h) => h.length >= 8 ? h.substring(0, 8) : h;

  static _Token? _take(String s, String tag) {
    if (!s.startsWith(tag)) return null;
    final sp = s.indexOf(' ');
    if (sp < 0) return _Token(s.substring(tag.length), '');
    return _Token(s.substring(tag.length, sp), s.substring(sp + 1));
  }
}

/// One carried packet delivered to us whose author's key was unknown at the
/// time — held by [MeshCourier] and retried until the key is heard.
class _UnresolvedMail {
  final String id;
  final String from;
  final String body;
  final String via;
  /// The section 5 identifier of the (reassembled) packet -- the inbox's
  /// `id`, distinct from [id], which is the frame's own dedup key.
  final String packetId;
  final String sig;
  final DateTime since = DateTime.now();
  _UnresolvedMail(
      this.id, this.from, this.body, this.via, this.packetId, this.sig);
}

class _Token {
  _Token(this.value, this.rest);
  final String value;
  final String rest;
}

/// A finished packet the courier carries unchanged — the bytes, who it is
/// for, and whether it arrived sealed. Named because "carry it, do not
/// re-author it" is the rule that keeps a message's identity stable.
class CarriedWire {
  const CarriedWire({
    required this.bytes,
    required this.to,
    required this.sealed,
  });
  final Uint8List bytes;
  final String to;
  final bool sealed;
}
