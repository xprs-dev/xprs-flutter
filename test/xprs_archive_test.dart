/*
 * XprsArchive tests — the heard-traffic spool: dup collapse on the derived
 * identifier, zero-hop wire preference, the never-archived types, signature
 * policy at flush, bounded eviction with protected classes, mailbox
 * declarations (13.12) and the query the history replay runs on.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'dart:convert';

import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:sqlite3/open.dart';

final BigInt _d =
    BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);

Uint8List _pubOf(BigInt d) {
  final q = (ECCurve_secp256k1().G * d)!;
  final xHex = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList([
    for (var i = 0; i < 64; i += 2)
      int.parse(xHex.substring(i, i + 2), radix: 16)
  ]);
}

XprsPacket _p(String wire) => XprsPacket.parse(wire)!;

void main() {
  late Directory tmp;
  late XprsArchive a;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprsarchive');
    a = XprsArchive.instance;
    a
      ..selfCallsign = 'X1SELF'
      ..keyResolver = null
      ..protectedCallsigns = null
      ..maxBytes = 500 * 1024 * 1024
      ..maxAgeDays = 365
      ..admitted = 0
      ..dropped = 0
      ..forged = 0
      ..init('${tmp.path}/xprs_archive.sqlite3');
  });

  tearDown(() {
    a.close();
    tmp.deleteSync(recursive: true);
  });

  test('xprsParseTs round-trips the spec format and refuses junk', () {
    expect(xprsParseTs('2026-08-13_12:00:00'),
        DateTime.utc(2026, 8, 13, 12).millisecondsSinceEpoch);
    expect(xprsParseTs('2026-08-13 12:00:00'), isNull);
    expect(xprsParseTs('yesterday'), isNull);
    expect(xprsParseTs(null), isNull);
  });

  test('dup collapse: same id from two sightings is one row, heard=2', () {
    final p = _p('t:info f:X1AAA ts:2026-08-13_10:00:00 m:hello');
    a.admit(p, bearer: 'ble', rssi: -60, nowMs: 1000);
    a.admit(p, bearer: 'ble', rssi: -70, nowMs: 2000);
    a.flush(nowMs: 2000);
    final rows = a.query();
    expect(rows, hasLength(1));
    expect(rows.single['heard'], 2);
    expect(rows.single['id'], xprsIdentifier(p));
  });

  test('zero-hop copy replaces a relayed one, never the reverse', () {
    final clean = _p('t:info f:X1AAA ts:2026-08-13_10:00:00 m:hop test');
    final hopped = clean.with_('via', 'X3RLY7');
    // Relayed copy first, original second: wire upgrades.
    a.admit(hopped, bearer: 'ble', nowMs: 1000);
    a.flush(nowMs: 1000);
    a.admit(clean, bearer: 'ble', nowMs: 2000);
    a.flush(nowMs: 2000);
    expect(a.query().single['wire'], clean.encode());
    // Same id, so a later relayed sighting must not downgrade it back.
    a.admit(hopped, bearer: 'ble', nowMs: 3000);
    a.flush(nowMs: 3000);
    expect(a.query().single['wire'], clean.encode());
  });

  test('ping/pong/receipt/result never stored; command is', () {
    for (final t in ['ping', 'pong', 'receipt', 'result']) {
      a.admit(_p('t:$t f:X1AAA ts:2026-08-13_10:00:00'),
          bearer: 'ble', nowMs: 1000);
    }
    a.admit(_p('t:command f:X1AAA d:X1SELF ts:2026-08-13_10:00:00 cmd:who'),
        bearer: 'ble', nowMs: 1000);
    a.flush(nowMs: 1000);
    final rows = a.query();
    expect(rows, hasLength(1));
    expect(rows.single['type'], 'command');
    expect(rows.single['mine'], true);
  });

  test('forged dropped at flush; unsigned and verified stored with state', () {
    a.keyResolver = (c) => c == 'X1AAA' ? _pubOf(_d) : null;
    final good = xprsSign(
        _p('t:info f:X1AAA ts:2026-08-13_10:00:00 m:signed'), _d);
    final unsigned = _p('t:info f:X1BBB ts:2026-08-13_10:01:00 m:plain');
    // Signed by the wrong key but claiming X1AAA: forged.
    final bad = xprsSign(
        _p('t:info f:X1AAA ts:2026-08-13_10:02:00 m:stolen'),
        BigInt.from(99999));
    a.admit(good, bearer: 'ble', nowMs: 1000);
    a.admit(unsigned, bearer: 'ble', nowMs: 1000);
    a.admit(bad, bearer: 'ble', nowMs: 1000);
    a.flush(nowMs: 1000);
    final rows = a.query();
    expect(rows, hasLength(2));
    final byFrom = {for (final r in rows) r['from']: r};
    expect(byFrom['X1AAA']!['sig'], 'verified');
    expect(byFrom['X1BBB']!['sig'], 'unsigned');
    expect(a.forged, 1);
  });

  test('own and mine survive the byte cap; age cap takes everything', () {
    a.maxBytes = 40 * 1024; // a few pages
    final now = DateTime.utc(2026, 8, 13).millisecondsSinceEpoch;
    // Fill with stranger chatter (unique ts => unique ids), plus one own and
    // one addressed to us, both OLD so eviction order would take them first
    // if they were not protected.
    a.admit(
        _p('t:status f:X1SELF ts:2026-08-01_00:00:00 m:my own words'),
        bearer: 'ble',
        own: true,
        nowMs: now);
    a.admit(
        _p('t:message f:X1AAA d:X1SELF ts:2026-08-01_00:00:01 m:for me'),
        bearer: 'ble',
        nowMs: now);
    for (var i = 0; i < 2000; i++) {
      final mm = (i ~/ 60) % 60, ss = i % 60, hh = 1 + i ~/ 3600;
      a.admit(
          _p('t:info f:X1AAA ts:2026-08-0${1 + (i % 7)}_'
              '${hh.toString().padLeft(2, '0')}:'
              '${mm.toString().padLeft(2, '0')}:'
              '${ss.toString().padLeft(2, '0')} '
              'm:stranger chatter number $i padding padding padding'),
          bearer: 'ble',
          nowMs: now + i);
    }
    // Enough flushes that the every-20th byte-cap pass runs several times.
    for (var i = 0; i < 60; i++) {
      a.flush(nowMs: now + 100000 + i);
    }
    final rows = a.query(limit: 1000);
    expect(rows.length, lessThan(2002));
    expect(rows.any((r) => r['own'] == true), true,
        reason: 'own publication must survive the byte cap');
    expect(rows.any((r) => r['mine'] == true), true,
        reason: 'mail to us must survive the byte cap');
  });

  test('mailbox declarations: verified-only, windows, cancel', () {
    final key = _pubOf(_d);
    a.keyResolver = (c) => c == 'X1BOA3' ? key : null;

    // Unsigned: must not act (13.12).
    expect(
        a.recordMailboxDecl(
            _p('t:mailbox f:X1BOA3 ts:2026-08-13_10:00:00 hold:X1SELF')),
        false);
    // Signed, names us: recorded.
    final decl = xprsSign(
        _p('t:mailbox f:X1BOA3 ts:2026-08-13_10:00:00 hold:X3RLY7,X1SELF'),
        _d);
    expect(a.recordMailboxDecl(decl), true);
    expect(a.hasActiveDecl('X1BOA3'), true);
    expect(a.hasActiveDecl('x1boa3-2'), true, reason: 'base-callsign match');
    // Signed, does not name us: ignored.
    expect(
        a.recordMailboxDecl(xprsSign(
            _p('t:mailbox f:X1BOA3 ts:2026-08-13_10:01:00 hold:X3RLY7'), _d)),
        false);
    // Windowed declaration outside its window is not active.
    final winter = xprsSign(
        _p('t:mailbox f:X1BOA3 ts:2026-08-13_10:02:00 hold:X1SELF '
            'since:2026-11-01_00:00:00 until:2027-03-31_23:59:59'),
        _d);
    expect(a.recordMailboxDecl(winter), true);
    final august = DateTime.utc(2026, 8, 14).millisecondsSinceEpoch;
    final january = DateTime.utc(2027, 1, 10).millisecondsSinceEpoch;
    // Cancel the open-ended one; only winter remains.
    final cancel = xprsSign(
        _p('t:mailbox f:X1BOA3 ts:2026-08-14_09:00:00 '
            'r:${xprsIdentifier(decl)} remove:mailbox'),
        _d);
    expect(a.recordMailboxDecl(cancel), true);
    expect(a.hasActiveDecl('X1BOA3', nowMs: august), false);
    expect(a.hasActiveDecl('X1BOA3', nowMs: january), true);
  });

  // A grant that arrives ONLY over Reticulum -- the one lane a phone on
  // cellular has -- used to reach the archive and never the live roster, so
  // the invitee saw no offer until a restart replayed the record. The radio
  // lane fed every act to XprsGroups; this lane forgot. Same funnel rule.
  test('reticulum lane: a group act moves the LIVE roster, no restart needed',
      () {
    final g = XprsGroups.instance;
    g.clear();
    g.keyResolver = (c) => c == 'X5A3F2' ? _pubOf(_d) : null;
    Uint8List wire(String s) => Uint8List.fromList(utf8.encode(s));
    XprsIngest.reticulum(
        'aa11',
        wire(xprsSign(
                _p('t:moderate f:X5A3F2 d:X5A3F2 ts:2026-08-13_10:00:00 '
                    'grant:X1SELF'),
                _d)
            .encode()));
    expect(g.rosterOf('X5A3F2').roles['X1SELF'], XprsRole.invited,
        reason: 'the offer is live the moment it is heard, on this lane too');
    g.clear();
  });

  test('reticulum lane: refused without a declaration, admitted with one, '
      'monitor untouched', () {
    XprsMonitor.instance.clear();
    final rev = XprsMonitor.instance.revision;
    final before = XprsIngest.refusedRns;
    Uint8List wire(String s) => Uint8List.fromList(utf8.encode(s));

    // A stranger's broadcast over the hub: refused, counted.
    XprsIngest.reticulum(
        'aa11', wire('t:info f:X1AAA ts:2026-08-13_10:00:00 m:hub chatter'));
    a.flush(nowMs: 1000);
    expect(a.query(), isEmpty);
    expect(XprsIngest.refusedRns, before + 1);

    // The author declares us; now its traffic is ours to hold.
    a.keyResolver = (c) => c == 'X1AAA' ? _pubOf(_d) : null;
    XprsIngest.reticulum(
        'aa11',
        wire(xprsSign(
                _p('t:mailbox f:X1AAA ts:2026-08-13_10:01:00 hold:X1SELF'),
                _d)
            .encode()));
    XprsIngest.reticulum(
        'aa11', wire('t:info f:X1AAA ts:2026-08-13_10:02:00 m:now archived'));
    // Mail TO a declared station is held too (we are its mailbox).
    XprsIngest.reticulum('bb22',
        wire('t:message f:X1ZZZ d:X1AAA ts:2026-08-13_10:03:00 m:for them'));
    a.flush(nowMs: 2000);
    final types = a.query().map((r) => r['type']).toList();
    expect(types, containsAll(['mailbox', 'info', 'message']));

    // Nothing on this lane is a SIGHTING (the air's list), but since 0c57aee a
    // station that reached us over Reticulum IS listed, apart from the air,
    // under "On Reticulum" -- so the monitor does move, and the old "revision
    // unchanged" assertion had been failing on main for two days. Assert the
    // behaviour that commit chose: remote, not local.
    expect(XprsMonitor.instance.revision, greaterThan(rev));
    expect(XprsMonitor.instance.remote.keys, containsAll(['X1AAA', 'X1ZZZ']));
    final sections = jsonEncode(XprsMonitor.instance.stationsJson());
    expect(sections, contains('Heard over the air (0)'),
        reason: 'a hub arrival is never an in-earshot sighting');
    expect(sections, contains('On Reticulum (2)'));
  });

  test('reticulum lane records the bearer it actually travelled on', () {
    Uint8List wire(String s) => Uint8List.fromList(utf8.encode(s));
    // A broadcast message (no d:) is a publication, so the declaration gate
    // does not apply — the same rows the chat wapp shows in its rooms.
    XprsIngest.reticulum(
        'aa11', wire('t:message f:X1LAN ts:2026-08-13_10:00:00 m:over the lan'),
        bearer: 'lan');
    XprsIngest.reticulum('bb22',
        wire('t:message f:X1BEN ts:2026-08-13_10:01:00 m:off the bench board'),
        bearer: 'espnow');
    // Nothing said where this one came from: it crossed the internet.
    XprsIngest.reticulum(
        'cc33', wire('t:message f:X1HUB ts:2026-08-13_10:02:00 m:off a hub'));
    a.flush(nowMs: 3000);
    final byFrom = {
      for (final r in a.query()) r['from'] as String: r['bearer'] as String,
    };
    expect(byFrom['X1LAN'], 'lan');
    expect(byFrom['X1BEN'], 'espnow');
    expect(byFrom['X1HUB'], 'rns');
  });

  test('query: to: keeps only the named destinations, "" meaning undirected',
      () {
    // setUp already opened a fresh archive as `a`.
    // Three destinations: a person, a closed group, and nobody (scope:local).
    a.admit(_p('t:message f:X1QZ3N d:X1RD89 ts:2026-08-20_10:00:00 m:mail'),
        bearer: 'ble');
    a.admit(_p('t:message f:X1QZ3N d:X5A3F2 ts:2026-08-20_10:00:01 m:group'),
        bearer: 'ble');
    a.admit(
        _p('t:message f:X1QZ3N ts:2026-08-20_10:00:02 scope:local m:room'),
        bearer: 'ble');
    a.flush();

    // The room's question: undirected plus one group. The 1:1 mail — which on
    // a station mid store-and-forward outnumbers everything and used to eat
    // the whole window — must not appear.
    final rows = a.query(types: const ['message'], to: const ['', 'X5A3F2']);
    expect(rows, hasLength(2));
    expect(rows.map((r) => r['to']).toSet(), {'', 'X5A3F2'});

    // And a single destination still works alone.
    expect(a.query(to: const ['X1RD89']), hasLength(1));
  });

  test('query: window on packet ts, only: matches from or to, newest first',
      () {
    a.admit(_p('t:info f:X1AAA ts:2026-08-13_10:00:00 m:one'),
        bearer: 'ble', nowMs: 1);
    a.admit(_p('t:info f:X1BBB ts:2026-08-13_11:00:00 m:two'),
        bearer: 'ble', nowMs: 2);
    a.admit(_p('t:message f:X1CCC d:X1AAA ts:2026-08-13_12:00:00 m:three'),
        bearer: 'ble', nowMs: 3);
    a.flush(nowMs: 10);

    final all = a.query();
    expect([for (final r in all) r['from']], ['X1CCC', 'X1BBB', 'X1AAA']);

    final only = a.query(only: 'X1AAA');
    expect(only, hasLength(2), reason: 'sender OR addressee');

    final until = xprsParseTs('2026-08-13_12:00:00')!;
    final windowed = a.query(untilMs: until);
    expect(windowed, hasLength(2), reason: 'until is strict <');
    final since = a.query(sinceMs: xprsParseTs('2026-08-13_11:00:00'));
    expect(windowed.length + since.length, 4,
        reason: 'boundary belongs to since side exactly once');
  });

  // ── The station keeps its own log ──────────────────────────────────────
  //
  // An installation is its own archive and indexer, so what it SENT and what
  // was addressed to IT are kept unconditionally. Each of these pins a hole
  // that was silent: no error, no row, nothing to notice.

  test('own packet survives the age prune; a heard one of the same age does not',
      () {
    const dayMs = 86400000;
    final old = DateTime.utc(2020).millisecondsSinceEpoch;
    a.admit(_p('t:info f:X1AAA ts:2020-01-01_10:00:00 m:theirs'),
        bearer: 'ble', nowMs: old);
    a.admit(_p('t:status f:X1SELF ts:2020-01-01_10:00:00 m:mine'),
        bearer: 'ble', own: true, nowMs: old);
    a.admit(_p('t:message f:X1AAA d:X1SELF ts:2020-01-01_10:00:00 m:for me'),
        bearer: 'ble', nowMs: old);
    // The age pass runs once per session, on the first flush — so this is one
    // flush, dated long after the packets it is writing.
    a.flush(nowMs: old + 400 * dayMs);
    final kept = a.query().map((r) => r['wire'] as String).toList();
    expect(kept.any((w) => w.contains('m:mine')), isTrue,
        reason: 'what we said is ours to keep');
    expect(kept.any((w) => w.contains('m:for me')), isTrue,
        reason: 'what was addressed to us is ours to keep');
    expect(kept.any((w) => w.contains('m:theirs')), isFalse,
        reason: "someone else's traffic still ages out — that is the spool");
  });

  test('our own beacons are the exception and do age out', () {
    const dayMs = 86400000;
    final old = DateTime.utc(2020).millisecondsSinceEpoch;
    a.admit(_p('t:observation f:X1SELF ts:2020-01-01_10:00:00 link:ble peers:2'),
        bearer: 'ble', own: true, nowMs: old);
    a.admit(_p('t:status f:X1SELF ts:2020-01-01_10:00:00 m:words'),
        bearer: 'ble', own: true, nowMs: old);
    a.flush(nowMs: old + 400 * dayMs);
    final kept = a.query().map((r) => r['type'] as String).toList();
    expect(kept, contains('status'));
    expect(kept, isNot(contains('observation')),
        reason: 'a beacon is telemetry, not something anybody said');
  });

  test('own() records a wire that no bearer took', () {
    // The bug that started this: a status composed with no radio active was
    // never stored, never shown and reported nothing. It is recorded now, and
    // the bearer says plainly that it aired nowhere.
    //
    // NOT covered here: that own() ignores the xprsArchive preference. This
    // test cannot reach it — PreferencesService has no instance under
    // flutter_test, so the pref reads as its `?? true` default and the old
    // code would pass this too. That path is held by the absence of the early
    // return in own(), not by this test.
    XprsIngest.own('t:status f:X1SELF ts:2026-08-13_10:00:00 m:no bearer',
        bearer: 'none');
    a.flush(nowMs: 1000);
    final rows = a.query();
    expect(rows.length, 1);
    expect(rows.first['own'], isTrue);
    expect(rows.first['bearer'], 'none',
        reason: 'aired nowhere, and the row says so');
  });
  group('a key binding is not chatter (9.3.2, 18.1)', () {
    // It used to be grouped with `observation` and `service`, so a station that
    // was not a super-archiver kept NO identities at all — measured on the
    // bench as a phone with zero key bindings and fifteen receipts it could not
    // verify. Without the binding this station can check no signature (9.1),
    // seal no private message (9.2) and trust no receipt (13.7.1).

    XprsPacket idOf(String call, String ts, {bool key = true}) =>
        XprsPacket.parse(key
            ? 't:identity f:$call ts:$ts '
                'k:npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f'
            : 't:identity f:$call ts:$ts nick:joao')!;

    int idRows(String call) => a
        .query(types: const ['identity'], limit: 100)
        .where((r) => '${r['from']}' == call)
        .length;

    test("a stranger's identity is kept even with chatter off", () {
      a.admit(idOf('X1QZ3N', '2026-08-08_10:00:00'), bearer: 'ble');
      a.flush();
      expect(idRows('X1QZ3N'), 1);
    });

    test('re-announcements collapse to the newest, not one row per half hour',
        () {
      // 18.1 re-announces every 30 minutes and each carries a fresh ts:, so
      // each is a different section 5 identifier and would be its own row.
      for (final t in [
        '2026-08-08_10:00:00',
        '2026-08-08_10:30:00',
        '2026-08-08_11:00:00',
      ]) {
        a.admit(idOf('X1QZ3N', t), bearer: 'ble');
        a.flush();
      }
      expect(idRows('X1QZ3N'), 1, reason: 'newest key-bearing row only');
      final w = '${a.query(types: const ['identity'], limit: 10).first['wire']}';
      expect(w, contains('11:00:00'), reason: 'the NEWEST survives');
    });

    test('a key-only announcement does not evict the decoration', () {
      // 9.3.2 splits the announcement in two because both do not fit, and they
      // are re-sent on different cadences: "the key binding is small and must
      // be repeated often ... the decoration is larger and changes once a year".
      a.admit(idOf('X1QZ3N', '2026-08-08_10:00:00', key: false), bearer: 'ble');
      a.flush();
      a.admit(idOf('X1QZ3N', '2026-08-08_10:30:00'), bearer: 'ble');
      a.flush();
      expect(idRows('X1QZ3N'), 2,
          reason: 'one key-bearing row and one decoration row');
    });

    test('two stations keep two bindings each at most', () {
      for (final c in ['X1QZ3N', 'X1RD89']) {
        for (final t in ['2026-08-08_10:00:00', '2026-08-08_10:30:00']) {
          a.admit(idOf(c, t), bearer: 'ble');
          a.flush();
        }
      }
      expect(idRows('X1QZ3N'), 1);
      expect(idRows('X1RD89'), 1);
    });

    test('an identity does not age out', () {
      // A station heard once a year ago is exactly the one whose signature
      // cannot be checked without its binding.
      a.maxAgeDays = 1;
      a.admit(idOf('X1QZ3N', '2020-01-01_00:00:00'), bearer: 'ble');
      a.flush();
      expect(idRows('X1QZ3N'), 1);
    });
  });

}
