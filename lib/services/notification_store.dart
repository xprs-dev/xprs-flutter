import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../platform/platform.dart' as platform;
import '../profile/profile_service.dart';
import '../profile/storage_paths.dart';
import 'event_bus.dart';
import 'notification_service.dart';

class StoredNotification {
  final String id;
  final NotificationLevel level;
  final String title;
  final String? body;
  final String source;

  /// Conversation inside the source wapp this is about — the tap target.
  final String? convo;

  final DateTime timestamp;

  /// Whether the user has already seen this notification.
  ///
  /// Per ROW, deliberately, rather than one global "seen before this time"
  /// watermark. The watermark had two moving operands: it moved forward when
  /// the user read the list, and the row's timestamp moved forward whenever a
  /// replayed event was re-recorded -- so an already-read notification jumped
  /// back above the line and re-lit the bell. A flag cannot be un-set by a
  /// replay, so a notification the user has seen stays seen.
  ///
  /// Null means "written by a build that predated this field": the loader
  /// resolves those against the legacy watermark, so the first launch after
  /// the upgrade shows exactly what the old build showed.
  final bool? seen;

  const StoredNotification({
    required this.id,
    required this.level,
    required this.title,
    this.body,
    required this.source,
    this.convo,
    required this.timestamp,
    this.seen,
  });

  StoredNotification copyWith({bool? seen, DateTime? timestamp}) =>
      StoredNotification(
        id: id,
        level: level,
        title: title,
        body: body,
        source: source,
        convo: convo,
        timestamp: timestamp ?? this.timestamp,
        seen: seen ?? this.seen,
      );

  factory StoredNotification.fromJson(Map<String, dynamic> json) {
    return StoredNotification(
      id: (json['id'] ?? '').toString(),
      level: _levelFromString((json['level'] ?? 'info').toString()),
      title: (json['title'] ?? '').toString(),
      body: json['body']?.toString(),
      source: (json['source'] ?? '').toString(),
      convo: json['convo']?.toString(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['timestamp'] as num?)?.toInt() ?? 0,
      ),
      seen: json['seen'] as bool?,
    );
  }

  factory StoredNotification.fromNotification(XprsNotification n) {
    final ts = n.timestamp;
    return StoredNotification(
      // The tag, when there is one, IS the identity: the same event announced
      // twice must be the same ROW. A timestamp id made every repeat a new row,
      // so the bell could never stop counting the same thing.
      id: (n.tag != null && n.tag!.isNotEmpty)
          ? n.tag!
          : '${ts.microsecondsSinceEpoch}:${n.source}',
      level: n.level,
      title: n.title,
      body: n.body,
      source: n.source,
      convo: n.convo,
      timestamp: ts,
      seen: false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'level': level.name,
    'title': title,
    if (body != null) 'body': body,
    'source': source,
    if (convo != null && convo!.isNotEmpty) 'convo': convo,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };
}

NotificationLevel _levelFromString(String raw) {
  return switch (raw.toLowerCase()) {
    'success' => NotificationLevel.success,
    'warning' || 'warn' => NotificationLevel.warning,
    'error' || 'err' => NotificationLevel.error,
    _ => NotificationLevel.info,
  };
}

class NotificationStore {
  NotificationStore._();
  static final NotificationStore instance = NotificationStore._();

  static const int maxItems = 300;
  static const String _itemsFile = 'notifications/history.jsonl';
  static const String _seenFile = 'notifications/seen_ms.txt';

