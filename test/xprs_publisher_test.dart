// The status publisher against the spec: one signed packet when it fits,
// section 6.6 parts when it does not (same ts:, split at spaces, sig on the
// last part covering the REASSEMBLED packet), and scope: deciding which
// bearers may carry it. Bearers are fakes — this tests the policy, not radios.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

class _FakeBearer implements XprsBearer {
  _FakeBearer(this.name, {required this.shortRange});
  final bool up = true;
  @override
  final String name;
  @override
  String get archiveBearer => name;
  @override
  final bool shortRange;
  final List<String> sent = [];
  @override
  Future<bool> get active async => up;
  /// The rotation slot the publisher chose, so a test can prove two asks to
  /// two stations no longer share one advert key.
  final List<String> slots = [];
  final List<Duration?> ttls = [];
  @override
  Future<XprsSendResult> send(String wire,
      {required int part, String slot = 'status', Duration? ttl}) async {
    sent.add(wire);
    slots.add(slot);
    ttls.add(ttl);
    return XprsSendResult.sent;
  }
}

void main() {
  _identityAndSlots();
  _oversizeWires();
  _pathChoice();
  TestWidgetsFlutterBinding.ensureInitialized();

  // No active profile in a unit test: the publisher must refuse politely.
  test('no profile -> nothing published', () async {
    final ble = _FakeBearer('ble5', shortRange: true);
    XprsPublisher.instance.bearers = [ble];
    final r = await XprsPublisher.instance.publishStatus('hello out there');
    expect(r, isEmpty);
    expect(ble.sent, isEmpty);
  });

  // The wire-building policy is where the spec lives; test it through the
  // publisher's splitter via a synthetic head (no profile needed).
  test('splitter: parts share ts, split at spaces, sig on last, rejoin',
      () async {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final words = List.generate(120, (i) => 'word$i').join(' ');
    final wires = XprsPublisher.instance.debugWires(head, words);
    expect(wires.length, greaterThan(1));
    expect(wires.length, lessThanOrEqualTo(9));

    final parts = [for (final w in wires) XprsPacket.parse(w)!];
    for (var i = 0; i < parts.length; i++) {
      expect(parts[i]['ts'], '2026-08-13_12:00:00');
      expect(parts[i]['n'], '${i + 1}/${parts.length}');
      expect(parts[i].fits, true, reason: 'part ${i + 1} must fit 250B');
      // Unsigned in a test (no profile key) — sig only ever on the last.
      if (i < parts.length - 1) expect(parts[i]['sig'], isNull);
    }
    // Reassembly (6.6): joined with single spaces = the original text.
    final joined = parts.map((p) => p['m']).join(' ');
    expect(joined, words);
  });

  test('short status is one packet', () {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final wires = XprsPublisher.instance.debugWires(head, 'all quiet here');
    expect(wires, hasLength(1));
    final p = XprsPacket.parse(wires.single)!;
    expect(p.type, 'status');
    expect(p['m'], 'all quiet here');
    expect(p['n'], isNull);
  });

  test('signed when a key is provided: sig verifies over reassembled packet',
      () {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final d = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
    final words = List.generate(80, (i) => 'w$i').join(' ');
    final wires =
        XprsPublisher.instance.debugWires(head, words, signingKey: d);
    final parts = [for (final w in wires) XprsPacket.parse(w)!];
    final sig = parts.last['sig'];
    expect(sig, isNotNull);
    expect(sig!.length, 60); // base85 of a 48-byte short-Schnorr

    // The signature must cover the REASSEMBLED packet (9.1.1): rebuild it,
    // attach the sig, and verify against the x-only public key of [d].
    final joined =
        XprsPacket.parse('$head m:${parts.map((p) => p['m']).join(' ')}')!
            .with_('sig', sig);
    final q = (ECCurve_secp256k1().G * d)!;
    final xHex = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
    final pub = Uint8List.fromList([
      for (var i = 0; i < 64; i += 2)
        int.parse(xHex.substring(i, i + 2), radix: 16)
    ]);
    expect(xprsVerify(joined, pub), XprsSigState.verified);
    // And it must NOT verify as a signature over any single part.
    final lastAlone = parts.last;
    expect(xprsVerify(lastAlone, pub), isNot(XprsSigState.verified));
  });
}

void _identityAndSlots() {
  // A station cannot check a single signature of ours until it has heard the
  // key our callsign signs with, and until then it meters us as a stranger:
  // two history replays an hour instead of six (section 31.2). The packet that
  // fixes that is section 9.3, and it MUST be self-signed — both station
  // firmwares drop one whose signature does not verify against the k: it
  // carries, so an unsigned announcement binds nothing anywhere.
  test('the identity announcement signs for the key it publishes', () {
    final d = BigInt.parse(
        '7b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff001',
        radix: 16);
    final q = (ECCurve_secp256k1().G * d)!;
    final xHex = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
    final pub = Uint8List.fromList([
      for (var i = 0; i < 64; i += 2)
        int.parse(xHex.substring(i, i + 2), radix: 16)
    ]);
    const npub =
        'npub1a67x63c0y4s79lwssfztkt9uryqlvmc2ylujaxdgfqjtu7vpc0xqtrdgfw';

    final wire = XprsPublisher.instance.debugIdentityWire(
        call: 'X1A67X', npub: npub, signingKey: d);
    expect(wire, isNotNull);

    final p = XprsPacket.parse(wire!)!;
    expect(p.type, 'identity');
    expect(p['f'], 'X1A67X');
    expect(p['k'], npub);
    expect(p.has('ts'), isTrue);
    expect(xprsVerify(p, pub), XprsSigState.verified);

    // 171 bytes in the spec; the smallest controller measured in
    // docs/ble5.md section 3 carries 184, and an oversized advert is refused
    // rather than truncated. No nick:, no room for one.
    expect(p.fits, isTrue);
    expect(wire.length, lessThanOrEqualTo(184));
  });

  // Re-registering an advert key REPLACES that rotation entry. Every publish
  // used to share one key, so a sweep asking N stations back to back put only
  // the last ask on air and took the user's status with it.
  test('two asks to two stations occupy two advert slots', () async {
    final b = _FakeBearer('ble5', shortRange: true);
    XprsPublisher.instance.bearers = [b];

    await XprsPublisher.instance
        .publishWire('t:command f:X1SELF d:X3AAAA ts:x scope:local cmd:history');
    await XprsPublisher.instance
        .publishWire('t:command f:X1SELF d:X3BBBB ts:x scope:local cmd:history');

    expect(b.sent, hasLength(2));
    expect(b.slots, ['command:X3AAAA', 'command:X3BBBB']);
    expect(b.slots.toSet(), hasLength(2),
        reason: 'sharing one slot is what silently dropped every ask but one');
  });
}

