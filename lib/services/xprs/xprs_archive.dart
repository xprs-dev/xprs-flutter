/*
 * xprs_archive — the spool of what this station has heard.
 *
 * docs/XPRS.md section 31.3 leaves retention to the station, section 24 names
 * the role (`serve:archive` "keeps a spool of what it has heard, and re-airs
 * it on cmd:history"), and until now no station kept one: the monitor's ring
 * forgets after 200 packets and a restart forgets everything. This is the
 * missing disk. Bounded — the caps are ours to pick and to change — and on by
 * default, because a spool nobody keeps is a network nobody can catch up on.
 *
 * Duplicates collapse on the derived identifier (section 25.2.1), so hearing
 * the same packet from three digipeaters costs one row. The wire is stored
 * exactly as heard — a replay re-airs original packets, unchanged — except
 * that a copy with fewer `via:` hops replaces one with more, because the
 * zero-hop copy is the closest thing to what the author transmitted.
 *
 * The hot path writes nothing: admit() appends to RAM and returns. A 20 s
 * timer flushes in one transaction, verifies signatures off the hot path,
 * and prunes in bounded batches (the ActivityArchive discipline). Nothing
 * here blocks the UI isolate for longer than one small indexed transaction.
 *
 * Also holds the `t:mailbox` declarations (section 13.12) that decide which
 * Reticulum-borne traffic may enter at all — see XprsIngest for the rule.
 */
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../profile/profile_db.dart';
import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../receive/core_state.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// Packet types that are never spooled.
///
/// `ping`/`pong` — section 36.1: a stale one answers a question nobody is
/// still asking. `receipt`/`result` — control traffic whose whole value is
/// consumed the moment it is heard; store-and-forward never carries them and
/// a history page re-airing day-old receipts wastes the page. `command` IS
/// kept: section 36.1 calls a command to a sleeping station mail.
const Set<String> kXprsNeverArchived = {'ping', 'pong', 'receipt', 'result'};

class _Pending {
  _Pending(this.p, this.bearer, this.rssi, this.own, this.nowMs);
  final XprsPacket p;
  final String bearer;
  final int rssi;
  final bool own;
  final int nowMs;
}

class XprsArchive {
  XprsArchive._();
  static final XprsArchive instance = XprsArchive._();

  Database? _db;
  bool get ready => _db != null;

  /// The stored packet whose §5 identifier is [id], or null when the spool
  /// holds none. This is how the core answers a read receipt for a message too
  /// old to be in [XprsReceipt]'s live pocket: the packet is resolved from the
  /// core's own persistent spool -- the sender and addressing composeRead needs
  /// -- rather than a wapp handing those fields across the door. Cheap: `id` is
  /// the packets table's primary key.
  XprsPacket? packetById(String id) {
    final key = id.trim().toLowerCase();
    if (key.isEmpty) return null;
    final db = _db;
    if (db == null) return null;
    try {
      final rows =
          db.select('SELECT wire FROM packets WHERE id = ? LIMIT 1', [key]);
      if (rows.isEmpty) return null;
      return XprsPacket.parse(rows.first.columnAt(0) as String);
    } catch (_) {
      return null;
    }
  }

  /// Caps. Prefs-backed by the owner (MeshService reads them at init and on
  /// change); the defaults are a judgement, not a specification (§31.3).
  int maxBytes = 500 * 1024 * 1024;
  int maxAgeDays = 365;

  /// The signer's x-only key for a callsign, or null when not held. Injected
  /// (RnsService.pubkeyForCallsign in production) so tests need no node.
  Uint8List? Function(String baseCallsign)? keyResolver;

  /// Callsigns whose packets the byte cap never evicts — the xprs wapp's
  /// favourites can be wired in later without a schema change. Null = none.
  Set<String> Function()? protectedCallsigns;

  /// Counters for /api and for honest logs.
  int admitted = 0, dropped = 0, forged = 0;

  /// Told, at flush, what each packet's signature turned out to be — including
  /// the forged ones this drops. Set by the owner so the air view can badge a
  /// station without doing the curve work a second time.
  void Function(String callsign, XprsSigState state)? onVerdict;

  final List<_Pending> _pending = [];
  static const int _pendingMax = 512;
  static const int _flushEarlyAt = 64;
  Timer? _flushTimer;
  bool _prunedThisSession = false;
  int _flushesSinceCap = 0;

