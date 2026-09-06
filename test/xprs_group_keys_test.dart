/*
 * The per-group durable store (docs/XPRS.md 26): a group's public key and its
 * t:moderate acts survive a restart, so a member's roster is rebuilt from the
 * group's own record and not scavenged from the general archive. A restart is
 * simulated by close() + a fresh init() on the same file.
 */
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/xprs/xprs_group_keys.dart';

void main() {
  late Directory tmp;
  late String path;

  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprsgroupkeys');
    path = '${tmp.path}/xprs_groups.sqlite3';
    XprsGroupKeys.instance.init(path);
  });

  tearDown(() {
    XprsGroupKeys.instance.close();
    tmp.deleteSync(recursive: true);
  });

  const g = 'X5A3F2';
  const npub = 'npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f';

  test('a member key and its acts survive a restart', () {
    final k = XprsGroupKeys.instance;
    k.rememberGroupKey(g, npub);
    k.putAct(g, 'aaa111', 't:moderate f:$g d:$g ts:2026-08-08_10:00:00 grant:X1RD89', 1000);
    k.putAct(g, 'bbb222', 't:moderate f:X1RD89 d:$g ts:2026-08-08_11:00:00 r:aaa111 accept:member', 2000);

    // Restart.
    k.close();
    k.init(path);

    expect(k.npubFor(g), npub, reason: 'the group key is durable');
    expect(k.actsFor(g), [
      't:moderate f:$g d:$g ts:2026-08-08_10:00:00 grant:X1RD89',
      't:moderate f:X1RD89 d:$g ts:2026-08-08_11:00:00 r:aaa111 accept:member',
    ], reason: 'oldest first, both acts');
    expect(k.followedGroups(), contains(g));
  });

  test('a member row is not an administered group, and never clobbers a key', () {
    final k = XprsGroupKeys.instance;
    // We admin a group.
    final own = k.create(nick: 'mine')!;
    // We are a member of another.
    k.rememberGroupKey(g, npub);
    // mine() lists only what we administer (a private key), never the member.
    final mineCalls = k.mine().map((e) => e.callsign).toList();
    expect(mineCalls, contains(own.callsign));
    expect(mineCalls, isNot(contains(g)));
    // rememberGroupKey on the administered group does not wipe its nsec.
    k.rememberGroupKey(own.callsign, npub);
    expect(k.scalarFor(own.callsign), isNotNull,
        reason: 'the admin private key is intact');
    // followedGroups covers both.
    expect(k.followedGroups(), containsAll([own.callsign, g]));
  });

  test('a repeated act is stored once; forget clears the group', () {
    final k = XprsGroupKeys.instance;
    k.rememberGroupKey(g, npub);
    k.putAct(g, 'aaa111', 't:moderate one', 1000);
    k.putAct(g, 'aaa111', 't:moderate one', 1000); // same id
    expect(k.actsFor(g), hasLength(1));
    k.forget(g);
    expect(k.actsFor(g), isEmpty);
    expect(k.npubFor(g), isNull);
    expect(k.followedGroups(), isNot(contains(g)));
  });
}