// A caller-composed wire that outgrew one packet.
//
// `hal_xprs_send` refused these on the same line as a wire that did not parse,
// so a wapp with 300 bytes to say had no way to say it — which is one of the
// reasons a wapp kept a long-message transport of its own.
void _oversizeWires() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('publishWire: an oversize wire is split at spaces, not refused',
      () async {
    final ble = _FakeBearer('ble5', shortRange: true);
    XprsPublisher.instance.bearers = [ble];
    final words = List.generate(90, (i) => 'w$i').join(' ');
    final wire = 't:message f:X1TEST d:X1PEER '
        'ts:2026-09-02_12:00:00 m:$words';
    expect(XprsPacket.parse(wire)!.fits, isFalse,
        reason: 'the fixture has to be over the limit to test anything');

    await XprsPublisher.instance.publishWire(wire, verbatim: true);
    // verbatim relays somebody else's packet; re-splitting it would recompose
    // it under a new §5 identity, so it stays refused.
    expect(ble.sent, isEmpty);

    await XprsPublisher.instance.publishWire(wire);
    expect(ble.sent.length, greaterThan(1));
    // Every part is a whole packet, carries n:i/total, and none exceeds the
    // limit that made the original too long.
    final bodies = <String>[];
    for (var i = 0; i < ble.sent.length; i++) {
      final p = XprsPacket.parse(ble.sent[i]);
      expect(p, isNotNull);
      expect(p!.fits, isTrue);
      expect(p['n'], '${i + 1}/${ble.sent.length}');
      expect(p['d'], 'X1PEER', reason: 'the envelope rides on every part');
      bodies.add(p['m'] ?? '');
    }
    expect(bodies.join(' '), words, reason: 'rejoins to the original body');
  });
}


// Section 36.0's path choice, isolated from the radios: a lane whose route is
// PROVEN is never suppressed by one a peer only CLAIMS. These drive the pure
// decision directly, so no transport, GATT peer or monitor is needed.
void _pathChoice() {
  group('choosePreferredBearer (§36.0: proven beats claimed)', () {
    String? pick({
      bool session = false,
      bool net = false,
      Set<String> declared = const {},
    }) =>
        XprsPublisher.choosePreferredBearer(
            bleSessionProven: session, netProven: net, declaredLocal: declared);

    test('a live BLE session wins outright — fastest AND proven', () {
      // Same-desk phones: prove the short-range lane and it beats everything,
      // including a live internet route (no 18 hops to the same desk).
      expect(pick(session: true, net: true, declared: {'ble5'}), 'ble5');
      expect(pick(session: true), 'ble5');
    });

    test('a claimed local link does NOT suppress a proven internet route', () {
      // THE BUG: a phone on another network still advertises `link:ble` into
      // our ear (relayed, indistinguishable without via:). With a live rns
      // route and no session to prove the ble claim, fan out so reticulum — the
      // one path we can prove — gets its copy. This is the receipt case.
      expect(pick(net: true, declared: {'ble5'}), isNull);
      expect(pick(net: true, declared: {'lan'}), isNull);
      expect(pick(net: true, declared: {'lan', 'ble5'}), isNull);
    });

    test('a local mesh with no internet route uses the declared link', () {
      // An ESP32 or radio-only peer: the beacon `link:` is the best evidence
      // there is, ranked by bandwidth. Nothing to be suppressed by here.
      expect(pick(declared: {'ble5'}), 'ble5');
      expect(pick(declared: {'lan', 'ble5'}), 'lan');
      // lora is deliberately absent from the bandwidth ranking (its bearer
      // refuses sends until a radio ships), so a lora-only claim fans out — the
      // same as before this change.
      expect(pick(declared: {'lora'}), isNull);
    });

    test('a proven route and nothing local takes the internet lane', () {
      // A peer only the hubs can reach: pin reticulum rather than fan a
      // directed packet onto every radio.
      expect(pick(net: true), 'reticulum');
    });

    test('no evidence at all fans out', () {
      expect(pick(), isNull);
    });

    test('a declared bearer we do not rank is not chosen', () {
      // declaredLocal only ever carries lan/ble5/lora; anything else means the
      // caller mislabelled a lane, and pinning an unknown name would silence
      // the fan-out. Fall through instead.
      expect(pick(declared: {'espnow'}), isNull);
    });
  });
}