  /// Open (and migrate) the spool. Safe to call again on profile switch.
  void init(String path) {
    close();
    try {
      Directory(File(path).parent.path).createSync(recursive: true);
      final db = openProfileDb(path);
      // INCREMENTAL auto-vacuum must precede table creation, or deletes never
      // shrink the file and the byte cap caps nothing.
      db.execute('PRAGMA auto_vacuum = INCREMENTAL;');
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA synchronous = NORMAL;');
      db.execute('''
        CREATE TABLE IF NOT EXISTS packets(
          id     TEXT PRIMARY KEY,
          ts     INTEGER NOT NULL,
          pts    INTEGER NOT NULL,
          type   TEXT NOT NULL,
          fromc  TEXT NOT NULL,
          toc    TEXT NOT NULL DEFAULT '',
          bearer TEXT NOT NULL,
          rssi   INTEGER NOT NULL DEFAULT 0,
          mine   INTEGER NOT NULL DEFAULT 0,
          own    INTEGER NOT NULL DEFAULT 0,
          sig    INTEGER NOT NULL DEFAULT 3,
          viac   INTEGER NOT NULL DEFAULT 0,
          heard  INTEGER NOT NULL DEFAULT 1,
          last   INTEGER NOT NULL,
          wire   TEXT NOT NULL
        )''');
      db.execute('CREATE INDEX IF NOT EXISTS idx_pk_pts ON packets(pts)');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pk_from ON packets(fromc, pts)');
      db.execute('CREATE INDEX IF NOT EXISTS idx_pk_to ON packets(toc, pts)');
      db.execute('''
        CREATE TABLE IF NOT EXISTS mailbox_decl(
          id    TEXT PRIMARY KEY,
          fromc TEXT NOT NULL,
          pos   INTEGER NOT NULL DEFAULT 0,
          since INTEGER,
          until INTEGER,
          ts    INTEGER NOT NULL,
          wire  TEXT NOT NULL
        )''');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_decl_from ON mailbox_decl(fromc)');
      _db = db;
      _prunedThisSession = false;
      _flushTimer?.cancel();
      _flushTimer =
          Timer.periodic(const Duration(seconds: 20), (_) => flush());
    } catch (e) {
      _db = null;
      // A broken disk degrades to no archive, never to a crash.
      LogService.instance.add('XPRS archive: open failed: $e');
    }
  }

  void close() {
    flush();
    _flushTimer?.cancel();
    _flushTimer = null;
    _db?.dispose();
    _db = null;
  }

  /// The person, with any device suffix removed: `X1ABCD-1` -> `X1ABCD`
  /// (spec section 3.1). One definition, shared, so the person/device
  /// split cannot drift between the archive, the ingest and the server.
  static String _base(String c) => NostrCrypto.bareCallsign(c);

  /// Record a heard packet. O(1): RAM append, nothing else — this sits on the
  /// radio receive path. [own] marks our own publication at transmit time.
  /// Test seam: every packet this archive accepted, in order. The retention
  /// policy lives in XprsIngest and the only honest way to test it is to watch
  /// what actually arrives here.
  void Function(XprsPacket p)? debugOnAdmit;

  void admit(
    XprsPacket p, {
    required String bearer,
    int rssi = 0,
    bool own = false,
    int? nowMs,
  }) {
    debugOnAdmit?.call(p);
    if (_db == null) return;
    if (kXprsNeverArchived.contains(p.type)) return;
    if ((p['f'] ?? '').trim().isEmpty) return;
    if (_pending.length >= _pendingMax) {
      _pending.removeAt(0);
      dropped++;
    }
    _pending.add(_Pending(
        p, bearer, rssi, own, nowMs ?? DateTime.now().millisecondsSinceEpoch));
    if (_pending.length >= _flushEarlyAt) flush();
  }

  /// Write the pending batch, verify signatures, prune. Public so tests and
  /// close() can force it; otherwise the 20 s timer calls it.
  /// A row that is now ACTUALLY in the table: the sender's base callsign and
  /// the packet's `ts:`.
  ///
  /// Fired here rather than at [admit], which only queues. The catch-up sweep
  /// advances a watermark on this, and firing it at admit time advanced it past
  /// packets the flush then dropped — a forged signature is discarded a few
  /// lines below — so the sweep believed it held history it had never stored,
  /// and stopped asking for it.
  void Function(String fromBase, int? tsMs)? onStored;

