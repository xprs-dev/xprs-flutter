/*
 * Section 26.4 replay. These rules exist "so that two implementations reach
 * the same answer from the same packets", so they are worth testing as rules
 * rather than as whatever the code happens to do.
 */
import 'dart:typed_data';

import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/nostr_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

const g = 'X5A3F2';
int _ts(String s) => DateTime.parse('${s}Z').millisecondsSinceEpoch;

BigInt _scalar(String privHex) {
  var d = BigInt.zero;
  for (final b in HEX.decode(privHex)) {
    d = (d << 8) | BigInt.from(b);
  }
  return d;
}

/// Every signer gets a real keypair, so the tests exercise verification too --
/// section 26 rests entirely on signatures and a roster that moved on an
/// unverified act would be worthless.
final _keys = <String, ({BigInt d, Uint8List pub})>{};
({BigInt d, Uint8List pub}) _keyFor(String callsign) =>
    _keys.putIfAbsent(callsign, () {
      final kp = NostrCrypto.generateKeyPair();
      return (
        d: _scalar(kp.privateKeyHex),
        pub: Uint8List.fromList(HEX.decode(kp.publicKeyHex))
      );
    });

/// A `t:moderate` as section 26.3 writes them, signed by its `f:`.
XprsPacket _act(String signer, String when, String rest) => xprsSign(
      XprsPacket.parse('t:moderate f:$signer d:$g ts:$when $rest')!,
      _keyFor(signer).d,
    );

/// A member consenting, signed by them (26.3.1). [grantId] is the section 5
/// identifier of the grant being accepted.
XprsPacket _accept(String member, String when, String grantId,
        {String role = 'member'}) =>
    xprsSign(
      XprsPacket.parse(
          't:moderate f:$member d:$g ts:$when r:$grantId accept:$role')!,
      _keyFor(member).d,
    );

XprsPacket _leave(String member, String when) => xprsSign(
      XprsPacket.parse('t:moderate f:$member d:$g ts:$when leave:group')!,
      _keyFor(member).d,
    );

