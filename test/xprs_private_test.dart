/*
 * Private and plain 1:1 messages (docs/XPRS.md sections 9.2, 6.2, 6.6, 9.4).
 *
 * The rules being pinned, and why each one is here:
 *
 *  - The wire form IS the privacy statement. `x:` replaces `m:` (9.2), so a
 *    reader needs no prior state and either side may switch on any message.
 *  - A private send NEVER quietly becomes a plain one. Section 36.8: sealed and
 *    clear mail are released under different rules, so a downgrade is not a
 *    weaker message, it is a message under rules its author did not choose.
 *  - A partial message is never displayed (6.6).
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

import 'package:xprs/services/xprs/xprs_body.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_parts.dart';
import 'package:xprs/util/nostr_crypto.dart';

BigInt _big(String hex) {
  var r = BigInt.zero;
  for (final b in HEX.decode(hex)) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

const _tsA = '2026-08-08_14:26:40';

XprsPacket _head({String to = 'X1RD89', String from = 'X1QZ3N'}) =>
    XprsPacket.parse('t:message f:$from d:$to ts:$_tsA')!;

void main() {
  final privA =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00';
  final privB = NostrCrypto.generateKeyPair().privateKeyHex;
  final dA = _big(privA), dB = _big(privB);
  final pubA = NostrCrypto.derivePublicKey(privA);
  final pubB = NostrCrypto.derivePublicKey(privB);

  setUp(() => XprsBandRule.reachesAmateurSpectrum = () => false);

  group('the two forms, exactly as section 9.2 and 6.2 draw them', () {
    test('plain is m:, and m: is last', () {
      final r = xprsBuildDirect(
          head: _head(), text: 'meet at the bridge at six', private: false);
      expect(r.ok, isTrue);
      expect(r.privacy, XprsPrivacy.plain);
      final w = r.packets.single.encode();
      // Section 6.2's own example, plus the signature this station adds.
      expect(w, startsWith('t:message f:X1QZ3N d:X1RD89 ts:$_tsA'));
      expect(w, endsWith('m:meet at the bridge at six'));
      expect(r.packets.single.has('x'), isFalse);
    });

    test('private is x:, and it REPLACES m:', () {
      final r = xprsBuildDirect(
          head: _head(),
          text: 'meet at the bridge at six',
          private: true,
          recipientKeyHex: pubB,
          signingKey: dA);
      expect(r.ok, isTrue);
      expect(r.privacy, XprsPrivacy.sealed);
      final p = r.packets.single;
      expect(p.has('x'), isTrue);
      expect(p.has('m'), isFalse, reason: '9.2: x: replaces m:');
      expect(p.fits, isTrue);
    });

    test('the routing envelope stays in cleartext', () {
      // 9.2: "t:, f:, d: and ts: stay in cleartext, so an intermediate station
      // can route the packet, identify the recipient and release a carried copy
      // ... without reading the content."
      final r = xprsBuildDirect(
          head: _head(),
          text: 'something private',
          private: true,
          recipientKeyHex: pubB,
          signingKey: dA);
      final p = r.packets.single;
      expect(p['t'], 'message');
      expect(p['f'], 'X1QZ3N');
      expect(p['d'], 'X1RD89');
      expect(p['ts'], _tsA);
      expect(p.encode(), isNot(contains('something private')));
    });

    test('the recipient reads it back; a bystander does not', () {
      final r = xprsBuildDirect(
          head: _head(),
          text: 'meet at the bridge at six',
          private: true,
          recipientKeyHex: pubB,
          signingKey: dA);
      final p = r.packets.single;

      final asRecipient = xprsReadBody(p, ownKey: dB, senderKeyHex: pubA);
      expect(asRecipient.privacy, XprsPrivacy.sealed);
      expect(asRecipient.clear, 'meet at the bridge at six');

      // A station with no key for the sender knows it is sealed and no more.
      final asStranger = xprsReadBody(p, ownKey: dB, senderKeyHex: null);
      expect(asStranger.privacy, XprsPrivacy.sealed);
      expect(asStranger.readable, isFalse,
          reason: 'unreadable is a fact to show, not a reason to drop');
    });

    test('privacy is read off the wire, with nothing remembered', () {
      final sealed = XprsPacket.parse(
          't:message f:X1QZ3N d:X1RD89 ts:$_tsA x:pQ4m9xT2vB8kR')!;
      final plain =
          XprsPacket.parse('t:message f:X1QZ3N d:X1RD89 ts:$_tsA m:hello')!;
      expect(xprsReadBody(sealed).privacy, XprsPrivacy.sealed);
      expect(xprsReadBody(plain).privacy, XprsPrivacy.plain);
      expect(xprsReadBody(plain).clear, 'hello');
    });

    test('either side may switch form on consecutive messages', () {
      // The behaviour the whole design exists for: no negotiation, no mode.
      for (final want in [true, false, true, false]) {
        final r = xprsBuildDirect(
            head: _head(),
            text: 'switching now',
            private: want,
            recipientKeyHex: pubB,
            signingKey: dA);
        expect(r.ok, isTrue);
        expect(r.privacy, want ? XprsPrivacy.sealed : XprsPrivacy.plain);
        expect(r.packets.single.has('x'), want);
        expect(r.packets.single.has('m'), !want);
      }
    });
  });

  group('a private send is never quietly downgraded', () {
    test('no recipient key refuses, and emits nothing', () {
      final r = xprsBuildDirect(
          head: _head(), text: 'secret', private: true, signingKey: dA);
      expect(r.ok, isFalse);
      expect(r.refusal, XprsSealRefusal.noRecipientKey);
      expect(r.packets, isEmpty, reason: '36.8: plaintext is disclosure');
    });

    test('a malformed recipient key refuses', () {
      for (final bad in ['', 'zz', 'npub1notreallyakey', 'ab' * 10]) {
        final r = xprsBuildDirect(
            head: _head(),
            text: 'secret',
            private: true,
            recipientKeyHex: bad,
            signingKey: dA);
        expect(r.ok, isFalse, reason: 'accepted "$bad"');
        expect(r.packets, isEmpty);
      }
    });

    test('amateur spectrum refuses a sealed body outright', () {
      // 9.4: "An implementation able to reach amateur infrastructure must
      // refuse to transmit a sealed body onto it."
      XprsBandRule.reachesAmateurSpectrum = () => true;
      final r = xprsBuildDirect(
          head: _head(),
          text: 'secret',
          private: true,
          recipientKeyHex: pubB,
          signingKey: dA);
      expect(r.ok, isFalse);
      expect(r.refusal, XprsSealRefusal.amateurBand);
      // …and plain text is still allowed there, because signing is lawful and
      // only obscuring meaning is not (9.4).
      final plain = xprsBuildDirect(
          head: _head(), text: 'in the clear', private: false, signingKey: dA);
      expect(plain.ok, isTrue);
    });
  });

  group('long messages split (6.6, 13.6)', () {
    String words(int n) => List.filled(n, 'alpha').join(' ');

    test('a plain body too long for one packet becomes parts', () {
      final r = xprsBuildDirect(
          head: _head(), text: words(60), private: false, signingKey: dA);
      expect(r.ok, isTrue);
      expect(r.packets.length, greaterThan(1));
      for (final p in r.packets) {
        expect(p.fits, isTrue);
        expect(p['n'], isNotNull);
        // "Every field except m: and n: is repeated on each part".
        expect(p['f'], 'X1QZ3N');
        expect(p['d'], 'X1RD89');
        expect(p['ts'], _tsA);
      }
      // 9.1.1: sign the last part.
      expect(r.packets.last.has('sig'), isTrue);
    });

    test('a sealed body splits, and every part is sealed on its own', () {
      final r = xprsBuildDirect(
          head: _head(),
          text: words(40),
          private: true,
          recipientKeyHex: pubB,
          signingKey: dA);
      expect(r.ok, isTrue);
      expect(r.packets.length, greaterThan(1));
      for (final p in r.packets) {
        expect(p.fits, isTrue);
        expect(p.has('x'), isTrue);
        expect(p.has('m'), isFalse);
        expect(p.has('sig'), isTrue,
            reason: 'sealing per part leaves room, so 9.1 default applies');
        // Each part opens by itself.
        expect(xprsReadBody(p, ownKey: dB, senderKeyHex: pubA).readable, isTrue);
      }
    });

    test('a sealed message round-trips through the part table', () {
      final text = words(40);
      final r = xprsBuildDirect(
          head: _head(),
          text: text,
          private: true,
          recipientKeyHex: pubB,
          signingKey: dA);
      final table = XprsPartTable();
      XprsReassembled? done;
      for (final p in r.packets) {
        final body = xprsReadBody(p, ownKey: dB, senderKeyHex: pubA);
        done = table.offer(p, clear: body.clear);
      }
      expect(done, isNotNull);
      expect(done!.text, text);
      expect(done.privacy, XprsPrivacy.sealed);
      // 6.6: the reassembled packet has n: removed and the joined body.
      expect(done.packet.has('n'), isFalse);
      expect(done.packet['f'], 'X1QZ3N');
    });

    test('parts arriving out of order still reassemble', () {
      final text = words(40);
      final r = xprsBuildDirect(
          head: _head(),
          text: text,
          private: true,
          recipientKeyHex: pubB,
          signingKey: dA);
      final table = XprsPartTable();
      XprsReassembled? done;
      for (final p in r.packets.reversed) {
        done = table.offer(p,
            clear: xprsReadBody(p, ownKey: dB, senderKeyHex: pubA).clear);
      }
      expect(done?.text, text);
    });

    test('a repeated part number is ignored', () {
      final r = xprsBuildDirect(
          head: _head(), text: words(60), private: false, signingKey: dA);
      final table = XprsPartTable();
      table.offer(r.packets.first, clear: 'FIRST');
      table.offer(r.packets.first, clear: 'IMPOSTOR');
      XprsReassembled? done;
      for (final p in r.packets.skip(1)) {
        done = table.offer(p, clear: p['m']);
      }
      expect(done!.text, startsWith('FIRST'));
      expect(done.text, isNot(contains('IMPOSTOR')));
    });

    test('an incomplete set is never displayed, and expires at 10 minutes', () {
      final r = xprsBuildDirect(
          head: _head(), text: words(60), private: false, signingKey: dA);
      final table = XprsPartTable();
      final t0 = DateTime(2026, 8, 8, 14, 26, 40);
      // Everything but the last part.
      for (final p in r.packets.take(r.packets.length - 1)) {
        expect(table.offer(p, clear: p['m'], now: t0), isNull,
            reason: '6.6: a partial message is never displayed');
      }
      expect(table.pending, 1);
      table.sweep(t0.add(XprsPartTable.hold).add(const Duration(seconds: 1)));
      expect(table.pending, 0);
    });

    test('a part that cannot be opened does not close the hole', () {
      final r = xprsBuildDirect(
          head: _head(),
          text: words(40),
          private: true,
          recipientKeyHex: pubB,
          signingKey: dA);
      final table = XprsPartTable();
      XprsReassembled? done;
      for (var i = 0; i < r.packets.length; i++) {
        final p = r.packets[i];
        // Middle part undecryptable.
        final clear =
            i == 1 ? null : xprsReadBody(p, ownKey: dB, senderKeyHex: pubA).clear;
        done = table.offer(p, clear: clear);
      }
      expect(done, isNull);
    });

    test('the part table is bounded against a flood of first-parts', () {
      final table = XprsPartTable();
      for (var i = 0; i < XprsPartTable.maxSets + 40; i++) {
        final p = XprsPacket.parse(
            't:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:00:${i.toString().padLeft(2, '0')} n:1/3 m:part')!;
        table.offer(p, clear: 'part');
      }
      expect(table.pending, lessThanOrEqualTo(XprsPartTable.maxSets));
    });

    test('a set never mixes sealed and plain parts', () {
      final table = XprsPartTable();
      final sealed = XprsPacket.parse(
          't:message f:X1QZ3N d:X1RD89 ts:$_tsA n:1/2 x:AAAA')!;
      final plain = XprsPacket.parse(
          't:message f:X1QZ3N d:X1RD89 ts:$_tsA n:2/2 m:tail')!;
      expect(table.offer(sealed, clear: 'head'), isNull);
      expect(table.offer(plain, clear: 'tail'), isNull,
          reason: 'a form switch mid-set is a different message');
    });
  });

  _pathEvidence();
  _evidenceAge();

  group('the splitter', () {
    test('splits at spaces only, never inside a word', () {
      final chunks = xprsChunkAtSpaces('alpha bravo charlie delta', 12);
      for (final c in chunks) {
        expect(c.trim(), c);
        expect(utf8.encode(c).length, lessThanOrEqualTo(12));
      }
      expect(chunks.join(' '), 'alpha bravo charlie delta');
    });

    test('a hard cut lands on a code-point boundary, never inside an emoji',
        () {
      // 12 emoji = 48 UTF-8 bytes, one "word". A unit-counted cut would have
      // taken 12 UTF-16 units = 6 emoji per part and could split a pair.
      final word = '😀' * 12;
      final chunks = xprsChunkAtSpaces(word, 10); // 10 bytes = 2 emoji + 2 spare
      expect(chunks.join(), word, reason: 'nothing lost, nothing invented');
      for (final c in chunks) {
        expect(utf8.encode(c).length, lessThanOrEqualTo(10));
        expect(c.length.isEven, isTrue, reason: 'no lone surrogate: $c');
        expect(c.runes.every((r) => r == 0x1F600), isTrue);
      }
    });

    test('hard-cuts a word longer than a whole part', () {
      final chunks = xprsChunkAtSpaces('x' * 50, 12);
      expect(chunks.length, greaterThan(1));
      expect(chunks.join(''), 'x' * 50);
    });
  });
}

/*
 * Path evidence (docs/XPRS.md section 36.0).
 *
 * These exist because the bench caught the bug they pin: a private message to a
 * phone with no WiFi went out over the LAN and reached nobody, because another
 * station had relayed that phone's packets onto the LAN and the relayed
 * sighting was counted as evidence of a path.
 */
