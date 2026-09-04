// Generic, app-agnostic conversation model for the ConversationsField
// primitive. A wapp owns all semantics (who a conversation is, how it is
// named, what is pinned, badges, ordering inputs) and drives this store via
// the ui.convo.* protocol; the host only renders what it is told. There is
// no domain knowledge here (no groups, callsigns, bulletins, distance, etc.).

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../services/log_service.dart';
import 'conversation_db.dart';

/// Short, stable key for a message: the first 8 hex characters of sha1(text),
/// plus the time it carries — "1a2b3c4d@13:51".
///
/// A vote has to name the message it votes on across two devices that may hold
/// it under different ids (or, for anything sent before ids were derived, no
/// id at all). Sending the text itself would work and is what a first cut did,
/// but a message can be an image reference or several hundred characters, and
/// these votes ride Bluetooth — this is a fixed ~14 characters whatever the
/// message, and the far side computes the same key from what it already has.
///
/// The time is there because content alone is not unique: "ok" gets sent all
/// day, and a like on this morning's would land on the newest one. It is a
/// tie-breaker, not a requirement — see [matchesContentKey], which falls back
/// to content when two clocks disagree about the minute.
String contentKey(String text, [String time = '']) {
  final t = text.replaceAll('\n', ' ').trim();
  if (t.isEmpty) return '';
  final h = sha1.convert(utf8.encode(t)).toString().substring(0, 8);
  return time.isEmpty ? h : '$h@$time';
}

/// Does [key] name this message? [exact] demands the time match too.
bool matchesContentKey(Map<String, dynamic> m, String key, {bool exact = true}) {
  final at = key.indexOf('@');
  final wantHash = at < 0 ? key : key.substring(0, at);
  final wantTime = at < 0 ? '' : key.substring(at + 1);
  final text = (m['text'] ?? '').toString();
  if (contentKey(text) != wantHash) return false;
  if (!exact || wantTime.isEmpty) return true;
  return (m['time'] ?? '').toString() == wantTime;
}

/// One conversation row + its messages. All fields are opaque to the host.
class ConversationItem {
  final String id;
  String title;
  String subtitle; // preview line for the list
  String badge; // free-text trailing chip, e.g. a distance the wapp computed
  String icon; // generic icon name (person, campaign, tag, group, chat…)
  int unread;

  /// Muted: unread still counts on this row (shown grey) but does NOT propagate
  /// to the Messages-tab / app-icon badge (no app-wide attention).
  bool muted;

  /// Closed: removed from the conversation list view. Re-appears when a new
  /// incoming message arrives.
  bool closed;

  /// Declared: the wapp has listed this conversation as one of its own, by
  /// sending `ui.convo.upsert` for it. False means the HOST invented the row
  /// — [ConversationStore._ensure] creates one whenever a message arrives for
  /// an unknown id, so an inbound message alone can mint a conversation the
  /// wapp never lists and no screen can render. Those must not badge: a count
  /// the user cannot open is a demand for attention with nowhere to go. Same
  /// treatment as [muted] — it still shows on its own row if it ever becomes
  /// visible, but it never propagates app-wide.
  ///
  /// Rows written before this field existed load as declared, so the upgrade
  /// hides nothing that is already on screen.
  bool declared;

  /// Private: a wapp-defined flag the wapp sets per conversation (e.g. APRS's
  /// "Reticulum-only" mode). Purely a display hint here — the host shows a lock
  /// indicator; the wapp owns the routing behaviour.
  bool private;

  /// Host wall-clock (ms) of the last real activity (message / pin / new
  /// unread) — the primary sort key so the most recently active conversations
  /// sit on top. 0 for legacy rows that predate this field; the list sort then
  /// falls back to unread-first, then non-empty, then insertion order.
  int activityTs;

  /// Normal messages, in arrival order. Each: {dir, from, text, time}.
  final List<Map<String, dynamic>> messages = [];

  ConversationItem(
    this.id, {
    this.title = '',
    this.subtitle = '',
    this.badge = '',
    this.icon = 'chat',
    this.unread = 0,
    this.activityTs = 0,
    this.muted = false,
    this.closed = false,
    this.private = false,
    this.declared = false,
    this.lastLine = '',
  });

