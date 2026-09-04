// Durable conversation history: the properties that had to hold for a phone
// to stop losing every message it had ever received.
import 'dart:ffi';
import 'dart:io';

import 'package:xprs/services/log_service.dart';
import 'package:xprs/wapp/geoui/conversation_db.dart';
import 'package:xprs/wapp/geoui/conversation_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
        OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'),
      );
    }
  });

  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('convo_db_test');
    dbPath = '${tmp.path}/conversations.sqlite3';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConversationStore attached(ConversationDb db, {String field = 'conversations'}) =>
      ConversationStore()
        ..db = db
        ..dbField = field
        ..loaded = true;

  /// Reopen the way the page does: `loadInto` restores the THREAD rows, then
  /// the store is attached so a conversation's message tail is read when
  /// something actually looks at it. Loading every thread's messages up front
  /// is the cost this split removed, so the tests reopen the same way the app
  /// does rather than asserting the old shape.
  ConversationStore reopen(ConversationDb db,
      {String field = 'conversations'}) {
    final store = ConversationStore()
      ..dbField = field
      ..loaded = false;
    db.loadInto(field, store);
    return store
      ..db = db
      ..loaded = true;
  }

  test('messages survive close and reopen', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'lxmf:abc', 'title': 'X1RD89'});
    store.addMessage({'id': 'lxmf:abc', 'dir': 'in', 'text': 'LIVE-D2P-001'});
    store.addMessage({'id': 'lxmf:abc', 'dir': 'out', 'text': 'LIVE-P2D-001'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = reopen(db2);
    expect(restored.items['lxmf:abc']!.title, 'X1RD89');
    expect(
      restored.messagesOf('lxmf:abc').map((m) => m['text']).toList(),
      ['LIVE-D2P-001', 'LIVE-P2D-001'],
    );
    db2.close();
  });

  test('a store that failed to load never writes', () {
    // Seed real history.
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'c1', 'title': 'kept'});
    store.addMessage({'id': 'c1', 'dir': 'in', 'text': 'precious'});
    db.close();

    // A page whose restore threw: db handle present, loaded false.
    final db2 = ConversationDb.open(dbPath);
    final broken = ConversationStore()
      ..db = db2
      ..dbField = 'conversations'
      ..loaded = false;
    broken.upsert({'id': 'c1', 'title': 'clobbered'});
    broken.addMessage({'id': 'c1', 'dir': 'in', 'text': 'overwrite'});
    broken.clear();
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    final check = reopen(db3);
    expect(check.items['c1']?.title, 'kept', reason: 'history was overwritten');
    expect(check.messagesOf('c1').single['text'], 'precious');
    db3.close();
  });

  test('a message carrying a mid is stored once', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    for (var i = 0; i < 3; i++) {
      store.addMessage(
          {'id': 'g', 'dir': 'in', 'text': 'hello', 'mid': 'abc123'});
    }
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = reopen(db2);
    expect(restored.messagesOf('g'), hasLength(1));
    db2.close();
  });

  test('the same message re-emitted after an engine restart shows once', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    // No mid (a 1:1 LXMF message), same content signature both times.
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'VERIFY', 'key': 'sig1'});
    db.close();

    // Engine restarts, re-reads the durable inbox, re-emits the same message.
    final db2 = ConversationDb.open(dbPath);
    final reloaded = reopen(db2);
    reloaded
        .addMessage({'id': 'c', 'dir': 'in', 'text': 'VERIFY', 'key': 'sig1'});
    expect(reloaded.messagesOf('c'), hasLength(1));
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    final check = reopen(db3);
    expect(check.messagesOf('c'), hasLength(1));
    db3.close();
  });

  test('a database written before the ckey column still opens', () {
    // Simulate the older schema exactly: no ckey column, one stored message.
    final legacyDb = ConversationDb.open(dbPath);
    legacyDb.close();
    final raw = sqlite3.open(dbPath);
    raw.execute('DROP INDEX IF EXISTS msg_key');
    raw.execute('ALTER TABLE messages DROP COLUMN ckey');
    raw.execute(
        "INSERT INTO messages(field, convo_id, mid, body) VALUES('conversations','c','', ?)",
        ['{"dir":"in","text":"older build"}']);
    raw.dispose();

    final db = ConversationDb.open(dbPath); // must NOT throw
    final restored = reopen(db);
    expect(restored.messagesOf('c').single['text'], 'older build');
    db.close();
  });

  test('two engines emitting the same message id show one bubble', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    // Page engine and headless engine each cursor the host inbox from 0 and
    // re-emit the same LXMF message: same mid (its hash), no content key.
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'once', 'mid': 'h1'});
    store.addMessage({'id': 'c', 'dir': 'in', 'text': 'once', 'mid': 'h1'});
    expect(store.items['c']!.messages, hasLength(1));
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final check = reopen(db2);
    expect(check.messagesOf('c'), hasLength(1));
    db2.close();
  });

  test('legacy JSON imports once, then the DB owns the history', () {
    final legacy = ConversationStore();
    legacy.upsert({'id': 'old', 'title': 'from json'});
    legacy.addMessage({'id': 'old', 'dir': 'in', 'text': 'archived'});

    final db = ConversationDb.open(dbPath);
    expect(db.hasField('conversations'), isFalse);
    db.importStore('conversations', legacy);
    expect(db.hasField('conversations'), isTrue);

    final restored = reopen(db);
    expect(restored.messagesOf('old').single['text'], 'archived');
    db.close();
  });

  test('delivery receipts and reactions survive a reopen', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.addMessage(
        {'id': 'c', 'dir': 'out', 'text': 'hi', 'rid': 'r1', 'mid': 'm1'});
    store.setStatus({'rid': 'r1', 'status': 'delivered'});
    store.react({'mid': 'm1', 'from': 'someone'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = reopen(db2);
    final msg = restored.messagesOf('c').single;
    expect(msg['status'], 'delivered');
    expect(msg['likes'], 1);
    db2.close();
  });

  test('a reopen reads thread rows, not every message', () {
    // The property that keeps the wapp opening in constant time as history
    // grows: the list needs a title, a preview, an unread count and a
    // timestamp, all of which live on the thread row.
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    for (var c = 0; c < 5; c++) {
      store.upsert({'id': 'c$c', 'title': 'chat $c', 'subtitle': 'last line'});
      for (var i = 0; i < 40; i++) {
        store.addMessage({'id': 'c$c', 'dir': 'in', 'text': 'm$i'});
      }
    }
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final fresh = ConversationStore()..loaded = false;
    db2.loadInto('conversations', fresh);
    expect(fresh.items, hasLength(5), reason: 'every thread is listed');
    expect(fresh.items['c0']!.title, 'chat 0');
    expect(fresh.items['c0']!.subtitle, 'last line',
        reason: 'the list row is complete without reading a single message');
    for (final it in fresh.items.values) {
      expect(it.messages, isEmpty, reason: 'no tail is read until asked for');
    }

    // …and asking for one reads that one, in order, and nothing else.
    fresh
      ..db = db2
      ..loaded = true;
    expect(fresh.messagesOf('c3').map((m) => m['text']).take(3).toList(),
        ['m0', 'm1', 'm2']);
    expect(fresh.items['c4']!.messages, isEmpty,
        reason: 'opening one conversation does not read its neighbours');
    expect(db2.countMessages('conversations'), 200);
    db2.close();
  });

  test('the list preview survives a reopen without reading messages', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'c', 'title': 'chat'});
    store.addMessage({'id': 'c', 'dir': 'in', 'from': 'X3ARK', 'text': 'hello'});
    // A like is not something anybody said.
    store.addMessage({'id': 'c', 'dir': 'in', 'from': 'X1RD89',
      'text': 'abc12345:like'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final fresh = ConversationStore()..loaded = false;
    db2.loadInto('conversations', fresh);
    expect(fresh.items['c']!.lastLine, 'X3ARK: hello');
    expect(fresh.items['c']!.messages, isEmpty,
        reason: 'the preview came off the thread row, not the messages');
    db2.close();
  });

  test('a conversation written before previews were stored gets one', () {
    // The upgrade case: rows exist, none of them carries lastLine, and the
    // messages that used to supply the preview are no longer read at load.
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': 'c', 'title': 'chat'});
    store.addMessage({'id': 'c', 'dir': 'in', 'from': 'X3ARK', 'text': 'older'});
    db.close();

    // Strip it the way an older build would have left the row.
    final raw = sqlite3.open(dbPath);
    raw.execute(
        "UPDATE threads SET meta = json_remove(meta, '\$.lastLine') "
        "WHERE field='conversations'");
    raw.dispose();

    final db2 = ConversationDb.open(dbPath);
    final fresh = ConversationStore()..loaded = false;
    db2.loadInto('conversations', fresh);
    expect(fresh.items['c']!.lastLine, 'X3ARK: older');
    expect(fresh.items['c']!.messages, isEmpty);
    db2.close();

    // …and it was written back, so the next open asks nothing.
    final db3 = ConversationDb.open(dbPath);
    final again = ConversationStore()..loaded = false;
    db3.loadInto('conversations', again);
    expect(again.items['c']!.lastLine, 'X3ARK: older');
    db3.close();
  });

  test('the per-thread cap is enforced on disk', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    for (var i = 0; i < kConvoMaxMessages + 25; i++) {
      store.addMessage({'id': 'big', 'dir': 'in', 'text': 'm$i'});
    }
    db.close();

    final db2 = ConversationDb.open(dbPath);
    final restored = reopen(db2);
    final msgs = restored.messagesOf('big');
    expect(msgs, hasLength(kConvoMaxMessages));
    expect(msgs.last['text'], 'm${kConvoMaxMessages + 24}');
    db2.close();
  });
  // ── Losing history to a block, and to a wipe ───────────────────────────
  //
  // Message tails are read lazily, so a thread nobody has opened holds NO
  // messages in memory. Blocking used to clear every thread on disk and write
  // the in-memory copy back — which for those threads was nothing at all. One
  // block emptied every room on the device, and the Local room went with it.

  test("blocking a sender leaves an unopened thread's history alone", () {
    final db = ConversationDb.open(dbPath);
    var store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.upsert({'id': '#NEWS', 'title': 'News'});
    store.addMessage(
        {'id': '#LOCAL', 'dir': 'in', 'from': 'X3WWAJ', 'text': 'hello here'});
    store.addMessage(
        {'id': '#NEWS', 'dir': 'in', 'from': 'X1BAD', 'text': 'noise'});
    db.close();

    // Reopen and open NOTHING: both tails are unhydrated, which is the state
    // an app is in the moment it starts.
    final db2 = ConversationDb.open(dbPath);
    store = reopen(db2);
    store.remove({'from': 'X1BAD'});
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    final after = reopen(db3);
    expect(after.messagesOf('#LOCAL').map((m) => m['text']), ['hello here'],
        reason: 'blocking somebody else must not empty this room');
    db3.close();
  });

  test('a blocked sender is hidden, not deleted, and comes back', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.addMessage(
        {'id': '#LOCAL', 'dir': 'in', 'from': 'X1BAD', 'text': 'rude'});
    store.addMessage(
        {'id': '#LOCAL', 'dir': 'in', 'from': 'X3WWAJ', 'text': 'fine'});

    store.setBlocked(['X1BAD']);
    expect(store.messagesOf('#LOCAL').map((m) => m['text']), ['fine']);

    store.setBlocked(const []);
    expect(store.messagesOf('#LOCAL').map((m) => m['text']), ['rude', 'fine'],
        reason: 'the rows were never deleted, so unblocking gives them back');
    db.close();
  });

  test('hiding one message takes one row, not the thread', () {
    final db = ConversationDb.open(dbPath);
    var store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.addMessage(
        {'id': '#LOCAL', 'dir': 'in', 'key': 'k1', 'text': 'keep me'});
    store.addMessage(
        {'id': '#LOCAL', 'dir': 'in', 'key': 'k2', 'text': 'hide me'});
    db.close();

    final db2 = ConversationDb.open(dbPath);
    store = reopen(db2);
    store.messagesOf('#LOCAL'); // hydrate, as opening the room does
    store.remove({'id': '#LOCAL', 'key': 'k2'});
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    expect(reopen(db3).messagesOf('#LOCAL').map((m) => m['text']), ['keep me']);
    db3.close();
  });

  test('a clear with no id is refused and the field survives', () {
    final db = ConversationDb.open(dbPath);
    var store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.addMessage({'id': '#LOCAL', 'dir': 'in', 'text': 'still here'});

    // The shape a wapp sent from its module_init for two releases.
    store.clear(null);
    store.clear('');
    db.close();

    final db2 = ConversationDb.open(dbPath);
    expect(reopen(db2).messagesOf('#LOCAL').map((m) => m['text']),
        ['still here'],
        reason: 'a wapp clears one conversation at a time');
    db2.close();
  });

  // ── Refilling a room from the core archive ─────────────────────────────

  test('a backfilled row does not duplicate a live one', () {
    final db = ConversationDb.open(dbPath);
    var store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.addMessage({
      'id': '#LOCAL', 'dir': 'in', 'from': 'X3WWAJ',
      'mid': 'ab12cd', 'key': '4149', 'text': 'said once',
    });
    db.close();

    // Reopen with nothing hydrated — the state a refill runs in — and replay.
    final db2 = ConversationDb.open(dbPath);
    store = reopen(db2);
    store.addMessage({
      'id': '#LOCAL', 'dir': 'in', 'from': 'X3WWAJ',
      'mid': 'ab12cd', 'key': '4149', 'text': 'said once', 'backfill': true,
    });
    expect(store.messagesOf('#LOCAL').length, 1);
    db2.close();

    final db3 = ConversationDb.open(dbPath);
    expect(reopen(db3).messagesOf('#LOCAL').length, 1);
    db3.close();
  });

  test('a backfilled row is stored but does not badge or bump', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.upsert({'id': '#NEWS', 'title': 'News'});
    final before = store.items['#LOCAL']!.activityTs;
    final orderBefore = [...store.order];

    store.addMessage({
      'id': '#LOCAL', 'dir': 'in', 'from': 'X3WWAJ',
      'mid': 'ffee11', 'text': 'from the archive', 'backfill': true,
    });

    expect(store.items['#LOCAL']!.unread, 0,
        reason: 'sixty replayed rows must not badge the room sixty times');
    expect(store.items['#LOCAL']!.activityTs, before,
        reason: 'a replay is not activity');
    expect(store.order, orderBefore, reason: 'and it does not float the rail');
    expect(store.messagesOf('#LOCAL').length, 1, reason: 'but it IS stored');
    db.close();
  });

  test('a store with no database says so once', () {
    // A field name of its own: the log is process-wide and other tests in this
    // file also build memory-only stores.
    final store = ConversationStore()
      ..owner = 'chat'
      ..dbField = 'silent_field_probe';
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.addMessage({'id': '#LOCAL', 'dir': 'in', 'text': 'lost'});
    store.addMessage({'id': '#LOCAL', 'dir': 'in', 'text': 'also lost'});
    expect(store.memoryOnly, isTrue);
    final said = LogService.instance
        .tail(200)
        .where((l) =>
            l.contains('MEMORY-ONLY') && l.contains('silent_field_probe'))
        .length;
    expect(said, 1, reason: 'said once per store, not once per message');
  });

  test('a wapp-owned store is a render cache and says nothing about it', () {
    final store = ConversationStore()
      ..owner = 'chat'
      ..dbField = 'wapp_owned_probe'
      ..wappOwned = true;
    store.upsert({'id': '#LOCAL', 'title': 'Local chat', 'unread': 2});
    store.addMessage(
        {'id': '#LOCAL', 'dir': 'in', 'text': 'painted by the wapp', 'backfill': true});
    expect(store.memoryOnly, isTrue);
    expect(store.messagesOf('#LOCAL').map((m) => m['text']), ['painted by the wapp']);
    // The wapp said 2 and a backfill bubble counts nothing: the wapp's number stands.
    expect(store.items['#LOCAL']!.unread, 2);
    final said = LogService.instance
        .tail(200)
        .where((l) => l.contains('MEMORY-ONLY') && l.contains('wapp_owned_probe'))
        .length;
    expect(said, 0, reason: 'memory-only is the design here, not a failure');
  });

  // ── Open survives a transient lock ──────────────────────────────────────
  //
  // The empty box: at the page->headless handoff the DB open met a lock and
  // threw, and the store fell to memory-only for good — a message arriving
  // then was written nowhere while its notification fired. openProfileDb waits
  // a lock out now, and ConversationDb.open retries a transient SqliteException
  // rather than giving up. A normal open must be unaffected.

  test('open on a fresh path returns a usable, writable database', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.addMessage({'id': '#LOCAL', 'dir': 'in', 'text': 'after a clean open'});
    db.close();
    final db2 = ConversationDb.open(dbPath);
    expect(reopen(db2).messagesOf('#LOCAL').map((m) => m['text']),
        ['after a clean open']);
    db2.close();
  });

  test('reopening a database another handle already holds does not throw', () {
    // Two live handles on one file — the shape of the page/headless overlap.
    // With busy_timeout set this must not throw SQLITE_BUSY on the second open.
    final a = ConversationDb.open(dbPath);
    attached(a).upsert({'id': '#LOCAL', 'title': 'Local chat'});
    final b = ConversationDb.open(dbPath); // would throw pre-fix
    expect(b.fields(), contains('conversations'));
    b.close();
    a.close();
  });

  // Blocking a sender is total: no bubble, no preview, no badge.

  test('a blocked sender leaves no preview and no badge', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.addMessage(
        {'id': '#LOCAL', 'dir': 'in', 'from': 'X1BAD', 'text': 'noise'});
    expect(store.items['#LOCAL']!.unread, 1);
    expect(store.items['#LOCAL']!.lastLine, contains('noise'));

    store.setBlocked(['X1BAD']);
    expect(store.messagesOf('#LOCAL'), isEmpty);
    expect(store.items['#LOCAL']!.unread, 0,
        reason: 'no badge on a room with nothing visible');
    expect(store.items['#LOCAL']!.lastLine, isEmpty);

    store.setBlocked(const []);
    expect(store.items['#LOCAL']!.lastLine, contains('noise'),
        reason: 'unblocking brings the preview back');
    db.close();
  });

  test('a new message from a blocked sender never badges', () {
    final db = ConversationDb.open(dbPath);
    final store = attached(db);
    store.upsert({'id': '#LOCAL', 'title': 'Local chat'});
    store.setBlocked(['X1BAD']);
    store.addMessage(
        {'id': '#LOCAL', 'dir': 'in', 'from': 'X1BAD', 'text': 'still noise'});
    expect(store.items['#LOCAL']!.unread, 0);
    expect(store.items['#LOCAL']!.lastLine, isEmpty);
    expect(store.messagesOf('#LOCAL'), isEmpty);
    db.close();
  });

}