  void flush({int? nowMs}) {
    final db = _db;
    if (db == null || _pending.isEmpty) {
      if (db != null) _prune(db, nowMs: nowMs);
      return;
    }
    final batch = List.of(_pending);
    // Collected during the write and fired after the transaction, so a hook
    // that throws cannot leave the batch half-committed.
    final stored = <MapEntry<String, int?>>[];
    /// Senders whose identity rows need collapsing after this batch.
    final identities = <String>{};
    _pending.clear();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      db.execute('BEGIN');
      final ins = db.prepare('''
        INSERT INTO packets(id,ts,pts,type,fromc,toc,bearer,rssi,mine,own,
                            sig,viac,heard,last,wire)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,1,?,?)
        ON CONFLICT(id) DO UPDATE SET
          heard = heard + 1,
          last  = excluded.last,
          rssi  = excluded.rssi,
          mine  = MAX(mine, excluded.mine),
          own   = MAX(own, excluded.own),
          wire  = CASE WHEN excluded.viac < viac
                       THEN excluded.wire ELSE wire END,
          viac  = MIN(viac, excluded.viac)''');
      try {
        for (final e in batch) {
          final p = e.p;
          // Signature state, off the hot path. A forged packet is somebody
          // else's words under a callsign, and a spool that replays it later
          // repeats the lie — dropped, same policy as the courier.
          var sig = XprsSigState.unsigned;
          if (p.has('sig')) {
            sig = xprsVerify(p, keyResolver?.call(_base(p['f'] ?? '')));
          }
          // Report before acting on it: a forged packet is dropped from the
          // spool, and if the verdict went with it nothing would ever be able
          // to say that a callsign had been used to sign something it could
          // not have signed.
          try {
            onVerdict?.call(_base(p['f'] ?? ''), sig);
          } catch (_) {
            // A view that throws must not cost the spool its flush.
          }
          if (sig == XprsSigState.forged) {
            forged++;
            continue;
          }
          final fromc = _base(p['f'] ?? '');
          final toc = _base(p['d'] ?? '');
          stored.add(MapEntry(fromc, xprsParseTs(p['ts'])));
          ins.execute([
            xprsIdentifier(p),
            e.nowMs,
            xprsParseTs(p['ts']) ?? e.nowMs,
            p.type,
            fromc,
            (p['d'] ?? '').trim().isEmpty ? '' : toc,
            e.bearer,
            e.rssi,
            (!e.own && toc.isNotEmpty && toc == _selfBase) ? 1 : 0,
            e.own ? 1 : 0,
            sig.index,
            xprsVia(p).length,
            e.nowMs,
            p.encode(),
          ]);
          admitted++;
          if (p.type == 'identity') identities.add(fromc);
        }
      } finally {
        ins.dispose();
      }
      for (final c in identities) {
        _collapseIdentities(db, c);
      }
      db.execute('COMMIT');
    } catch (e) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      LogService.instance.add('XPRS archive: flush failed: $e');
    }
    _prune(db, nowMs: now);
    // The archive's counters moved, and its dashboard is somebody's screen.
    // Once per flush rather than once per row: a backlog drain writes hundreds
    // in one transaction, and the reader re-reads the whole status anyway.
    if (stored.isNotEmpty) CoreState.instance.changed(CoreState.archive);

    // Only now, and only for rows the transaction actually wrote.
    final notify = onStored;
    if (notify != null) {
      for (final e in stored) {
        try {
          notify(e.key, e.value);
        } catch (_) {
          // A watermark that throws must not cost the spool its flush.
        }
      }
    }
  }

  /// Keep only the NEWEST identity announcement of each shape, per callsign.
  ///
  /// §9.3.2: "An identity announcement carries any subset of these fields, and
  /// a receiver keeps, for each field, **the value from the newest verifiable
  /// announcement that carried it**." A station re-announces every thirty
  /// minutes (§18.1) and each announcement carries a fresh `ts:`, so each is a
  /// different §5 identifier and a different row — 48 rows a day per station if
  /// nothing collapses them. That growth is why identity was lumped in with
  /// chatter and dropped wholesale, which threw away the binding to avoid the
  /// duplication.
  ///
  /// Collapsing by SHAPE rather than by callsign is what §9.3.2 forces: the
  /// same section splits the announcement in two because the key binding and
  /// the decoration do not fit in one packet, and they are re-sent on different
  /// cadences — "the key binding is small and must be repeated often ... the
  /// decoration is larger and changes once a year". Keeping only the newest per
  /// callsign would let a key-only announcement evict the avatar and the
  /// description. So: newest key-bearing row, and newest decoration row. Two
  /// per station, for ever.
  static void _collapseIdentities(Database db, String fromc) {
    if (fromc.isEmpty) return;
    for (final bearing in [1, 0]) {
      final rows = db.select(
          "SELECT id, wire FROM packets WHERE type = 'identity' AND fromc = ? "
          'ORDER BY pts DESC, ts DESC',
          [fromc]);
      final same = <String>[];
      for (final r in rows) {
        final w = r['wire'] as String? ?? '';
        // `k:` is the key binding; anything else is decoration (§9.3.2).
        final hasKey = w.contains(' k:npub') ? 1 : 0;
        if (hasKey == bearing) same.add(r['id'] as String);
      }
      // The first is the newest — ordered by the packet's own ts:, not by when
      // we heard it, so a re-aired old announcement cannot displace a newer one.
      for (final id in same.skip(1)) {
        db.execute('DELETE FROM packets WHERE id = ?', [id]);
      }
    }
  }

  /// Have [a] and [b] exchanged a DIRECT message before, in either direction?
  ///
  /// Section 13.7.1 gates the automatic receipt on exactly this: "a direct
  /// message has already passed between the two callsigns, in either
  /// direction". Not politeness — an acknowledgement is airtime on a shared
  /// channel, and answering a stranger also confirms to everyone listening that
  /// this callsign is here and awake. Two stations that have already exchanged
  /// have both costs priced in; a stranger has not agreed to either.
  ///
  /// Indexed on `(fromc, toc)` via the existing type/time index; the limit makes
  /// it a lookup rather than a scan.
  bool hasExchanged(String a, String b) {
    final db = _db;
    if (db == null) return false;
    final x = _base(a), y = _base(b);
    if (x.isEmpty || y.isEmpty) return false;
    return db.select(
        "SELECT 1 FROM packets WHERE type = 'message' AND "
        '((fromc = ? AND toc = ?) OR (fromc = ? AND toc = ?)) LIMIT 1',
        [x, y, y, x]).isNotEmpty;
  }

  /// Our base callsign, set by the owner at init/profile switch so `mine` can
  /// be computed at flush time without asking a service from inside sqlite.
  String selfCallsign = '';
  String get _selfBase => _base(selfCallsign);

  void _prune(Database db, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // Age, once per session. Our own side of the conversation is exempt, the
    // same way the byte cap below already exempts it: this station IS its own
    // archive, and a log that deletes what you said and what was said to you
    // is not one. Everyone else's traffic still ages out — that is the
    // indexer's job and where the storage actually goes.
    //
    // Own `observation` beacons are the exception to the exemption: one every
    // 300 s is ~100k rows a year, and a beacon is telemetry rather than
    // something anybody said. They age out with the rest.
    //
    // Expired declarations go in the same breath.
    if (!_prunedThisSession) {
      _prunedThisSession = true;
      try {
        // `identity` never ages out. It is the key binding, and a station
        // heard once a year ago is exactly the one whose signature this
        // station cannot check without it (§18.1). Bounded by construction —
        // `_collapseIdentities` keeps two rows per callsign, ever — so ten
        // thousand distinct stations is about 3.6 MB against a 500 MB spool.
        db.execute(
            'DELETE FROM packets WHERE pts < ? '
            "AND (own = 0 OR type = 'observation') AND mine = 0 "
            "AND type != 'identity'",
            [now - maxAgeDays * 86400000]);
        db.execute(
            'DELETE FROM mailbox_decl WHERE until IS NOT NULL AND until < ?',
            [now]);
      } catch (e) {
        LogService.instance.add('XPRS archive: age prune failed: $e');
      }
    }
    // Byte cap, every 20th flush (~7 min of dense traffic). One bounded
    // batch that converges over successive flushes rather than looping.
    if (++_flushesSinceCap < 20) return;
    _flushesSinceCap = 0;
    try {
      final bytes = _dataBytes(db);
      if (bytes <= maxBytes) return;
      final prot = protectedCallsigns?.call() ?? const <String>{};
      final protSql = prot.isEmpty
          ? ''
          : ' AND fromc NOT IN (${List.filled(prot.length, '?').join(',')})';
      final protList = prot.toList();
      // Identity is exempt here too, and for a sharper reason than age: the
      // cap evicts OLDEST FIRST, and a key binding heard long ago is precisely
      // the row most likely to be oldest and least likely to be re-heard soon.
      // Under storage pressure this would have thrown away exactly the keys
      // that cannot be re-derived from anything else on disk.
      final rows = db
          .select('SELECT COUNT(*) c FROM packets WHERE own=0 AND mine=0'
              " AND type != 'identity'$protSql", protList)
          .first['c'] as int;
      if (rows == 0) return;
      final avg = (bytes / rows).clamp(64, 1 << 20);
      var drop = ((bytes - maxBytes) / avg).ceil() + 500;
      if (drop > 20000) drop = 20000;
      db.execute(
          'DELETE FROM packets WHERE id IN '
          "(SELECT id FROM packets WHERE own=0 AND mine=0 AND type != 'identity'"
          '$protSql ORDER BY pts ASC LIMIT ?)',
          [...protList, drop]);
      db.execute('PRAGMA incremental_vacuum;');
    } catch (e) {
      LogService.instance.add('XPRS archive: cap prune failed: $e');
    }
  }

  /// Drop everything this station holds about one closed group.
  ///
  /// Forgetting a group is not deleting it: the group goes on existing
  /// wherever anybody else holds its record, and 26.6 says as much about the
  /// key. This is only the local copy — and it has to include the archive,
  /// because the roster is replayed from these rows at startup and a group
  /// forgotten in memory alone comes straight back on the next launch.
  ///
  /// Rides `idx_pk_to(toc, pts)`, so it is a range delete rather than a scan.
  int forgetGroup(String group) {
    final db = _db;
    if (db == null) return 0;
    final g = _base(group.trim().toUpperCase());
    if (g.isEmpty) return 0;
    flush(); // anything still queued would be written back after the delete
    db.execute('DELETE FROM packets WHERE toc = ? OR fromc = ?', [g, g]);
    return db.updatedRows;
  }

  int _dataBytes(Database db) {
    try {
      final pc =
          (db.select('PRAGMA page_count').first.values.first as num).toInt();
      final ps =
          (db.select('PRAGMA page_size').first.values.first as num).toInt();
      return pc * ps;
    } catch (_) {
      return 0;
    }
  }

  // ── mailbox declarations (section 13.12) ─────────────────────────────────

  /// Act on a `t:mailbox` packet. Only a VERIFIED one is acted on — §13.12:
  /// "a receiver that cannot verify one must not act on it"; forging one is
  /// how an attacker collects somebody's mail. Returns true when the
  /// declaration (or cancellation) named us and was recorded.
  bool recordMailboxDecl(XprsPacket p, {int? nowMs}) {
    final db = _db;
    if (db == null || p.type != 'mailbox') return false;
    final fromc = _base(p['f'] ?? '');
    if (fromc.isEmpty) return false;
    final state = xprsVerify(p, keyResolver?.call(fromc));
    if (state != XprsSigState.verified) return false;

    if ((p['remove'] ?? '') == 'mailbox') {
      final r = (p['r'] ?? '').trim();
      if (r.isEmpty) return false;
      db.execute(
          'DELETE FROM mailbox_decl WHERE id=? AND fromc=?', [r, fromc]);
      return true;
    }
    final hold = (p['hold'] ?? '')
        .split(',')
        .map(_base)
        .where((c) => c.isNotEmpty)
        .toList();
    final pos = hold.indexOf(_selfBase);
    // A declaration NOT naming us is still recorded (pos -1): section 36.8.1
    // routes held mail by "who holds for X", and an archiver that only
    // remembered its own appointments could never answer it. The return
    // value keeps its old meaning -- "named us" -- because ingest admission
    // rides on it.
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    db.execute(
        'INSERT OR REPLACE INTO mailbox_decl(id,fromc,pos,since,until,ts,wire) '
        'VALUES(?,?,?,?,?,?,?)',
        [
          xprsIdentifier(p),
          fromc,
          pos,
          xprsParseTs(p['since']),
          xprsParseTs(p['until']),
          xprsParseTs(p['ts']) ?? now,
          p.encode(),
        ]);
    return pos >= 0;
  }

  /// L1 of the gossip layers (36.9.4): who [baseCallsign] declared as its
  /// mailboxes, in the declaration's own order of preference (13.12). The
  /// narrowest active window wins (13.12.1); windowed beats open-ended.
  List<String> holdersFor(String baseCallsign, {int? nowMs}) {
    final db = _db;
    if (db == null) return const [];
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final rows = db.select(
        'SELECT wire FROM mailbox_decl WHERE fromc=? '
        'AND (since IS NULL OR since<=?) AND (until IS NULL OR until>=?) '
        'ORDER BY (until IS NULL) ASC, ts DESC LIMIT 1',
        [_base(baseCallsign), now, now]);
    if (rows.isEmpty) return const [];
    final p = XprsPacket.parse(rows.first['wire'] as String);
    if (p == null) return const [];
    return (p['hold'] ?? '')
        .split(',')
        .map(_base)
        .where((c) => c.isNotEmpty)
        .toList();
  }

  /// Whether [baseCallsign] currently has an active declaration naming us —
  /// the admission ticket for its Reticulum-borne traffic (§36.3).
  bool hasActiveDecl(String baseCallsign, {int? nowMs}) {
    final db = _db;
    if (db == null) return false;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // pos>=0: only declarations that NAME US are an admission ticket --
    // the table now also holds everyone else's declarations for routing
    // (holdersFor above), and those must not open the door.
    return db.select(
        'SELECT 1 FROM mailbox_decl WHERE fromc=? AND pos>=0 '
        'AND (since IS NULL OR since<=?) AND (until IS NULL OR until>=?) '
        'LIMIT 1',
        [_base(baseCallsign), now, now]).isNotEmpty;
  }

  int get declCount {
    final db = _db;
    if (db == null) return 0;
    return db.select('SELECT COUNT(*) c FROM mailbox_decl').first['c'] as int;
  }

  // ── reading the spool ─────────────────────────────────────────────────────

  /// Archived packets, newest first by the packet's own timestamp — the order
  /// a `cmd:history` replay airs them in (§25.2.1). [only] matches sender or
  /// addressee. One row past [limit] is never returned; the responder asks
  /// for limit+1 itself to learn whether more exists.
  /// What counts as conversation: the default a radio replay serves when the
  /// asker named no `kind:`. A person catching up wants what was SAID, and a
  /// twelve-record page spent on presence beacons reaches none of it.
  static const Set<String> kXprsTalk = {
    'message', 'reaction', 'blog', 'event', 'warning', 'sos', 'info', 'status',
  };

