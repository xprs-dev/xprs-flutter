/*
 * wapp_delivery — the core hands a wapp the packets it asked for.
 *
 * A wapp owns no transport: it does not open a socket, read a radio or drain
 * a shared inbox. It names the PACKET TYPES it cares about and is handed
 * those, with the provenance the specification already puts on the wire.
 *
 * ── Topics are packet types (XPRS.md §4.2) ───────────────────────────────
 * One topic per `t:` value -- `xprs.message`, `xprs.observation`,
 * `xprs.status`, `xprs.poll`, `xprs.receipt`, and so on for all thirty. The
 * format already sorts traffic by kind, so inventing coarse buckets on top of
 * it ("message / group / status") threw that away and made every wapp filter
 * again on the far side of the bus. A feed wapp wants `t:status`; a poll wapp
 * wants `t:poll` and `t:reaction`; chat wants `t:message` and `t:receipt`.
 * None of them should have to see the others to find out.
 *
 * An unknown type is published under its own name and simply has no
 * subscriber, which matches §4.2: "An unknown type is ignored. It is never an
 * error." A wapp written for a type this build has never heard of works the
 * day a peer starts sending it, with no host change.
 *
 * ── Provenance travels with the packet ───────────────────────────────────
 * The row carries the packet's own fields plus how it reached us: the bearer,
 * the signal where there was one, and the `via:` chain §13 puts on the wire.
 * A wapp needs this -- "who sent it, how far away, by what route, and can I
 * answer on the same path" are content questions, and §10.6 makes `link:` a
 * first-class reading. What a wapp still does not get is a transport
 * DECISION: which radio to answer on, whether to relay, what to hold. Those
 * stay in the core (docs/architecture.md §1), and none of them is a field.
 */
import 'dart:convert';

import '../../wapp/wapp_event_broker.dart';
import '../log_service.dart';
import '../xprs/xprs_id.dart';
import '../../util/nostr_crypto.dart';
import '../xprs/xprs_archive.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_parts.dart';
import '../xprs/xprs_sig.dart';
import '../xprs/xprs_vocab.dart';

/// The topic a packet of type [t] is published on. One per §4.2 type.
String rxTopicFor(String t) => 'xprs.${t.trim().toLowerCase()}';

/// Every type §4.2 defines, for a wapp that wants the list rather than a
/// literal, and for the subscription UI.
const List<String> kXprsTypes = [
  'message', 'observation', 'receipt', 'reaction', 'request', 'identity',
  'track', 'sos', 'info', 'blog', 'poll', 'file', 'report', 'place',
  'status', 'passage', 'event', 'offer', 'need', 'channel', 'mailbox',
  'service', 'command', 'result', 'moderate', 'challenge', 'response',
  'warning', 'ping', 'pong',
];

class WappDelivery {
  WappDelivery._();
  static final WappDelivery instance = WappDelivery._();

  static int published = 0;
  static int noSubscriber = 0;

  /// Bodies refused because they are an XPRS wire, not a person's words. The
  /// rule that PROTOCOL NEVER REACHES A PERSON lives here, on the one door
  /// every wapp reads a message from, so both the radio lane (MeshCourier)
  /// and the LXMF lane (_admitToInbox) are held to it once.
  static int refusedProtocol = 0;

  /// Test seam: what was published, without standing up an engine.
  static void Function(String topic, Map<String, dynamic> row)? onPublish;

  /// §6.6: the parts of a split message, held until the set is whole.
  ///
  /// A long message is aired as up to nine packets that each carry `n:i/total`
  /// and the full envelope. Every part is a `t:message`, so every part used to
  /// be published to the wapps as a message of its own: one thing somebody
  /// said arrived as four rows reading `n:3/4 …`, and the chat wapp — correctly
  /// — dropped every packet carrying `n:`, so a long post in the Local room was
  /// rendered NOWHERE, live or from the archive.
  ///
  /// [MeshCourier] has joined the DIRECTED path for a while, because a 1:1
  /// reaches it through custody. Nothing joined the undirected one, which is
  /// the path a broadcast takes. This is that caller, and it sits here because
  /// this is the single door every wapp-facing packet passes through:
  /// reassembly is the core's, and a wapp is handed a message, never a part.
  final XprsPartTable _parts = XprsPartTable();

