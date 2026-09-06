/*
 * The core routes; the wapp subscribes. Nothing pulls from a shared pool.
 *
 * What this replaces: `_lxmfInbox` was one flat list of human correspondence
 * with no recipient test on it, handed through `hal_lxmf_recv` to whichever
 * wapp asked. "This belongs to chat" was decided nowhere in the core -- chat
 * was simply the only wapp that called it. Any wapp that added the import
 * would have received every private message on the device and could have
 * raised its own notifications for them, because the engine offers every HAL
 * import to every module and swallows the failure when it is not declared.
 *
 * Fine while every wapp is ours; not fine the moment a stranger's wapp can be
 * installed. So: the core picks a topic, publishes once, and the broker
 * delivers only to engines that asked for it.
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:xprs/services/receive/packet_gateway.dart';
import 'package:xprs/services/receive/wapp_delivery.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/nostr_crypto.dart';
import 'package:xprs/wapp/wapp_event_broker.dart';

void main() {
  late WappEventBroker bus;

  setUp(() {
    bus = WappEventBroker.instance;
    for (final id in bus.registeredEngines().toList()) {
      bus.unregisterEngine(id);
    }
    WappDelivery.debugReset();
  });

  // §13.11 decides which room a broadcast lands in, and three of its four
  // spellings mean the same thing. A wapp reading `scope:` out of `fields`
  // gets the ABSENT case wrong on its first try, and the Local room would then
  // quietly show the world's traffic.
  test('the row states the scope, normalised', () {
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));

    Map<String, dynamic> deliver(String wire) {
      final p = XprsPacket.parse(wire)!;
      WappDelivery.instance.deliverPacket(p, bearer: 'ble', forUs: false);
      return jsonDecode(bus.recv('chat')!.data) as Map<String, dynamic>;
    }

    const head = 't:message f:X1QZ3N ts:2026-09-03_11:04:00';
    expect(deliver('$head m:goes anywhere')['scope'], 'global',
        reason: 'absent scope: IS global — the case a wapp gets wrong');
    expect(deliver('$head scope:local m:the room')['scope'], 'local');
    expect(deliver('$head scope:PT m:this country')['scope'], 'country');
  });

  // Section 26.7 at the RECEIVE door: a closed-group post from a proven
  // non-member is not handed to any wapp, a member's is, and a group whose
  // roster cannot be verified fails OPEN. Decided here, once, for every
  // bearer — no wapp has to know what a roster is.
  test('a closed-group post is handed on only from a member (26.7, at the door)',
      () {
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));
    final m = XprsGroups.instance;
    m.clear();
    final keys = <String, ({BigInt d, Uint8List pub})>{};
    ({BigInt d, Uint8List pub}) keyFor(String c) => keys.putIfAbsent(c, () {
          final kp = NostrCrypto.generateKeyPair();
          var d = BigInt.zero;
          for (final b in HEX.decode(kp.privateKeyHex)) {
            d = (d << 8) | BigInt.from(b);
          }
          return (
            d: d,
            pub: Uint8List.fromList(HEX.decode(kp.publicKeyHex)),
          );
        });
    m.keyResolver = (c) => keys[c]?.pub;
    const g = 'X5A3F2';
    final grant = xprsSign(
        XprsPacket.parse(
            't:moderate f:$g d:$g ts:2026-08-08_10:00:00 grant:X1RD89')!,
        keyFor(g).d);
    m.offer(grant);
    m.offer(xprsSign(
        XprsPacket.parse('t:moderate f:X1RD89 d:$g ts:2026-08-08_11:00:00 '
            'r:${xprsIdentifier(grant)} accept:member')!,
        keyFor('X1RD89').d));
    keyFor('X1PZ4Q'); // a stranger: known key, no grant

    int deliver(String wire) => WappDelivery.instance
        .deliverPacket(XprsPacket.parse(wire)!, bearer: 'lan', forUs: false);
    const ts = 'ts:2026-08-08_12:00:00';
    expect(deliver('t:message f:X1RD89 d:$g $ts m:from a member'), 1);
    expect(deliver('t:message f:X1PZ4Q d:$g $ts m:from a stranger'), 0,
        reason: 'a proven non-member is stopped at the door');
    expect(WappDelivery.refusedGroupAuthor, 1);
    // A group we hold no record of: nothing to verify against, fails open.
    expect(deliver('t:message f:X1PZ4Q d:X5ZZZZ $ts m:unverifiable'), 1);
    // The same rule on the content lane.
    expect(
        WappDelivery.instance.deliverMessage(
            from: 'x', call: 'X1PZ4Q', content: 'psst', title: '#$g'),
        0);
    expect(
        WappDelivery.instance.deliverMessage(
            from: 'x', call: 'X1RD89', content: 'hi', title: '#$g'),
        1);
    m.clear();
  });

  test('only a subscriber is told, and it is told once', () {
    bus.registerEngine('chat');
    bus.registerEngine('nosy');
    bus.subscribe('chat', rxTopicFor('message'));
    // `nosy` subscribes to something else entirely.
    bus.subscribe('nosy', rxTopicFor('status'));

    final n = WappDelivery.instance
        .deliverMessage(from: 'X1QZ3N', content: 'hello');

    expect(n, 1, reason: 'exactly one engine asked for this topic');
    expect(bus.queueDepth('chat'), 1);
    expect(bus.queueDepth('nosy'), 0,
        reason: 'a wapp that did not subscribe is not told');

    final ev = bus.recv('chat')!;
    expect(ev.topic, rxTopicFor('message'));
    expect(jsonDecode(ev.data)['content'], 'hello');
  });

  test('a packet is published on its own type, with its provenance', () {
    // XPRS.md 4.2 gives thirty types; the bus uses them directly rather than
    // inventing coarse buckets a wapp would have to filter again.
    bus.registerEngine('feed');
    bus.subscribe('feed', rxTopicFor('status'));
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));

    final p = XprsPacket.parse(
        't:status f:X1QZ3N ts:2026-09-02_10:00:00 link:ble m:on the hill')!;
    WappDelivery.instance
        .deliverPacket(p, bearer: 'ble', rssi: -61, forUs: false);

    expect(bus.queueDepth('chat'), 0, reason: 'a status is not a message');
    final row = jsonDecode(bus.recv('feed')!.data) as Map<String, dynamic>;
    expect(row['type'], 'status');
    expect(row['from'], 'X1QZ3N');
    // Provenance a wapp legitimately needs: who, how it reached us, how far.
    expect(row['bearer'], 'ble');
    expect(row['rssi'], -61);
    expect(row['link'], 'ble');
    expect(row['id'], isNotEmpty, reason: 'section 5 identifier, for dedup');
    // Every field, in order, so a wapp can read a type the core never parsed.
    expect(row['fields'], contains(equals(['m', 'on the hill'])));
  });

  test('a packet reaches a subscriber on EVERY link, Reticulum included', () {
    // Reticulum is how two of our stations talk over the internet: an XPRS
    // wire travels inside an LXMF message and the router hands it to the
    // funnel. For XPRS it is a link like BLE or LAN.
    //
    // It was not treated like one. `receive` published every heard packet on
    // its type topic and `receiveInternet` published nothing, so a wapp
    // subscribed to xprs.message got everything off BLE and LAN and silently
    // missed every message that came over the internet.
    XprsArchive.instance.selfCallsign = 'X1SELF';
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));

    const wire = 't:message f:X1QZ3N d:X1RD89 ts:2026-09-02_10:00:00 m:hello';
    final bytes = Uint8List.fromList(utf8.encode(wire));

    PacketGateway.instance
        .receive(bytes, bearer: 'ble', lane: RxLane.advert, rssi: -55);
    PacketGateway.instance
        .receive(bytes, bearer: 'lan', lane: RxLane.advert);
    PacketGateway.instance.receiveInternet('hub', bytes);

    expect(bus.queueDepth('chat'), 3,
        reason: 'one delivery per link, Reticulum included');
    final bearers = <String>[];
    for (var i = 0; i < 3; i++) {
      bearers.add(jsonDecode(bus.recv('chat')!.data)['bearer'] as String);
    }
    expect(bearers, ['ble', 'lan', 'rns'],
        reason: 'and each says which link carried it');
  });

  test('an unknown type is published under its own name, not dropped', () {
    // 4.2: "An unknown type is ignored. It is never an error." A wapp written
    // for a type this build has never heard of works the day a peer sends it.
    bus.registerEngine('future');
    bus.subscribe('future', rxTopicFor('telemetry'));
    final p = XprsPacket.parse('t:telemetry f:X1QZ3N ts:2026-09-02_10:00:00 m:9')!;
    WappDelivery.instance
        .deliverPacket(p, bearer: 'lan', forUs: false);
    expect(bus.queueDepth('future'), 1);
  });

  test('a delivery nobody asked for is counted, not silently dropped', () {
    bus.registerEngine('chat'); // registered, but subscribed to nothing
    final n = WappDelivery.instance
        .deliverMessage(from: 'X1QZ3N', content: 'hello');
    expect(n, 0);
    expect(WappDelivery.noSubscriber, 1,
        reason: 'the old pull model made this state invisible');
  });

  test('the event is queued for the subscriber to read', () {
    // Delivery calls the engine (see WappEventBroker.publish); the queue is
    // what the wapp reads with hal_event_recv once it is in
    // module_handle_event. No engine is registered in this test, so only the
    // queue side is exercised here.
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));
    WappDelivery.instance.deliverMessage(from: 'X1A', content: 'a');
    WappDelivery.instance.deliverMessage(from: 'X1A', content: 'b');
    expect(bus.queueDepth('chat'), 2);
    expect(jsonDecode(bus.recv('chat')!.data)['content'], 'a');
  });
  // ── Section 6.6: a part is not a message ───────────────────────────────
  //
  // A long message is aired as up to nine packets that each carry n:i/total
  // and the full envelope. Every part is a t:message, so every part used to be
  // published as a message of its own — and the chat wapp, correctly, dropped
  // anything carrying n:. A long post in the Local room therefore rendered
  // NOWHERE. The courier had joined the directed path for a while; nothing
  // joined the undirected one, which is the path a broadcast takes.

  test('a split broadcast arrives once, whole, and never as a fragment', () {
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));

    const head = 't:message f:X3WWAJ ts:2026-09-03_12:00:00 scope:local';
    WappDelivery.instance.deliverPacket(
        XprsPacket.parse('$head n:1/3 m:the quick')!,
        bearer: 'ble', forUs: false);
    expect(bus.queueDepth('chat'), 0, reason: 'a partial message is not shown');
    WappDelivery.instance.deliverPacket(
        XprsPacket.parse('$head n:3/3 m:the lazy dog')!,
        bearer: 'ble', forUs: false);
    expect(bus.queueDepth('chat'), 0, reason: 'still short, and still silent');

    // Out of order on purpose: 6.6 says parts may arrive in any order.
    WappDelivery.instance.deliverPacket(
        XprsPacket.parse('$head n:2/3 m:brown fox')!,
        bearer: 'ble', forUs: false);

    expect(bus.queueDepth('chat'), 1, reason: 'one message, not three');
    final row = jsonDecode(bus.recv('chat')!.data) as Map<String, dynamic>;
    expect(row['fields'],
        contains(equals(['m', 'the quick brown fox the lazy dog'])),
        reason: 'joined in order, one space between parts');
    expect(row['fields'].any((f) => (f as List).first == 'n'), isFalse,
        reason: 'the reassembled packet carries no n:');
    expect(row['scope'], 'local');
    expect(WappDelivery.partsJoined, 1);
  });

  test('a repeated part does not complete a set', () {
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));
    const head = 't:message f:X3WWAJ ts:2026-09-03_12:05:00 scope:local';
    for (var i = 0; i < 3; i++) {
      WappDelivery.instance.deliverPacket(
          XprsPacket.parse('$head n:1/2 m:only this one')!,
          bearer: 'ble', forUs: false);
    }
    expect(bus.queueDepth('chat'), 0,
        reason: 'the same part three times is still one part');
  });

  test('an unsplit message is untouched by the part table', () {
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));
    WappDelivery.instance.deliverPacket(
        XprsPacket.parse(
            't:message f:X3WWAJ ts:2026-09-03_12:10:00 scope:local m:short')!,
        bearer: 'ble', forUs: false);
    expect(bus.queueDepth('chat'), 1);
    expect(WappDelivery.partsHeld, 0);
    expect(WappDelivery.partsJoined, 0);
  });

}