/// A `ts:` of right now, for the freshness window in the tests below.
String _tsNow() {
  final t = DateTime.now().toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}_'
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

void _pathEvidence() {
  group('a path is chosen on what the station says, not where it was heard',
      () {
    test("a beacon's link: is what counts", () {
      final m = XprsMonitor.instance;
      m.debugReset();
      m.offer(XprsPacket.parse('t:observation f:X1VCVM link:ble ts:${_tsNow()}')!,
          bearer: 'ble', selfCallsign: 'X3ARK');
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(m.stations['X1VCVM']!.declaredBearersFresh(now, 180000),
          contains('ble5'));
    });

    test('a beacon re-aired onto another bearer still says its own', () {
      // The bug this pins: a phone with its WiFi off had its BLE beacon
      // re-aired onto the LAN by a third station. Recording the ARRIVAL bearer
      // made the LAN look like a path to that phone, and a private message went
      // out over the LAN alone and reached nobody.
      //
      // `via:` cannot distinguish the two — nothing transmits it (section 37) —
      // but `link:` describes the sender, so it survives the re-airing intact.
      final m = XprsMonitor.instance;
      m.debugReset();
      m.offer(XprsPacket.parse('t:observation f:X1VCVM link:ble ts:${_tsNow()}')!,
          bearer: 'lan', selfCallsign: 'X3ARK');
      final st = m.stations['X1VCVM']!;
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(st.bearersFresh(now, 180000), contains('lan'),
          reason: 'we did hear it over the LAN');
      expect(st.declaredBearersFresh(now, 180000), ['ble5'],
          reason: 'but the LAN reaches the relayer, not this station');
    });

    test('a station on two bearers declares both', () {
      final m = XprsMonitor.instance;
      m.debugReset();
      m.offer(XprsPacket.parse('t:observation f:X16JK8 link:lan ts:${_tsNow()}')!,
          bearer: 'lan', selfCallsign: 'X3ARK');
      m.offer(XprsPacket.parse('t:observation f:X16JK8 link:ble ts:${_tsNow()}')!,
          bearer: 'ble', selfCallsign: 'X3ARK');
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(m.stations['X16JK8']!.declaredBearersFresh(now, 180000),
          containsAll(['lan', 'ble5']));
    });
  });
}

/*
 * Evidence must age on the packet's own clock (docs/XPRS.md section 4.8).
 */
void _evidenceAge() {
  test('a re-aired old beacon does not read as current', () {
    // The bench bug: a phone whose WiFi had been off for an hour still looked
    // like it was on the LAN, because a third station kept re-airing its old
    // `link:lan` beacon and each arrival was stamped "now".
    final m = XprsMonitor.instance;
    m.debugReset();
    m.offer(
        XprsPacket.parse('t:observation f:X1VCVM link:lan ts:2020-01-01_00:00:00')!,
        bearer: 'lan',
        selfCallsign: 'X3ARK');
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(m.stations['X1VCVM']!.declaredBearersFresh(now, 180000), isEmpty,
        reason: 'composed in 2020; hearing it today does not make it current');
  });
}