  /// Sets still short, and messages this door has rejoined.
  static int partsHeld = 0;
  static int partsJoined = 0;

  /// Rejoin [p] when it is a part, or return it unchanged when it is not.
  ///
  /// Null means the set is still short — and §6.6 is explicit that a partial
  /// message is never displayed, so the caller publishes nothing at all.
  XprsPacket? _whole(XprsPacket p, {required String bearer, required int rssi}) {
    if (!p.has('n')) return p;
    // A SEALED part is not ours to open. §9.2 seals to one recipient and the
    // courier holds the key handling; offering null keeps the set short, which
    // is the right answer here — a sealed set completes on the courier's path
    // and reaches wapps as a finished message, never as packets.
    final clear = p.has('x') ? null : (p['m'] ?? '');
    final done = _parts.offer(p, clear: clear);
    if (done == null) {
      partsHeld++;
      return null;
    }
    partsJoined++;
    // §9.1.1: a split plain message is signed ONCE, on the last part, over the
    // packet the parts reassemble into. Re-attach it so the verdict below is
    // computed against the thing the signature actually covers.
    final whole = done.sig == null
        ? done.packet
        : done.packet.with_('sig', done.sig!);
    // The archive heard the parts and stored them as it heard them. Store the
    // message they make as well, so a reader coming back later — the chat
    // wapp refilling a room, `/api/xprs/history` — finds the message rather
    // than nine fragments it is obliged to skip.
    try {
      XprsArchive.instance.admit(whole, bearer: bearer, rssi: rssi);
    } catch (_) {
      // Archiving is best-effort; a message that arrived still arrives.
    }
    LogService.instance.add(
        'Delivery: rejoined ${p['n']} from ${whole['f'] ?? '?'} '
        '(${(whole['m'] ?? '').length}B, ${_parts.pending} set(s) still short)');
    return whole;
  }


  /// Publish a heard packet to whoever subscribed to its type.
  ///
  /// [bearer] is the word a radio person would use (`ble`, `lan`, `rns`);
  /// [rssi] is 0 where the bearer has no signal to report, as a TCP byte does
  /// not. [forUs] says whether `d:` names this station -- the wapp would
  /// otherwise have to know our callsign to work it out.
  int deliverPacket(
    XprsPacket pIn, {
    required String bearer,
    required bool forUs,
    int rssi = 0,
  }) {
    // §6.6: a part is not a message. Held until the set is whole, and a set
    // that is still short publishes nothing.
    final p = _whole(pIn, bearer: bearer, rssi: rssi);
    if (p == null) return 0;
    // §9.1's verdict, computed here rather than left to the wapp. The archive
    // has always computed exactly this for its own rows; a wapp handed a packet
    // and no verdict has to verify it itself, and chat did — with a signature
    // scheme of its own invention, layered inside `m:`.
    final sig = p.has('sig')
        ? xprsVerify(p,
                XprsArchive.instance.keyResolver
                    ?.call(NostrCrypto.bareCallsign(p['f'] ?? '')))
            .name
        : XprsSigState.unsigned.name;
    final row = <String, dynamic>{
      // Section 5: derived from the packet, never transmitted, so a copy
      // heard twice over two bearers is recognised once. A wapp needs it to
      // dedup and to name the packet in a reply or a receipt.
      'id': xprsIdentifier(p),
      'type': p.type,
      'from': p['f'] ?? '',
      'to': p['d'] ?? '',
      'ts': p['ts'] ?? '',
      // Every field, verbatim and IN ORDER, as [key, value] pairs. A wapp
      // reading `t:poll` needs its options and the core has no business
      // enumerating them. Pairs rather than a map because the format allows
      // duplicate keys and order is what the §5 identifier is derived from --
      // collapsing either would quietly rename the packet.
      'fields': [for (final f in p.fields) [f.key, f.value]],
      'forUs': forUs,
      'sealed': p.has('x'),
      // §13.11's verdict, NORMALISED: 'global' | 'local' | 'country'.
      //
      // A wapp can read `scope:` out of `fields` and three of them will get it
      // wrong the same way, because an ABSENT field, an empty one and the word
      // `global` are one answer and only the third looks like it. The core
      // already owns that reading -- `xprsScope` is the function the
      // publisher's own reach gate calls -- so it states the verdict here, for
      // the same reason it states `forUs`, `sealed` and `sig` rather than
      // leaving each wapp to re-derive them. The country codes stay in
      // `fields` for whoever needs the letters.
      'scope': xprsScope(p).scope.name,
      // How it got here. `via:` is the §13 relay chain and is already on the
      // wire; `bearer` and `rssi` are what this station observed.
      'bearer': bearer,
      'rssi': rssi,
      'via': p['via'] ?? '',
      'link': p['link'] ?? '',
      'sig': sig,
    };
    return _publish(rxTopicFor(p.type), row);
  }

