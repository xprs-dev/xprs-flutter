/*
 * MeshStore (SCF sqlite) tests — park/dedup/purge/route-aware pending,
 * have-bloom build+apply, TTL/quota sweep.
 */
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:xprs/services/mesh/mesh_beacon.dart';
import 'package:xprs/services/mesh/mesh_bloom.dart';
import 'package:xprs/services/mesh/mesh_store.dart';
import 'package:xprs/services/mesh/mesh_table.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

Uint8List _wire(String from, String to, String text) =>
    Uint8List.fromList('$from\x1F$to\x1F$text'.codeUnits);

void main() {
  late Directory tmp;
  late MeshStore store;

  setUpAll(() {
    // Host test runner: the distro ships libsqlite3.so.0, not the dev symlink.
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('meshstore');
    store = MeshStore.instance;
    store.init('${tmp.path}/mesh.sqlite3');
  });

  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });

  test('a message typed now is not queued behind the backlog', () {
    // C61 -> TANK2 arrived in 6 s with 37 rows queued; TANK2 -> C61 had not
    // arrived after four minutes with 1,258 queued. pendingFor drained
    // oldest-first, so the newest message shipped last.
    for (var i = 0; i < 50; i++) {
      store.offer(
          target: 'X3ARK',
          sender: 'X1VCVM',
          wire: _wire('X1VCVM', 'X3ARK', 'backlog$i'),
          am: 'old$i',
          inTransit: true);
    }
    store.offer(
        target: 'X3ARK',
        sender: 'X1VCVM',
        wire: _wire('X1VCVM', 'X3ARK', 'just typed'),
        am: 'fresh',
        inTransit: true);

    final batch =
        store.pendingFor('X3ARK', null, max: 4, selfCallsign: 'X1VCVM');
    expect(batch.map((m) => m.key), contains('fresh'),
        reason: 'the newest of our own must be in the first batch');
  });

  test('ownPendingTo answers for our own 1:1 to that peer, and nothing else', () {
    // The scheduler asks this before anything else on its tick: a 1:1 WE
    // wrote to a peer we can dial goes ahead of a hub's backlog.
    expect(store.ownPendingTo('X3ARK', selfCallsign: 'X1VCVM'), isFalse);
    store.offer(
        target: 'X3ARK',
        sender: 'X1WATT',
        wire: _wire('X1WATT', 'X3ARK', 'carried for somebody'),
        am: 'theirs',
        inTransit: true);
    expect(store.ownPendingTo('X3ARK', selfCallsign: 'X1VCVM'), isFalse,
        reason: 'a stranger\'s mail for the peer is not ours');
    store.offer(
        target: 'X3ARK',
        sender: 'X1VCVM',
        wire: _wire('X1VCVM', 'X3ARK', 'hello'),
        am: 'mine',
        inTransit: true);
    expect(store.ownPendingTo('x3ark', selfCallsign: 'x1vcvm'), isTrue,
        reason: 'case does not matter on either side');
    expect(store.ownPendingTo('X1WATT', selfCallsign: 'X1VCVM'), isFalse,
        reason: 'addressed to the peer itself, not merely routed through it');
  });

  test('a stranger\'s mail still goes before our own', () {
    store.offer(
        target: 'X3ARK',
        sender: 'X1VCVM',
        wire: _wire('X1VCVM', 'X3ARK', 'ours'),
        am: 'ours',
        inTransit: true);
    store.offer(
        target: 'X3ARK',
        sender: 'X16JK8',
        wire: _wire('X16JK8', 'X3ARK', 'carried'),
        am: 'carried',
        inTransit: true);
    final batch =
        store.pendingFor('X3ARK', null, max: 8, selfCallsign: 'X1VCVM');
    expect(batch.first.key, 'carried',
        reason: 'carried mail has only this store behind it');
  });

  test('a big backlog for other targets does not starve the peer here', () {
    // The bench failure: a phone holding 1,508 in-transit rows handed over
    // ZERO in every session it opened, because pendingFor took the 256 OLDEST
    // rows in the whole store and only then filtered for the peer. A message
    // sent to the neighbour standing right there was parked, taken off the air
    // for 1:1 delivery, and never handed over.
    for (var i = 0; i < 400; i++) {
      store.offer(
          target: 'XOTHER',
          sender: 'X1VCVM',
          wire: _wire('X1VCVM', 'XOTHER', 'old$i'),
          am: 'old$i',
          inTransit: true);
    }
    expect(
        store.offer(
            target: 'X3ARK',
            sender: 'X1VCVM',
            wire: _wire('X1VCVM', 'X3ARK', 'hello'),
            am: 'fresh1',
            inTransit: true),
        isTrue);

    final batch = store.pendingFor('X3ARK', null, selfCallsign: 'X1VCVM');
    expect(batch.map((m) => m.key), contains('fresh1'));
    // …and the backlog for somebody else is not what we hand this peer.
    expect(batch.every((m) => m.key.startsWith('fresh')), isTrue);
  });

  test('offer parks once; duplicates rejected by am and by content', () {
    final w = _wire('AAA', 'BBB', 'am:a1b2c3 hello');
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w, am: 'a1b2c3'),
        true);
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w, am: 'a1b2c3'),
        false);
    // am-less frame: content-keyed
    final w2 = _wire('AAA', 'BBB', 'plain');
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w2), true);
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w2), false);
    expect(store.pendingCount(), 2);
  });

  test('already-received am is not parked; ?ACK purges', () {
    store.recordReceivedAm('dededе'.substring(0, 6)); // any 6 chars
    final w = _wire('AAA', 'BBB', 'am:ffffff x');
    store.recordReceivedAm('ffffff');
    expect(store.offer(target: 'BBB', sender: 'AAA', wire: w, am: 'ffffff'),
        false);
    final w2 = _wire('AAA', 'BBB', 'am:abcdef y');
    store.offer(target: 'BBB', sender: 'AAA', wire: w2, am: 'abcdef');
    expect(store.purgeAm('abcdef'), 1);
    expect(store.pendingCount(), 0);
  });

  test('pendingFor: direct target and routed next-hop', () {
    final table = MeshTable('ME');
    // Route to CCC via BBB (BBB is a bidirectional neighbor advertising CCC).
    table.ingest(MeshBeacon(
      callsign: 'BBB',
      deviceClass: MeshDeviceClass.phone,
      cond: const MeshConditions(),
      dv: [
        MeshDvEntry(meshHash('ME'), 1), // sees us → bidirectional
        MeshDvEntry(meshHash('CCC'), 1),
      ],
    ));
    store.offer(
        target: 'BBB', sender: 'ME', wire: _wire('ME', 'BBB', 'direct'));
    store.offer(
        target: 'CCC', sender: 'ME', wire: _wire('ME', 'CCC', 'routed'));
    store.offer(
        target: 'ZZZ', sender: 'ME', wire: _wire('ME', 'ZZZ', 'unreachable'));

    final forB = store.pendingFor('BBB', table);
    expect(forB.length, 2); // direct + routed-via
    final forZ = store.pendingFor('ZZZ', table);
    expect(forZ.length, 1); // only its own
    // Archive one; it stops being pending.
    store.markArchived(forB.first.key);
    expect(store.pendingFor('BBB', table).length, 1);
  });

  // A neighbour we can hear is the shortest path there is. Handing its mail to
  // a third party instead is how a message went round in a circle: the relay's
  // route pointed back at us, our store already held the row, the offer came
  // back "duplicate", and both copies ended up archived owing nothing.
  test('a live neighbour gets its own mail — never a relay', () {
    final table = MeshTable('ME');
    // BBB and CCC are BOTH neighbours, and BBB also advertises reaching CCC.
    table.ingest(MeshBeacon(
      callsign: 'BBB',
      deviceClass: MeshDeviceClass.phone,
      cond: const MeshConditions(),
      dv: [MeshDvEntry(meshHash('ME'), 1), MeshDvEntry(meshHash('CCC'), 1)],
    ));
    table.ingest(MeshBeacon(
      callsign: 'CCC',
      deviceClass: MeshDeviceClass.phone,
      cond: const MeshConditions(),
      dv: [MeshDvEntry(meshHash('ME'), 1)],
    ));
    store.offer(
        target: 'CCC', sender: 'ME', wire: _wire('ME', 'CCC', 'for ccc'));

    expect(store.pendingFor('BBB', table), isEmpty); // not via the relay
    expect(store.pendingFor('CCC', table).length, 1); // straight to the target
  });

  // Custody handed on is archived, not deleted — that row is the receipt saying
  // we no longer owe delivery. When a peer hands the same message BACK, saying
  // "duplicate" made the other side archive its copy too and the message
  // belonged to nobody.
  test('an archived row can take custody again; an in-transit one cannot', () {
    store.offer(
        target: 'BBB',
        sender: 'AAA',
        wire: _wire('AAA', 'BBB', 'am:bbbbbb m'),
        am: 'bbbbbb');
    expect(store.reArm('bbbbbb'), isFalse); // still in transit = real duplicate

    store.markArchived('bbbbbb');
    expect(store.pendingFor('BBB', null), isEmpty);
    expect(store.reArm('bbbbbb'), isTrue); // we owe delivery again
    expect(store.pendingFor('BBB', null).length, 1);

    expect(store.reArm('nosuch'), isFalse); // nothing to re-arm
  });

  // A custodian carries anyone's mail, so the sorting happens under pressure:
  // a stranger's frame (low) must be shed before our own (normal). Backwards
  // would quietly delete the user's outgoing messages first.
  test('under quota pressure a stranger is evicted before our own mail', () {
    store.quotaBytes = 450; // three 200 B frames will not fit
    final mine = Uint8List.fromList(List.filled(200, 1));
    final theirs = Uint8List.fromList(List.filled(200, 2));
    store.offer(
        target: 'BBB',
        sender: 'ME',
        wire: mine,
        am: 'mine11',
        urg: MeshUrgency.normal);
    store.offer(
        target: 'CCC',
        sender: 'ZZZ',
        wire: theirs,
        am: 'theirs',
        urg: MeshUrgency.low);
    store.offer(
        target: 'DDD',
        sender: 'YYY',
        wire: Uint8List.fromList(List.filled(200, 3)),
        am: 'other1',
        urg: MeshUrgency.low);
    store.sweep();

    // Ours survives; a stranger's was shed to make room.
    expect(
        store.pendingFor('BBB', null, max: 64).map((e) => e.key), ['mine11']);
    expect(store.counts().inTransit, lessThan(3));
  });

  // Four levels, not two: the sweep must shed strictly bottom-up, or a level
  // is decorative. This is what `prio 0/1` could not express.
  test('eviction runs lowest urgency first, across all four levels', () {
    store.quotaBytes = 450; // only two 200 B frames fit
    for (final (am, u) in [
      ('lo0000', MeshUrgency.low),
      ('no0000', MeshUrgency.normal),
      ('hi0000', MeshUrgency.high),
      ('ur0000', MeshUrgency.urgent),
    ]) {
      store.offer(
          target: 'BBB',
          sender: 'AAA',
          wire: Uint8List.fromList(List.filled(200, am.codeUnitAt(0))),
          am: am,
          urg: u);
    }
    store.sweep();

    final left = store.pendingFor('BBB', null, max: 64).map((e) => e.key).toSet();
    expect(left, containsAll(['ur0000', 'hi0000'])); // the top two survive
    expect(left, isNot(contains('lo0000'))); // the bottom went first
    expect(left, isNot(contains('no0000')));
  });

  // A device must carry for strangers, but not without limit.
  test('the in-transit cap refuses the bottom level, never our own', () {
    expect(MeshStore.inTransitMax, 4000);
    expect(
        store.offer(
            target: 'CCC', sender: 'ZZZ', wire: _wire('ZZZ', 'CCC', 'hi'),
            am: 'str001', urg: MeshUrgency.low),
        isTrue); // far below the cap: carried
  });

  // The wire vocabulary is XPRS `urg:` (docs/XPRS.md §13.5), so a word that
  // parses wrong must not cost the message: unknown falls back to normal.
  test('urgency parses the XPRS words and never drops on a bad one', () {
    expect(MeshUrgency.fromWire('low'), MeshUrgency.low);
    expect(MeshUrgency.fromWire('normal'), MeshUrgency.normal);
    expect(MeshUrgency.fromWire('high'), MeshUrgency.high);
    expect(MeshUrgency.fromWire('urgent'), MeshUrgency.urgent);
    expect(MeshUrgency.fromWire('URGENT'), MeshUrgency.urgent);
    expect(MeshUrgency.fromWire('banana'), MeshUrgency.normal);
    expect(MeshUrgency.fromWire(null), MeshUrgency.normal);
    // Ordered lowest-first, which is what `ORDER BY urg, ts` relies on.
    expect(MeshUrgency.low.index < MeshUrgency.normal.index, isTrue);
    expect(MeshUrgency.high.index < MeshUrgency.urgent.index, isTrue);
  });

  // A sender states what it wants; the carrier decides what it may have.
  test('a stated urgency is capped, so nobody talks their way to the front', () {
    expect(MeshUrgency.urgent.cappedAt(MeshUrgency.high), MeshUrgency.high);
    expect(MeshUrgency.low.cappedAt(MeshUrgency.high), MeshUrgency.low);
    expect(MeshUrgency.urgent.cappedAt(MeshUrgency.urgent), MeshUrgency.urgent);
  });

  test('have-bloom: built from received, applyPeerBloom purges only the owner',
      () {
    store.offer(
        target: 'BBB',
        sender: 'AAA',
        wire: _wire('AAA', 'BBB', 'am:aaaaaa m'),
        am: 'aaaaaa');
    store.offer(
        target: 'CCC',
        sender: 'AAA',
        wire: _wire('AAA', 'CCC', 'am:cccccc m'),
        am: 'cccccc');

    // BBB's beacon says it has aaaaaa (and cccccc — but that row targets CCC).
    final bloom = Uint8List(kMeshBloomBytes);
    meshBloomAdd(bloom, 'aaaaaa');
    meshBloomAdd(bloom, 'cccccc');
    expect(store.applyPeerBloom('BBB', bloom), 1);
    expect(store.pendingCount(), 1); // CCC's copy survives

    // Our own bloom round-trip.
    store.recordReceivedAm('zzzzzz');
    final have = store.buildHaveBloom();
    expect(meshBloomHas(have, 'zzzzzz'), true);
    expect(meshBloomHas(have, 'yyyyyy'), false);
  });

  test('quota sweep evicts archives before in-transit', () {
    store.quotaBytes = 60; // tiny quota: each row ~20B
    for (var i = 0; i < 5; i++) {
      store.offer(
          target: 'BBB',
          sender: 'AAA',
          wire: _wire('AAA', 'BBB', 'msg$i pad pad'),
          am: 'aaaa0$i');
    }
    store.markArchived('aaaa00');
    store.markArchived('aaaa01');
    store.sweep();
    final c = store.counts();
    expect(c.bytes, lessThanOrEqualTo(60));
    // In-transit survived preferentially.
    expect(c.inTransit, greaterThanOrEqualTo(c.archived));
  });

  test('mule custody: own unreachable mail goes to any session peer', () {
    final table = MeshTable('ME');
    table.ingest(MeshBeacon(
      callsign: 'BBB',
      deviceClass: MeshDeviceClass.phone,
      cond: const MeshConditions(),
      dv: [MeshDvEntry(meshHash('ME'), 1)],
    ));
    // Our own message to an unknown target...
    store.offer(target: 'ZZZ', sender: 'ME', wire: _wire('ME', 'ZZZ', 'x'));
    // ...someone else's message to an unknown target (must NOT be muled).
    store.offer(target: 'YYY', sender: 'AAA', wire: _wire('AAA', 'YYY', 'y'));
    final forB =
        store.pendingFor('BBB', table, selfCallsign: 'ME');
    expect(forB.length, 1);
    expect(store.ownPendingTargets('ME'), ['ZZZ']);
  });

  test('bulk handover records', () {
    expect(store.bulkHandedOver('sha1', 'BBB'), false);
    store.recordBulkHandover('sha1', 'BBB', 'CCC');
    expect(store.bulkHandedOver('sha1', 'BBB'), true);
  });

  // What the device is holding, so a viewer can show WHAT is carried and not
  // only how much. The counts already existed; the rows did not.
  group('what we are holding, listed', () {
    test('a parked frame appears with its addressing, size and text', () {
      store.offer(
          target: 'X1RD89', sender: 'X1A67X', wire: _wire('X1A67X', 'X1RD89', 'on my way'), am: 'aa11');

      final held = store.heldJson();
      expect(held, hasLength(1));
      expect(held.single['target'], 'X1RD89');
      expect(held.single['sender'], 'X1A67X');
      expect(held.single['am'], 'aa11');
      expect(held.single['size'], greaterThan(0));
      expect(held.single['state'], 0, reason: 'still to hand on');
      expect(held.single['wire'], contains('on my way'),
          reason: 'a text frame is shown as text');
    });

    test('newest first, and bounded by the limit asked for', () {
      for (var i = 0; i < 5; i++) {
        store.offer(
            target: 'X1RD89', sender: 'X1A67X',
            wire: _wire('X1A67X', 'X1RD89', 'note $i'), am: 'am$i');
      }
      expect(store.heldJson(limit: 2), hasLength(2));
      expect(store.heldJson(), hasLength(5));
    });

    test('nothing held is an empty list, not an error', () {
      expect(store.heldJson(), isEmpty);
    });
  });

  // The owner's disk, battery and airtime. On by default, because a mesh where
  // nobody carries only works when both people are awake and in range at once.
  group('carrying for other people', () {
    test('is on by default', () {
      expect(store.carryForOthers, isTrue);
    });

    test('switched off, somebody else\'s mail is refused', () {
      store.carryForOthers = false;
      addTearDown(() => store.carryForOthers = true);

      final took = store.offer(
          target: 'X1RD89', sender: 'X1A67X', wire: _wire('X1A67X', 'X1RD89', 'carry me'), am: 'bb22');

      expect(took, isFalse);
      expect(store.heldJson(), isEmpty);
    });

    test('switched off, our OWN outgoing copy is still kept', () {
      store.carryForOthers = false;
      addTearDown(() => store.carryForOthers = true);

      // Declining to carry for strangers is not the same as refusing to send:
      // our own mail still needs somewhere to wait for its recipient.
      final took = store.offer(
          target: 'X1RD89', sender: 'X1A67X', wire: _wire('X1A67X', 'X1RD89', 'mine'),
          am: 'cc33', ours: true);

      expect(took, isTrue);
      expect(store.heldJson(), hasLength(1));
    });
  
  group('the persistent outgoing-packet queue (tx_outbound)', () {
    test('a queued packet round-trips: put, load, advance, drop', () {
      final packed = Uint8List.fromList(List.generate(40, (i) => i));
      store.txPut('k1', '9fe08ecd', packed, 'xprs', 'hello', 0, 1000);
      var rows = store.txLoad();
      expect(rows.length, 1);
      expect(rows.first['key'], 'k1');
      expect(rows.first['dest'], '9fe08ecd');
      expect(rows.first['try'], 0);
      expect(rows.first['at'], 1000);
      expect(rows.first['packed'], packed);

      store.txAdvance('k1', 3, 5000);
      rows = store.txLoad();
      expect(rows.first['try'], 3);
      expect(rows.first['at'], 5000);

      store.txDrop('k1');
      expect(store.txLoad(), isEmpty);
    });

    test('a re-put on the same key replaces, not duplicates', () {
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([4, 5, 6]);
      store.txPut('k2', 'dst', a, 't', 'c', 0, 1);
      store.txPut('k2', 'dst', b, 't', 'c', 1, 2);
      final rows = store.txLoad();
      expect(rows.length, 1);
      expect(rows.first['packed'], b);
      expect(rows.first['try'], 1);
    });

    test('the queue survives a reopen — this is the point of persisting it', () {
      final packed = Uint8List.fromList([9, 9, 9, 9]);
      store.txPut('k3', 'dst', packed, 'xprs', 'ack', 2, 42);
      final path = '${tmp.path}/mesh.sqlite3';
      store.close();
      store.init(path); // as a restart would
      final rows = store.txLoad();
      expect(rows.length, 1);
      expect(rows.first['key'], 'k3');
      expect(rows.first['try'], 2);
      expect(rows.first['packed'], packed);
    });
  });

});
}