void main() {
  late XprsGroups m;
  final now = _ts('2026-08-20T00:00:00');

  setUp(() {
    m = XprsGroups.instance;
    m.clear();
    m.keyResolver = (call) => _keys[call]?.pub;
  });

  group('membership', () {
    test('a grant alone is an OFFER — nobody is a member without saying so', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89,X32DVA'),
          nowMs: now);
      final r = m.rosterOf(g, nowMs: now);
      expect(r.roles['X1RD89'], XprsRole.invited);
      expect(r.roles['X32DVA'], XprsRole.invited);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isFalse,
          reason: 'a pending grant confers no right to post (26.3.1)');
    });

    test('acceptance makes the member', () {
      final grant = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      m.offer(grant, nowMs: now);
      m.offer(_accept('X1RD89', '2026-08-08_11:00:00', xprsIdentifier(grant)),
          nowMs: now);
      expect(m.rosterOf(g, nowMs: now).roles['X1RD89'], XprsRole.member);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isTrue);
    });

    test('a grant and its acceptance at the SAME ts still make the member', () {
      // A self-grant on group creation signs the grant and the acceptance in
      // the same second. 26.4: membership begins at the acceptance's ts if the
      // grant was in force then — and a same-ts grant is in force. The replay
      // must not drop the acceptance because the id tie-break happened to sort
      // it before its own grant.
      const when = '2026-08-08_10:00:00';
      final grant = _act(g, when, 'grant:X1RD89');
      m.offer(_accept('X1RD89', when, xprsIdentifier(grant)), nowMs: now);
      m.offer(grant, nowMs: now); // arrival order deliberately reversed too
      expect(m.rosterOf(g, nowMs: now).roles['X1RD89'], XprsRole.member);
    });

    test('an acceptance naming the wrong grant does nothing', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89'), nowMs: now);
      m.offer(_accept('X1RD89', '2026-08-08_11:00:00', 'ffffff'), nowMs: now);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isFalse,
          reason: 'the acceptance is evidence of a SPECIFIC offer');
    });

    test('a stranger cannot accept their way in', () {
      final grant = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      m.offer(grant, nowMs: now);
      // X1PZ4Q was never offered anything, and names somebody else's grant.
      m.offer(_accept('X1PZ4Q', '2026-08-08_11:00:00', xprsIdentifier(grant)),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse);
    });

    test('leaving ends it, and consent does not carry across a departure', () {
      final g1 = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      m.offer(g1, nowMs: now);
      m.offer(_accept('X1RD89', '2026-08-08_11:00:00', xprsIdentifier(g1)),
          nowMs: now);
      m.offer(_leave('X1RD89', '2026-08-09_10:00:00'), nowMs: now);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isFalse);

      // Re-offered, but silent this time: an old offer must not re-add them.
      m.offer(_act(g, '2026-08-10_10:00:00', 'grant:X1RD89'), nowMs: now);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isFalse,
          reason: 'a later grant needs a NEW acceptance (26.4)');
    });

    test('the group itself is the admin', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89'), nowMs: now);
      expect(m.rosterOf(g, nowMs: now).roles[g], XprsRole.admin);
    });

    test('revoke removes', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1PZ4Q'), nowMs: now);
      m.offer(_act(g, '2026-08-09_10:00:00', 'revoke:X1PZ4Q'), nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse);
    });
  });

  group('two tiers — only the admin may appoint', () {
    test('a moderator may revoke — once they have accepted the role', () {
      final appoint = _act(g, '2026-08-08_10:00:00', 'grant:X32DVA role:mod');
      m.offer(appoint, nowMs: now);
      m.offer(
          _accept('X32DVA', '2026-08-08_10:30:00', xprsIdentifier(appoint),
              role: 'mod'),
          nowMs: now);
      final gr = _act(g, '2026-08-08_11:00:00', 'grant:X1PZ4Q');
      m.offer(gr, nowMs: now);
      m.offer(_accept('X1PZ4Q', '2026-08-08_11:30:00', xprsIdentifier(gr)),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isTrue);

      m.offer(_act('X32DVA', '2026-08-09_10:00:00', 'revoke:X1PZ4Q'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse);
    });

    test('an appointed moderator who never accepted cannot act', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X32DVA role:mod'),
          nowMs: now);
      final gr = _act(g, '2026-08-08_11:00:00', 'grant:X1PZ4Q');
      m.offer(gr, nowMs: now);
      m.offer(_accept('X1PZ4Q', '2026-08-08_11:30:00', xprsIdentifier(gr)),
          nowMs: now);
      m.offer(_act('X32DVA', '2026-08-09_10:00:00', 'revoke:X1PZ4Q'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isTrue,
          reason: 'an unaccepted appointment carries no authority');
    });

    test('a moderator may NOT appoint', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X32DVA role:mod'),
          nowMs: now);
      m.offer(_act('X32DVA', '2026-08-09_10:00:00', 'grant:X1PZ4Q'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse,
          reason: 'two tiers is the whole hierarchy (26.3)');
    });

    test('a stranger may do nothing', () {
      final gr = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      m.offer(gr, nowMs: now);
      m.offer(_accept('X1RD89', '2026-08-08_10:30:00', xprsIdentifier(gr)),
          nowMs: now);
      m.offer(_act('X1NOPE', '2026-08-09_10:00:00', 'revoke:X1RD89'),
          nowMs: now);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isTrue);
    });
  });

  group('a suspension is a revocation with an end', () {
    test('in force before its moment, lapsed after', () {
      final gr = _act(g, '2026-08-08_10:00:00', 'grant:X1PZ4Q');
      m.offer(gr, nowMs: now);
      m.offer(_accept('X1PZ4Q', '2026-08-08_10:30:00', xprsIdentifier(gr)),
          nowMs: now);
      m.offer(
          _act(g, '2026-08-09_10:00:00',
              'revoke:X1PZ4Q until:2026-08-15_00:00:00'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: _ts('2026-08-10T00:00:00')), isFalse);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: _ts('2026-08-16T00:00:00')), isTrue,
          reason: 'removes them until that moment and no longer');
    });

    test('an until: more than a year past its ts is discarded', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1PZ4Q'), nowMs: now);
      m.offer(
          _act(g, '2026-08-09_10:00:00',
              'revoke:X1PZ4Q until:2030-01-01_00:00:00'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse,
          reason: 'the until: is dropped, so it is a plain revocation');
    });
  });

  group('reading the log', () {
    test('a ts far in the future is discarded', () {
      expect(m.offer(_act(g, '2030-01-01_00:00:00', 'grant:X1RD89'), nowMs: now),
          isFalse);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isFalse);
    });

    test('authority is judged at the moment of the act', () {
      // The moderator acts, and is only removed afterwards. The act stands.
      final ap = _act(g, '2026-08-01_10:00:00', 'grant:X32DVA role:mod');
      m.offer(ap, nowMs: now);
      m.offer(
          _accept('X32DVA', '2026-08-01_10:30:00', xprsIdentifier(ap),
              role: 'mod'),
          nowMs: now);
      final gr = _act(g, '2026-08-01_11:00:00', 'grant:X1PZ4Q');
      m.offer(gr, nowMs: now);
      m.offer(_accept('X1PZ4Q', '2026-08-01_11:30:00', xprsIdentifier(gr)),
          nowMs: now);
      m.offer(_act('X32DVA', '2026-08-02_10:00:00', 'revoke:X1PZ4Q'),
          nowMs: now);
      m.offer(_act(g, '2026-08-03_10:00:00', 'revoke:X32DVA'), nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse,
          reason: 'removing a moderator must not undo their legitimate work');
    });

    test('the admin can void a moderator record with since:', () {
      final ap = _act(g, '2026-08-01_10:00:00', 'grant:X32DVA role:mod');
      m.offer(ap, nowMs: now);
      m.offer(
          _accept('X32DVA', '2026-08-01_10:30:00', xprsIdentifier(ap),
              role: 'mod'),
          nowMs: now);
      final gr = _act(g, '2026-08-01_11:00:00', 'grant:X1PZ4Q');
      m.offer(gr, nowMs: now);
      m.offer(_accept('X1PZ4Q', '2026-08-01_11:30:00', xprsIdentifier(gr)),
          nowMs: now);
      m.offer(_act('X32DVA', '2026-08-02_10:00:00', 'revoke:X1PZ4Q'),
          nowMs: now);
      m.offer(
          _act(g, '2026-08-03_10:00:00',
              'revoke:X32DVA since:2026-08-02_00:00:00'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isTrue,
          reason: 'the compromised moderator\'s acts go with them');
    });

    test('order of arrival does not change the answer', () {
      // Same packets, reversed. The replay sorts, so the result must match.
      final g1 = _act(g, '2026-08-01_10:00:00', 'grant:X1RD89');
      final g2 = _act(g, '2026-08-03_10:00:00', 'grant:X1RD89');
      final wires = [
        g1,
        _accept('X1RD89', '2026-08-01_11:00:00', xprsIdentifier(g1)),
        _act(g, '2026-08-02_10:00:00', 'revoke:X1RD89'),
        g2,
        _accept('X1RD89', '2026-08-03_11:00:00', xprsIdentifier(g2)),
      ];
      for (final w in wires) {
        m.offer(w, nowMs: now);
      }
      final forward = m.mayPost(g, 'X1RD89', nowMs: now);
      m.clear();
      for (final w in wires.reversed) {
        m.offer(w, nowMs: now);
      }
      expect(m.mayPost(g, 'X1RD89', nowMs: now), forward);
      expect(forward, isTrue);
    });

    test('a repeated act is heard once', () {
      final a = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      m.offer(a, nowMs: now);
      m.offer(a, nowMs: now);
      expect(m.groupJson(g)['acts'], 1);
    });
  });

  group('keeping the record', () {
    test('a group act concerns us when it names us, even though d: is the group',
        () {
      final act = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      // The funnel's "addressed to us" test is about d:, and d: is the GROUP.
      expect(m.concernsUs(act, 'X1RD89'), isTrue,
          reason: 'being granted is our own record, not somebody else’s');
      expect(m.concernsUs(act, 'X1NOPE'), isFalse);
    });

    test('a restart replays the roster from the acts we kept', () {
      final grant = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      final accept =
          _accept('X1RD89', '2026-08-08_10:01:00', xprsIdentifier(grant));
      final wires = [grant.encode(), accept.encode()];

      m.clear();
      m.keyResolver = (call) => _keys[call]?.pub;
      expect(m.rosterOf(g, nowMs: now).roles['X1RD89'], isNull,
          reason: 'a fresh station knows nothing');

      expect(m.hydrate(wires), 2);
      expect(m.rosterOf(g, nowMs: now).roles['X1RD89'], XprsRole.member,
          reason: 'the record replays to the same answer it had before');
    });
  });

  group('what a client shows', () {
    test('an acceptance is not a hide — `r:` alone hides nothing (26.3.1)', () {
      final grant = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      m.offer(grant, nowMs: now);
      m.offer(_accept('X1RD89', '2026-08-08_10:01:00', xprsIdentifier(grant)),
          nowMs: now);
      final r = m.rosterOf(g, nowMs: now);
      expect(r.roles['X1RD89'], XprsRole.member);
      expect(r.hidden, isEmpty,
          reason: 'consent names the grant with r:, it does not hide it');
    });

    test('hide:message collects the identifier', () {
      final ap = _act(g, '2026-08-08_10:00:00', 'grant:X32DVA role:mod');
      m.offer(ap, nowMs: now);
      m.offer(
          _accept('X32DVA', '2026-08-08_10:30:00', xprsIdentifier(ap),
              role: 'mod'),
          nowMs: now);
      m.offer(_act('X32DVA', '2026-08-09_10:00:00', 'r:89a9c8 hide:message'),
          nowMs: now);
      expect(m.rosterOf(g, nowMs: now).hidden, contains('89a9c8'));
    });

    test('without the key it fails OPEN and says so', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89'), nowMs: now);
      final r = m.rosterOf(g, nowMs: now, haveKey: false);
      expect(r.verified, isFalse);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now, haveKey: false), isTrue,
          reason: 'must look broken rather than empty (26.7)');
    });
  });

  group('an act that does not verify moves nothing', () {
    test('a forged grant is refused', () {
      // Signed by somebody else, wearing the group's callsign in f:.
      final impostor = xprsSign(
          XprsPacket.parse(
              't:moderate f:$g d:$g ts:2026-08-08_10:00:00 grant:X1PZ4Q')!,
          _keyFor('X1NOPE').d);
      expect(m.offer(impostor, nowMs: now), isFalse);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse);
    });

    test('a key we do not hold yet is counted, not trusted', () {
      m.keyResolver = (_) => null; // nothing learned yet
      expect(m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89'), nowMs: now),
          isFalse);
      expect(m.statusJson()['unverified'], 1);
      expect(m.statusJson()['rejected'], 0,
          reason: 'a missing key is a bootstrap state, not a lie');
    });
  });

  test('role:sub lists a subgroup and confers nothing', () {
    m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X5K2M9 role:sub'),
        nowMs: now);
    final r = m.rosterOf(g, nowMs: now);
    expect(r.roles['X5K2M9'], XprsRole.sub);
    expect(m.mayPost(g, 'X5K2M9', nowMs: now), isFalse,
        reason: 'listing confers no authority (26.2)');
  });
}