  /// The preview line: what was last actually SAID here, as "who: what".
  ///
  /// Derived once when the message arrives and stored on the thread row,
  /// because the list needs it and reading a conversation's messages to
  /// recompute it is what made opening the wapp cost every message in the
  /// database. Distinct from [subtitle], which is whatever the wapp chose to
  /// put there and is nobody else's to overwrite.
  String lastLine;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'badge': badge,
        'icon': icon,
        'unread': unread,
        'activityTs': activityTs,
        'muted': muted,
        'closed': closed,
        'private': private,
        'declared': declared,
        'lastLine': lastLine,
        'messages': messages,
      };

  factory ConversationItem.fromJson(Map<String, dynamic> j) {
    final it = ConversationItem(
      (j['id'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      subtitle: (j['subtitle'] ?? '').toString(),
      badge: (j['badge'] ?? '').toString(),
      icon: (j['icon'] ?? 'chat').toString(),
      unread: (j['unread'] as num?)?.toInt() ?? 0,
      activityTs: (j['activityTs'] as num?)?.toInt() ?? 0,
      muted: j['muted'] == true,
      closed: j['closed'] == true,
      private: j['private'] == true,
      lastLine: (j['lastLine'] ?? '').toString(),
      // Absent = written before the flag existed = already on screen.
      declared: j['declared'] == null || j['declared'] == true,
    );
    final msgs = j['messages'];
    if (msgs is List) {
      for (final m in msgs) {
        if (m is Map) it.messages.add(m.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    return it;
  }
}

class ConversationStore {
  final Map<String, ConversationItem> items = {};

  /// Durable backing store. When set AND [loaded] is true, every mutation is
  /// written through as it happens — no debounce, no whole-file rewrite.
  ConversationDb? db;

  /// Which field name this store is persisted under (one database serves all
  /// of a wapp's conversation fields).
  String dbField = 'conversations';

  /// True once the history has been READ successfully (or confirmed empty).
  ///
  /// This is the guard that stops the loss it is named after: when a restore
  /// throws — a locked profile, a wrong key, an unreadable file — the store
  /// stays usable in memory but NEVER writes, because a store that could not
  /// read the history must not be allowed to overwrite it. The old code could
  /// not tell those apart and erased a phone's entire history on every launch.
  bool loaded = true;

  /// True when this store cannot persist: no database, or a history that
  /// could not be read. Exposed so a screen can say so, not only the log.
  bool get memoryOnly => db == null || !loaded;

  /// Which wapp this store belongs to, named in the warning below.
  String owner = '';

  /// The wapp keeps its own history and repaints this store from it
  /// (`"conversations": "wapp"` in its manifest). Memory-only is then the
  /// design, not a failure, and the warning below stays quiet.
  bool wappOwned = false;

  bool _saidMemoryOnly = false;

  bool get _wt {
    if (db != null && loaded) return true;
    if (!_saidMemoryOnly && !wappOwned) {
      _saidMemoryOnly = true;
      // Open-time already said the database would not open. This is the only
      // place that can say a MESSAGE was not written, which is the fact a
      // person actually notices — and it is said once, not once per message.
      LogService.instance.add(
          'conversations: "$dbField"${owner.isEmpty ? '' : ' ($owner)'} is '
          'MEMORY-ONLY (${db == null ? 'no database' : 'history unreadable'}) '
          '— nothing said here survives this session');
    }
    return false;
  }

  /// Senders whose messages are hidden (§ blocking), stated by the wapp.
  ///
  /// Blocking used to DELETE. It ran `db.clear()` over every conversation and
  /// then wrote back only the in-memory tail — which is empty for any thread
  /// nobody had opened this session, so blocking one person destroyed the
  /// stored history of every other room. Nothing is deleted now: the rows stay
  /// and this set decides what is drawn, so unblocking gives them back.
  ///
  /// The wapp owns the list durably (its own KV) and re-states it at every
  /// start, the way it re-states the rail. Nothing here is persisted.
  final Set<String> blockedFrom = {};

  /// Most-recent-first display order.
  final List<String> order = [];

  /// Reaction tally per message id (mid). The wapp reports each individual
  /// like/unlike (by an opaque actor id) and the host owns the set, so each
  /// actor counts once. Value: `{'likers': List<String>, 'mine': bool}`. The
  /// derived count + my-state are mirrored onto every message carrying that mid
  /// (`likes`/`liked`) so the renderer reads simple fields. Keyed by mid so it
  /// survives message ordering and applies across conversations sharing a mid.
  final Map<String, Map<String, dynamic>> reactions = {};

  /// Delivery/read status per message correlation id (`rid`): 'sent' →
  /// 'delivered' → 'read' (WhatsApp-style ticks on our own 1:1 messages). Kept
  /// out-of-band + mirrored onto every message carrying that `rid` (like
  /// reactions) so an out-of-order receipt still lands. Never downgrades.
  final Map<String, String> _statuses = {};
  static const Map<String, int> _statusRank = {
    'sent': 1,
    'delivered': 2,
    'read': 3,
  };

  /// Conversations whose message tail has been read from the database.
  ///
  /// A restore loads the thread rows only, so a conversation's messages arrive
  /// the first time somebody looks at it. Ids are tiny; this holds them for
  /// the life of the store rather than re-reading on every rebuild.
  final Set<String> _hydrated = {};

  /// The message tail of [id], reading it from the database on first use.
  ///
  /// Every caller that renders a thread goes through here instead of touching
  /// `item.messages`, so "have we read this one yet?" is asked in one place
  /// rather than at each screen that happens to show messages.
  List<Map<String, dynamic>> messagesOf(String id) {
    final it = items[id];
    if (it == null) return const [];
    if (_hydrated.contains(id) || !_wt) return _visible(it.messages);
    _hydrated.add(id);
    try {
      final rows = db!.loadMessages(dbField, id);
      // Replace rather than merge: every message was written through on the
      // way in, so the database is the complete copy and anything appended in
      // memory before this point is already in those rows.
      it.messages
        ..clear()
        ..addAll(rows);
    } catch (_) {
      // Unreadable tail: show the thread empty rather than failing the screen,
      // and do not retry per frame.
    }
    return _visible(it.messages);
  }

  /// The tail minus whatever a blocked sender wrote. The rows are still there;
  /// this is the only place blocking is applied, so unblocking is free.
  List<Map<String, dynamic>> _visible(List<Map<String, dynamic>> msgs) {
    if (blockedFrom.isEmpty) return msgs;
    return msgs
        .where((m) => !blockedFrom.contains((m['from'] ?? '').toString()))
        .toList(growable: false);
  }

  /// Replace the blocked-sender set (the wapp states it whole, never a delta).
  ///
  /// Blocking hides; it never deletes. So when the set changes, the stored
  /// preview and unread badge of every thread are reconciled against what is
  /// now visible — a thread whose only messages were a blocked sender's shows
  /// no preview and no badge (rather than a count pointing at an empty room),
  /// and unblocking brings the preview back. The message rows are untouched.
  void setBlocked(Iterable<String> from) {
    final next = from.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (next.length == blockedFrom.length && next.containsAll(blockedFrom)) {
      return;
    }
    blockedFrom
      ..clear()
      ..addAll(next);
    for (final e in items.entries) {
      final vis = _visible(messagesOf(e.key));
      if (vis.isEmpty) {
        // Nothing left to show: no preview, and a badge here would point at an
        // empty room.
        e.value.lastLine = '';
        e.value.unread = 0;
        if (_wt) db!.upsertThread(dbField, e.value);
        continue;
      }
      final last = vis.last;
      final text = (last['text'] ?? '').toString().trim();
      final who = (last['from'] ?? '').toString();
      if (text.isNotEmpty) {
        e.value.lastLine = who.isEmpty ? text : '$who: $text';
        if (_wt) db!.upsertThread(dbField, e.value);
      }
    }
  }

  /// The conversation currently shown (set by the widget) so the store can
  /// auto-manage unread counts. Null when no conversation is open.
  String? openId;

  ConversationItem _ensure(String id) {
    final it = items.putIfAbsent(id, () => ConversationItem(id, title: id));
    // Append, don't front-insert: a conversation only rises to the top when it
    // has ACTUAL activity (addMessage / bump). Front-inserting here made groups
    // merely listed via upsert (metadata, no message) jump above conversations
    // with recent messages.
    if (!order.contains(id)) order.add(id);
    return it;
  }

  void _bump(String id) {
    order.remove(id);
    order.insert(0, id);
  }

  /// Create/update a conversation's list-row metadata. Only the keys present
  /// in [d] are changed.
  void upsert(Map d) {
    final id = (d['id'] ?? '').toString();
    if (id.isEmpty) return;
    final it = _ensure(id);
    // The wapp is listing it, so the user can reach it: it may badge.
    it.declared = true;
    if (d.containsKey('title')) it.title = (d['title'] ?? '').toString();
    if (d.containsKey('subtitle')) it.subtitle = (d['subtitle'] ?? '').toString();
    if (d.containsKey('badge')) it.badge = (d['badge'] ?? '').toString();
    if (d.containsKey('icon')) it.icon = (d['icon'] ?? 'chat').toString();
    if (d.containsKey('private')) it.private = d['private'] == true;
    if (d.containsKey('unread')) {
      final nv = (d['unread'] as num?)?.toInt() ?? it.unread;
      if (nv > it.unread) it.activityTs = _nowMs(); // new unread = activity
      it.unread = nv;
    }
    if (d['bump'] == true) {
      it.activityTs = _nowMs();
      _bump(id);
    }
    // The wapp is the authority on closed state: it emits closed:false when
    // the user re-engages a muted conversation (open / send / new message).
    // Without this, addMessage's closed-drop was permanent — nothing ever
    // cleared the flag.
    if (d.containsKey('closed')) it.closed = d['closed'] == true;
    if (_wt) db!.upsertThread(dbField, it);
  }

  void addMessage(Map d) {
    final id = (d['id'] ?? '').toString();
    if (id.isEmpty) return;
    // A closed conversation is unsubscribed: drop incoming messages so it stays
    // gone (our own sends still go through — they reopen it intentionally).
    final existing = items[id];
    final dir = (d['dir'] ?? 'in').toString();
    if (existing != null && existing.closed && dir == 'in') return;
    // Read the tail before deduplicating against it. A restarted engine
    // re-emits its whole durable inbox, and the check below only works against
    // messages we are actually holding — with tails read lazily, a thread
    // nobody has opened holds none, and every one of them would come back as
    // a fresh bubble. Only threads that receive traffic pay this, and only
    // once each.
    if (existing != null) messagesOf(id);
    // A restarted engine re-reads the host's durable inbox from the beginning
    // and re-emits everything in it, so the same message can arrive twice with
    // the same content signature. Show it once.
    final ckey = (d['key'] ?? '').toString();
    final dmid = (d['mid'] ?? '').toString();
    if (existing != null) {
      final dup = existing.messages.any((m) =>
          (ckey.isNotEmpty && (m['key'] ?? '').toString() == ckey) ||
          (dmid.isNotEmpty && (m['mid'] ?? '').toString() == dmid));
      if (dup) return;
    }
    final it = _ensure(id);
    it.messages.add({
      'dir': dir,
      'from': (d['from'] ?? '').toString(),
      'text': (d['text'] ?? '').toString(),
      'time': (d['time'] ?? '').toString(),
      'meta': (d['meta'] ?? '').toString(),
      'key': (d['key'] ?? '').toString(),
      if ((d['via'] ?? '').toString().isNotEmpty) 'via': d['via'].toString(),
      // Opaque threading ids set by the wapp (groups only): this message's id
      // and the id it replies to. The host just stores + renders the relation.
      if ((d['mid'] ?? '').toString().isNotEmpty) 'mid': d['mid'].toString(),
      if ((d['parent'] ?? '').toString().isNotEmpty) 'parent': d['parent'].toString(),
      if ((d['auth'] ?? '').toString().isNotEmpty) 'auth': d['auth'].toString(),
      if (d['enc'] == true) 'enc': true,
      // System note (not a real message): rendered as a centered, muted line —
      // no avatar/name/bubble. Used for in-chat status like "key unknown — sent
      // public; checking relays".
      if (d['sys'] == true) 'sys': true,
      // Reticulum-only (private) message — the wapp tags it so the bubble is
      // visibly distinct from public APRS traffic (which can also be encrypted).
      if (d['private'] == true) 'private': true,
      // The other half of the same statement (docs/XPRS.md section 9.2).
      // Carried explicitly rather than inferred from `private` being absent,
      // because absent means "the wapp said nothing", which is not the same as
      // "this went out readable".
      if (d['plain'] == true) 'plain': true,
      // Delivery-receipt correlation id + tick state for 1:1 outgoing messages
      // (WhatsApp-style sent/delivered/read). The wapp stamps `rid` (a small
      // per-message id echoed back in receipts); `status` advances via setStatus.
      if ((d['rid'] ?? '').toString().isNotEmpty) 'rid': d['rid'].toString(),
      if ((d['status'] ?? '').toString().isNotEmpty) 'status': d['status'].toString(),
      if (d['lat'] != null) 'lat': d['lat'],
      if (d['lon'] != null) 'lon': d['lon'],
    });
    if (it.messages.length > 500) {
      it.messages.removeRange(0, it.messages.length - 500);
    }
    // A like may have arrived before this message — seed its tally now.
    final mid = (d['mid'] ?? '').toString();
    if (mid.isNotEmpty && reactions.containsKey(mid)) _applyReaction(mid);
    // A receipt may have arrived before this bubble — apply the latest status.
    final rid = (d['rid'] ?? '').toString();
    if (rid.isNotEmpty && _statuses.containsKey(rid)) _applyStatus(rid);
    // Keep the preview on the thread row. A vote arrives as a "<mid>:like"
    // message and is not something anybody said, and a system note is not
    // either — quoting one as the last word would show a hex blob or a status
    // line where the conversation should be.
    // A blocked sender is INVISIBLE, and that means the preview and the unread
    // badge too — not only the bubble list ([_visible]). Otherwise the rail
    // showed a blocked person's words with an unread count, the user tapped in,
    // and the room was empty: the message was there, hidden, and nothing said
    // so. Their row is left exactly as it was.
    final fromBlocked = blockedFrom.contains((d['from'] ?? '').toString());
    if (d['sys'] != true && !fromBlocked) {
      final text = (d['text'] ?? '').toString().trim();
      final isVote = RegExp(r'^[0-9a-f]{8,64}:(?:un)?like$').hasMatch(text);
      if (text.isNotEmpty && !isVote) {
        final who = (d['from'] ?? '').toString();
        it.lastLine = who.isEmpty ? text : '$who: $text';
      }
    }
    // A REPLAY IS NOT AN ARRIVAL.
    //
    // The wapp refills a room from the core's archive when its own copy was
    // lost or was never written, and every one of those has already been
    // seen, delivered and usually read. Stored, and nothing else: no badge, no
    // bump, no activity stamp. Without this a refill of sixty rows would
    // badge the room sixty times and float it to the top of the rail on every
    // single launch, which is worse than the missing history it repairs.
    if (d['backfill'] != true && !fromBlocked) {
      if (dir == 'in' && id != openId && d['sys'] != true) it.unread++;
      it.activityTs = _nowMs();
      _bump(id);
    }
    if (_wt) {
      db!.addMessage(dbField, id, it.messages.last);
      db!.upsertThread(dbField, it);
    }
  }

  /// Mute / unmute a conversation (its unread stops counting app-wide).
  void setMuted(String id, bool v) {
    final it = items[id];
    if (it == null) return;
    it.muted = v;
    if (_wt) db!.upsertThread(dbField, it);
  }

  /// Close a conversation (hide from the list) or reopen it.
  void setClosed(String id, bool v) {
    final it = items[id];
    if (it == null) return;
    it.closed = v;
    if (_wt) db!.upsertThread(dbField, it);
  }

  /// Remove already-shown messages locally (hide / block — never network state).
  /// Two forms: `{id, key}` drops one message from one conversation; `{from}`
  /// drops every message by a sender across all conversations and removes a
  /// direct conversation row with that callsign.
  void remove(Map d) {
    final from = (d['from'] ?? '').toString();
    if (from.isNotEmpty) {
      // BLOCKING DELETES NOTHING NOW.
      //
      // What stood here looped every conversation doing `db.clear(field, id)`
      // and then re-added `it.messages` — and tails are hydrated lazily, so a
      // thread nobody had opened this session wrote an empty list back over
      // its whole stored history. Blocking one person emptied every room.
      //
      // The rows stay and [blockedFrom] decides what is drawn ([_visible]),
      // which also makes unblocking give the messages back. The 1:1 row is
      // dropped from view because it is a conversation the user ended; its
      // messages remain on disk under that id.
      blockedFrom.add(from);
      for (final it in items.values) {
        it.messages.removeWhere((m) => (m['from'] ?? '').toString() == from);
      }
      if (items.containsKey(from)) {
        items.remove(from);
        order.remove(from);
      }
      return;
    }
    final id = (d['id'] ?? '').toString();
    final key = (d['key'] ?? '').toString();
    if (id.isEmpty) return;
    if (key.isEmpty) {
      // Remove the whole conversation row (e.g. a wapp deleting/leaving a circle).
      items.remove(id);
      order.remove(id);
      if (_wt) db!.removeThread(dbField, id);
      return;
    }
    final it = items[id];
    if (it == null) return;
    it.messages.removeWhere((m) => (m['key'] ?? '').toString() == key);
    // One row asked for, one row deleted. The clear-and-rewrite this replaces
    // wrote a lazily-hydrated (often empty) tail back over the whole thread.
    if (_wt) db!.deleteMessageByKey(dbField, id, key);
  }

  /// Record a reaction (like) on a message. [d]: `{mid, from, remove?, mine?}`.
  /// The set of `likers` is deduped, so each actor counts once however many
  /// times they vote; `remove` retracts. `mine` marks our own vote.
  ///
  /// Returns the conversation and message SOMEONE ELSE just liked of ours, so
  /// the caller can tell the user — a like that only moves a counter on a
  /// screen nobody is looking at is a like nobody receives. Null for our own
  /// votes, retractions, votes on other people's messages, and votes naming a
  /// message we do not hold.
  ({String convo, Map<String, dynamic> message, String from})? react(Map d) {
    var mid = (d['mid'] ?? '').toString();
    final from = (d['from'] ?? '').toString();
    if (mid.isEmpty || from.isEmpty) return null;
    final remove = d['remove'] == true;
    final mine = d['mine'] == true;
    // A vote may name a message we hold under a DIFFERENT id, or under none at
    // all — anything sent before ids were derived, or by a peer that numbers
    // messages its own way. The text is the one thing both ends always have,
    // so when the id resolves to nothing we find the message by content and
    // ADOPT the voter's id for it. The next vote then matches directly, and
    // the message becomes votable from either side for good.
    final voted = (d['ck'] ?? '').toString();
    if (voted.isNotEmpty && !_knowsMid(mid)) {
      final hit = _byContentKey(d['id']?.toString(), voted);
      if (hit != null) {
        final was = (hit.message['mid'] ?? '').toString();
        if (was.isEmpty) {
          final oldBody = jsonEncode(hit.message);
          hit.message['mid'] = mid;
          if (_wt) {
            db!.setMessageMid(dbField, hit.convo, oldBody,
                jsonEncode(hit.message), mid);
          }
        } else {
          mid = was; // we already had an id for it — keep ours, tally on it
        }
      }
    }
    final r = reactions.putIfAbsent(
        mid, () => {'likers': <String>[], 'mine': false});
    final likers = (r['likers'] as List).cast<String>();
    if (remove) {
      likers.remove(from);
      if (mine) r['mine'] = false;
    } else {
      if (!likers.contains(from)) likers.add(from);
      if (mine) r['mine'] = true;
    }
    _applyReaction(mid);
    if (_wt) db!.setReaction(dbField, mid, r);
    if (remove || mine) return null;
    for (final e in items.entries) {
      for (final m in e.value.messages) {
        if ((m['mid'] ?? '') != mid) continue;
        if ((m['dir']?.toString() ?? 'in') != 'out') return null; // not ours
        return (convo: e.key, message: m, from: from);
      }
    }
    return null;
  }

  /// Do we hold any message carrying [mid]? A vote naming an id we never saw
  /// is not an error — it is the normal case across two devices that numbered
  /// the same message differently.
  bool _knowsMid(String mid) {
    for (final it in items.values) {
      for (final m in it.messages) {
        if ((m['mid'] ?? '') == mid) return true;
      }
    }
    return false;
  }

  /// The message whose content matches this key, preferring the named
  /// conversation and the most recent match — the one a person would point at.
  ({String convo, Map<String, dynamic> message})? _byContentKey(
      String? convo, String ck) {
    // Same content AND the same minute first: "ok" is sent all day, and a like
    // on this morning's must not land on the newest one. If no minute agrees —
    // two devices stamped the same message a minute apart — fall back to
    // content and take the most recent, which is still the right message far
    // more often than nothing at all.
    for (final exact in [true, false]) {
      ({String convo, Map<String, dynamic> message})? found;
      for (final e in items.entries) {
        if (convo != null && convo.isNotEmpty && e.key != convo) continue;
        for (final m in e.value.messages) {
          if (matchesContentKey(m, ck, exact: exact)) {
            found = (convo: e.key, message: m);
          }
        }
      }
      if (found != null) return found;
    }
    return null;
  }

  /// Mirror a mid's tally (`likes` count + `liked` mine-flag) onto every stored
  /// message/pinned entry carrying that mid, across all conversations.
  void _applyReaction(String mid) {
    final r = reactions[mid];
    if (r == null) return;
    final count = (r['likers'] as List).length;
    final mine = r['mine'] == true;
    for (final it in items.values) {
      for (final m in it.messages) {
        if ((m['mid'] ?? '') == mid) {
          m['likes'] = count;
          m['liked'] = mine;
          if (_wt) db!.updateMessage(dbField, it.id, m);
        }
      }
    }
  }

  /// Advance a message's delivery/read status. [d]: `{rid, status}` where status
  /// is 'sent' | 'delivered' | 'read'. Monotonic — a later, lower-ranked receipt
  /// (e.g. a delivered arriving after read) is ignored.
  void setStatus(Map d) {
    final rid = (d['rid'] ?? '').toString();
    final s = (d['status'] ?? '').toString();
    if (rid.isEmpty || !_statusRank.containsKey(s)) return;
    final cur = _statuses[rid];
    if (cur != null && (_statusRank[cur] ?? 0) >= (_statusRank[s] ?? 0)) return;
    _statuses[rid] = s;
    _applyStatus(rid);
    if (_wt) db!.setStatus(dbField, rid, s);
  }

  /// Mirror a rid's status onto every stored message carrying that rid.
  void _applyStatus(String rid) {
    final s = _statuses[rid];
    if (s == null) return;
    for (final it in items.values) {
      for (final m in it.messages) {
        if ((m['rid'] ?? '') == rid) {
          m['status'] = s;
          if (_wt) db!.updateMessage(dbField, it.id, m);
        }
      }
    }
  }

  /// Zero every conversation's unread — the user's "I have seen all of it".
  /// Returns whether anything changed.
  bool markAllRead() {
    var changed = false;
    for (final it in items.values) {
      if (it.unread == 0) continue;
      it.unread = 0;
      changed = true;
      if (_wt) db!.upsertThread(dbField, it);
    }
    return changed;
  }

  void clearUnread(String id) {
    final it = items[id];
    if (it == null || it.unread == 0) return;
    it.unread = 0;
    if (_wt) db!.upsertThread(dbField, it);
  }

  /// Clear one conversation (id given) or all (id empty/null).
  /// Clear ONE conversation. An empty or absent id is REFUSED.
  ///
  /// A wapp sent the empty form from its `module_init` for two releases and
  /// emptied every room on the device at every start — `#LOCAL` included, which
  /// it was never about. Destroying a whole field is [clearWholeField], which
  /// is not reachable from the `ui.convo.*` protocol and has to say why.
  void clear([String? id]) {
    if (id == null || id.isEmpty) {
      LogService.instance.add(
          'conversations: refused a clear of the whole "$dbField" field — '
          'a wapp clears one conversation at a time');
      return;
    }
    items.remove(id);
    order.remove(id);
    if (_wt) db!.removeThread(dbField, id);
  }

  /// Destroy every thread, message, reaction and status in this field.
  ///
  /// The host's own "clear chat" is the only caller. [reason] is logged,
  /// because a wipe that nobody can attribute is how this took a day to find.
  void clearWholeField({required String reason}) {
    final n = items.length;
    items.clear();
    order.clear();
    if (_wt) db!.clear(dbField);
    LogService.instance.add(
        'conversations: cleared the whole "$dbField" field '
        '($n conversation(s)) — $reason');
  }

  /// Whether a notification about conversation [id] is worth raising.
  ///
  /// A notification's whole purpose is to take the user somewhere. If the tap
  /// target is a conversation they cannot open — one the wapp never listed —
  /// or one they have muted, the notification is a dead end and is not shown.
  /// An id this store has never heard of is allowed: the notification may be
  /// the thing that creates the conversation.
  bool mayNotifyFor(String? id) {
    if (id == null || id.isEmpty) return true;
    final it = items[id];
    if (it == null) return true;
    return it.declared && !it.muted;
  }

  /// Total unread across all conversations — drives the Messages tab/app-icon
  /// badge. Muted, closed and undeclared conversations are excluded so they
  /// don't pull app-wide attention; their count still shows on their own row.
  ///
  /// Undeclared is the same judgement as muted, applied to a row the wapp
  /// never listed (see [ConversationItem.declared]): if the user cannot open
  /// it, it must not ask for their attention.
  int get totalUnread => items.values.fold(
      0,
      (sum, it) => sum +
          ((it.unread > 0 && !it.muted && !it.closed && it.declared)
              ? it.unread
              : 0));

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Conversations for display, most-recently-active first. Primary key is
  /// [ConversationItem.activityTs] (host-stamped on real activity). Legacy rows
  /// (activityTs == 0, saved before that field existed) tie on 0 and fall back
  /// to: unread first, then non-empty, then insertion order — which fixes
  /// already-persisted lists where unread/active rows had sunk below empties.
  List<ConversationItem> ordered() {
    // Closed conversations are hidden from the list (they reappear on a new
    // incoming message).
    final list = [
      for (final id in order)
        if (items.containsKey(id) && !items[id]!.closed) items[id]!
    ];
    final idx = {for (var i = 0; i < order.length; i++) order[i]: i};
    list.sort((a, b) {
      if (a.activityTs != b.activityTs) {
        return b.activityTs.compareTo(a.activityTs); // newer first
      }
      final ua = a.unread > 0 ? 1 : 0, ub = b.unread > 0 ? 1 : 0;
      if (ua != ub) return ub.compareTo(ua); // unread before read
      final ma = a.messages.isNotEmpty ? 1 : 0, mb = b.messages.isNotEmpty ? 1 : 0;
      if (ma != mb) return mb.compareTo(ma); // non-empty before empty
      return (idx[a.id] ?? 0).compareTo(idx[b.id] ?? 0); // stable
    });
    return list;
  }

  /// Read-only view of the delivery/read statuses (for the durable store).
  Map<String, String> statusesSnapshot() => Map.unmodifiable(_statuses);

  /// Restore statuses read back from the durable store and re-mirror them.
  void restoreStatuses(Map<String, String> saved) {
    _statuses
      ..clear()
      ..addAll(saved);
    for (final rid in _statuses.keys) {
      _applyStatus(rid);
    }
  }

  /// Serialize the whole store for on-disk persistence.
  Map<String, dynamic> toJson() => {
        'order': order,
        'items': {for (final e in items.entries) e.key: e.value.toJson()},
        'reactions': reactions,
        'statuses': _statuses,
      };

  /// Replace the store's contents from a previously [toJson]-ed map.
  void loadJson(Map<String, dynamic> j) {
    items.clear();
    order.clear();
    reactions.clear();
    final its = j['items'];
    if (its is Map) {
      its.forEach((k, v) {
        if (v is Map) {
          items[k.toString()] =
              ConversationItem.fromJson(v.map((kk, vv) => MapEntry(kk.toString(), vv)));
        }
      });
    }
    final ord = j['order'];
    if (ord is List) {
      for (final id in ord) {
        final s = id.toString();
        if (items.containsKey(s) && !order.contains(s)) order.add(s);
      }
    }
    // Defensive: any item missing from the saved order still gets shown.
    for (final k in items.keys) {
      if (!order.contains(k)) order.add(k);
    }
    // Restore reaction tallies and re-mirror them onto the loaded messages.
    final rx = j['reactions'];
    if (rx is Map) {
      rx.forEach((k, v) {
        if (v is Map) {
          final likers = <String>[
            for (final e in (v['likers'] is List ? v['likers'] as List : const []))
              e.toString()
          ];
          reactions[k.toString()] = {'likers': likers, 'mine': v['mine'] == true};
        }
      });
      for (final mid in reactions.keys) {
        _applyReaction(mid);
      }
    }
    // Restore delivery/read statuses and re-mirror onto loaded messages.
    _statuses.clear();
    final st = j['statuses'];
    if (st is Map) {
      st.forEach((k, v) {
        final s = v.toString();
        if (_statusRank.containsKey(s)) _statuses[k.toString()] = s;
      });
      for (final rid in _statuses.keys) {
        _applyStatus(rid);
      }
    }
  }
}