  final ValueNotifier<List<StoredNotification>> items =
      ValueNotifier<List<StoredNotification>>(const []);
  final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);

  EventSubscription<NotificationShownEvent>? _sub;
  bool _initialised = false;
  int _seenMs = 0;

  void init() {
    if (_initialised) return;
    _initialised = true;
    _sub = EventBus().on<NotificationShownEvent>((e) {
      unawaited(record(e.notification).catchError((_) {}));
    });
    ProfileService.instance.activeProfileNotifier.addListener(_reload);
    unawaited(_load());
  }

  /// Whether [n] belongs on the bell at all.
  ///
  /// The bell is for notifications that have nowhere else to go. A conversation
  /// message does: the source wapp's own icon carries its unread count (chat's
  /// forum badge, mail's envelope), and the in-app card already announced it.
  /// Letting it ALSO light the bell shows one message on two counters, which is
  /// exactly what a person reads as wrong. `convo` is set only by messaging
  /// wapps and names the thread a tap opens, so it is the precise mark of
  /// "this is a wapp badge's business, not the bell's".
  static bool countsOnBell(XprsNotification n) =>
      !(n.source.startsWith('wapp:') && (n.convo?.isNotEmpty ?? false));

  Future<void> record(XprsNotification n) async {
    if (!countsOnBell(n)) return;
    var incoming = StoredNotification.fromNotification(n);
    // Same id = same notification. Replace it in place instead of stacking
    // another copy on top of it -- and carry the OLD row's seen flag and
    // first-seen time onto the replacement. A repeat is not a new event: the
    // wapps re-ingest their backlog on every start, so without this a replay
    // both re-lights the bell and jumps the row to "Today". This makes
    // history.jsonl a second, independent dedupe guard, which matters because
    // the tag guard can lose a write (AnnouncedTagsStore's debounce).
    StoredNotification? prior;
    for (final e in items.value) {
      if (e.id == incoming.id) {
        prior = e;
        break;
      }
    }
    if (prior != null) {
      incoming = incoming.copyWith(
        seen: prior.seen ?? _legacySeen(prior),
        timestamp: prior.timestamp,
      );
    }
    final next = [
      incoming,
      ...items.value.where((e) => e.id != incoming.id),
    ].take(maxItems).toList(growable: false);
    items.value = next;
    _recomputeUnread();
    try {
      await _persistItems(next);
    } catch (_) {}
  }

  /// Mark everything from one source as read — the panel that owns those
  /// notifications was opened, so the bell must agree with it.
  ///
  /// Exact, per row. It used to drag the single global watermark forward to
  /// this source's newest timestamp, which silently marked every OTHER
  /// source's older notifications read too.
  Future<void> markSeenBySource(String source) async {
    await _markSeenWhere((n) => n.source == source);
  }

  Future<void> markAllSeen() async {
    await _markSeenWhere((_) => true);
    // Read in-app = read everywhere: drop the Android shade's event
    // notifications (and with them the launcher-icon dot). One lifecycle —
    // the shade must never disagree with the notification center.
    unawaited(platform.clearSystemNotifications());
  }

  /// Flag every row matching [pick] as seen and persist. No-op when nothing
  /// changes, so a second call (page open then page close) costs nothing.
  Future<void> _markSeenWhere(bool Function(StoredNotification) pick) async {
    var changed = false;
    final next = <StoredNotification>[];
    for (final n in items.value) {
      if (n.seen != true && pick(n)) {
        changed = true;
        next.add(n.copyWith(seen: true));
      } else {
        next.add(n.seen == null ? n.copyWith(seen: _legacySeen(n)) : n);
      }
    }
    // The watermark is still written so a downgrade, or a row this build has
    // not rewritten yet, keeps behaving.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now > _seenMs) _seenMs = now;
    if (!changed) return;
    items.value = next;
    _recomputeUnread();
    try {
      final root = activeProfileRoot();
      await root.createDirectory('notifications');
      await root.writeString(_seenFile, '$_seenMs');
      await _persistItems(next);
    } catch (_) {}
  }

  Future<void> clear() async {
    // Clears the visible history only. Deliberately does NOT touch
    // AnnouncedTagsStore: clearing the list must not re-arm announcement of
    // events that replay on the next start.
    items.value = const [];
    unreadCount.value = 0;
    unawaited(platform.clearSystemNotifications());
    try {
      final root = activeProfileRoot();
      await root.delete(_itemsFile);
      await root.delete(_seenFile);
    } catch (_) {}
  }

  @visibleForTesting
  void reset() {
    _sub?.cancel();
    _sub = null;
    _initialised = false;
    _seenMs = 0;
    items.value = const [];
    unreadCount.value = 0;
    ProfileService.instance.activeProfileNotifier.removeListener(_reload);
  }

  void _reload() {
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final root = activeProfileRoot();
      final seenRaw = await root.readString(_seenFile);
      _seenMs = int.tryParse((seenRaw ?? '').trim()) ?? 0;
      final raw = await root.readString(_itemsFile);
      if (raw == null || raw.trim().isEmpty) {
        items.value = const [];
        unreadCount.value = 0;
        return;
      }
      final loaded = <StoredNotification>[];
      for (final line in const LineSplitter().convert(raw)) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            loaded.add(StoredNotification.fromJson(decoded));
          }
        } catch (_) {}
      }
      loaded.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      items.value = loaded.take(maxItems).toList(growable: false);
      _recomputeUnread();
    } catch (_) {
      items.value = const [];
      unreadCount.value = 0;
    }
  }

  Future<void> _persistItems(List<StoredNotification> list) async {
    final root = activeProfileRoot();
    await root.createDirectory('notifications');
    await root.writeString(
      _itemsFile,
      list.map((n) => jsonEncode(n.toJson())).join('\n'),
    );
  }

  /// A row written before the `seen` flag existed: fall back to the watermark
  /// this build still maintains, so the upgrade shows what the old build did.
  bool _legacySeen(StoredNotification n) =>
      n.timestamp.millisecondsSinceEpoch <= _seenMs;

  void _recomputeUnread() {
    unreadCount.value = items.value
        .where((n) => !(n.seen ?? _legacySeen(n)))
        .length;
  }
}