  /// Publish a message that arrived already decoded rather than as a packet
  /// (the LXMF lane). It is a `t:message` in everything but framing.
  /// [id] is the §5 identifier of the packet the text came out of, empty when
  /// it did not come out of one (a foreign LXMF message has no packet). It is
  /// what §13.7 puts in a receipt's `r:`, so a wapp reporting "a person read
  /// this" has something to name.
  int deliverMessage({
    String from = '',
    required String content,
    String title = '',
    String bearer = 'rns',
    Object? ts,
    String id = '',
    String call = '',
    String sig = '',
  }) {
    // An XPRS wire is protocol, not correspondence: a `t:...`/`x:...` body
    // that leaked this far is a bug upstream, and it must never surface as a
    // chat bubble. Refused here, once, for every lane.
    if (xprsLooksLikeWire(content)) {
      refusedProtocol++;
      return 0;
    }
    return _publish(rxTopicFor('message'), {
        'id': id,
        'type': 'message',
        'from': from,
        // The sender's CALLSIGN where we know it. `from` is a Reticulum
        // delivery destination, which is what addresses a reply but is not
        // what a person is called — a wapp given only the hex had to keep its
        // own hex-to-name table and ask the host to fill it in.
        'call': call,
        // §9.1's verdict, computed by the core and reported rather than
        // discarded: verified | unverified | forged | unsigned. A wapp with
        // no answer here invents a signature scheme of its own; chat did.
        'sig': sig,
        'to': title.startsWith('#') ? title : '',
        'content': content,
        'title': title,
        'ts': ts,
        'forUs': !title.startsWith('#'),
        'bearer': bearer,
        'rssi': 0,
      });
  }

  /// The fate of a message THIS station sent: delivered, read.
  ///
  /// Its own topic, because it is not a packet somebody heard -- it is an
  /// answer about one of ours. A wapp subscribes to draw the tick it used to
  /// assert on its own.
  int deliverStatus({
    required String id,
    required String peer,
    required String state,
  }) =>
      _publish('xprs.status.tx', {'id': id, 'peer': peer, 'state': state});

  int _publish(String topic, Map<String, dynamic> row) {
    final n = WappEventBroker.instance.publish('core', topic, jsonEncode(row));
    published++;
    if (n == 0) {
      noSubscriber++;
      if (noSubscriber <= 3 || noSubscriber % 100 == 0) {
        LogService.instance
            .add('Delivery: $topic reached no subscriber ($noSubscriber)');
      }
    }
    try {
      onPublish?.call(topic, row);
    } catch (_) {}
    return n;
  }

  static void debugReset() {
    refusedProtocol = 0;
    published = 0;
    noSubscriber = 0;
    partsHeld = 0;
    partsJoined = 0;
    onPublish = null;
    instance._parts.clear();
  }
}