/// How many records of [types] the archive holds, without building any.
  ///
  /// [query] materialises a Dart Map per row INCLUDING the wire, so asking it
  /// for a count means allocating the page to throw it away. A caller that
  /// wanted `.length` of a thousand-row page ran that once a minute on the
  /// main isolate, forever, on the device with the biggest archive -- which is
  /// megabytes of garbage a minute to learn one integer, and is what an
  /// out-of-memory on a busy archiver looks like from the inside
  /// (docs/performance.md 4.2: the drains are cheap calls in hot loops, not
  /// expensive algorithms).
  int countOf({List<String>? types}) {
    final db = _db;
    if (db == null) return 0;
    if (types == null || types.isEmpty) {
      return db.select('SELECT COUNT(*) c FROM packets').first['c'] as int;
    }
    final marks = List.filled(types.length, '?').join(',');
    return db.select(
        'SELECT COUNT(*) c FROM packets WHERE type IN ($marks)',
        types).first['c'] as int;
  }

    List<Map<String, dynamic>> query({
    int? sinceMs,
    int? untilMs,
    String? only,
    List<String>? types,
    List<String>? to,
    int limit = 200,
    String? rankFor,
  }) {
    final db = _db;
    if (db == null) return const [];
    final where = StringBuffer('1=1');
    final args = <Object?>[];
    // Ask for the rows you will render, not a page you will sieve.
    //
    // The chat rooms asked for "the newest 48 messages" and filtered on their
    // side, which is a lottery against whatever else the station is doing.
    // Measured on the C61 mid store-and-forward: the newest 48 message rows
    // were ALL this station's own custody re-airs to one absent peer — 343 of
    // the newest 371 spanning five minutes — so of 400 rows fetched, the
    // rooms could render zero, and a group post sat unrendered in the archive
    // for an hour. A destination list makes the window mean something: the
    // empty string is the undirected traffic a scope room reads, a group
    // callsign is that group's room, and idx_pk_to(toc, pts) serves both.
    if (to != null && to.isNotEmpty) {
      where.write(' AND toc IN (${List.filled(to.length, '?').join(',')})');
      args.addAll(to.map((d) => d.trim().isEmpty ? '' : _base(d)));
    }
    // A caller that only reads conversations (message + reaction) must not
    // have its window eaten by the observation chatter, which outnumbers
    // everything else on a busy bench.
    if (types != null && types.isNotEmpty) {
      where.write(' AND type IN (${List.filled(types.length, '?').join(',')})');
      args.addAll(types);
    }
    if (sinceMs != null) {
      where.write(' AND pts >= ?');
      args.add(sinceMs);
    }
    if (untilMs != null) {
      where.write(' AND pts < ?');
      args.add(untilMs);
    }
    if (only != null && only.trim().isNotEmpty) {
      final c = _base(only);
      // An observation ABOUT the named callsign has that callsign in its
      // `hears:` list and someone else in `f:` — matching sender/addressee
      // alone made `only:X kind:observation` (36.9.4's bulk-gossip ask, "the
      // signed sightings this station holds about X") return nothing, ever.
      // instr() over the wire is a scan, but one confined to observation
      // rows already narrowed by the type filter and the time window; a
      // substring hit beyond the hears: list adds at worst an extra record
      // to a page, and a sighting informs routing, never compels it
      // (10.6.3).
      where.write(" AND (fromc=? OR toc=? OR "
          "(type='observation' AND instr(wire, ?) > 0))");
      args
        ..add(c)
        ..add(c)
        ..add(c);
    }
    // Relevance bands, newest-first WITHIN each band (25.2.1 keeps newest
    // first; this only decides which newest).
    //
    // Measured on a bench station: the newest 200 records were 120 t:identity,
    // 69 t:observation, 11 t:service and no messages, so a strictly
    // chronological page of twelve is twelve beacons and the conversation is
    // never reached. Ordering by band first costs one CASE and uses the
    // (toc,pts) and (fromc,pts) indexes that already exist.
    var order = 'pts DESC';
    if (rankFor != null && rankFor.trim().isNotEmpty) {
      final me = _base(rankFor);
      final talk = kXprsTalk.map((t) => "'$t'").join(',');
      order = 'CASE '
          // 1. their own mail, either direction
          'WHEN toc=? OR fromc=? THEN 0 '
          // 2. what was said locally
          'WHEN type IN ($talk) THEN 1 '
          // 3. presence and service chatter, which a short page rarely reaches
          'ELSE 2 END, pts DESC';
      args
        ..add(me)
        ..add(me);
    }
    args.add(limit.clamp(1, 1000));
    final rows = db.select(
        'SELECT id,ts,pts,type,fromc,toc,bearer,rssi,mine,own,sig,heard,wire '
        'FROM packets WHERE $where ORDER BY $order LIMIT ?',
        args);
    return [
      for (final r in rows)
        {
          'id': r['id'],
          'ts': (r['pts'] as int) ~/ 1000,
          'heardTs': (r['ts'] as int) ~/ 1000,
          'bearer': r['bearer'],
          'rssi': r['rssi'],
          'from': r['fromc'],
          'to': r['toc'],
          'type': r['type'],
          'mine': (r['mine'] as int) != 0,
          'own': (r['own'] as int) != 0,
          'sig': XprsSigState.values[(r['sig'] as int)].name,
          'heard': r['heard'],
          'wire': r['wire'],
        }
    ];
  }

  /// Counters for /api/status-style checks.
  Map<String, dynamic> statusJson() {
    final db = _db;
    final rows = db == null
        ? 0
        : db.select('SELECT COUNT(*) c FROM packets').first['c'] as int;
    return {
      'ready': ready,
      'rows': rows,
      'bytes': db == null ? 0 : _dataBytes(db),
      'declarations': declCount,
      'pending': _pending.length,
      'admitted': admitted,
      'forged': forged,
      'dropped': dropped,
    };
  }
}
