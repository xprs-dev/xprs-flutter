/*
 * xprs_outbox — what this station sent, and what became of it.
 *
 * Nothing in the core could name a message it had sent. `sendLxmf` returns a
 * bool, the LXMF hash is computed and discarded, and `_lxmfRetries` deletes
 * its row at the exact moment the answer becomes interesting -- so
 * "delivered" and "gave up" were indistinguishable from outside, and
 * `lxmfPendingFor(dest) == 0` meant either. A receipt could arrive naming a
 * message and there was nothing to apply it to.
 *
 * So the tick a person sees was asserted by the WAPP: chat invented `am:`, a
 * second identifier competing with §5, and a private `?ACK <am> d|r` wire
 * that appears nowhere in the specification. This is what replaces it.
 *
 * Keyed on the §5 identifier, which is derived from the packet and never
 * transmitted, so the copy that went out over Reticulum and the copy that
 * went out over BLE are one row -- and a `t:receipt r:<id>` names it exactly
 * (§13.7.1).
 *
 * Deliberately small: an id, who it was for, a state and a timestamp. It is
 * not a message store. The words are the wapp's; this is only their fate.
 */
import '../log_service.dart';
import '../receive/wapp_delivery.dart';

/// §13.7's states, plus the two local ones that precede any answer.
class TxState {
  /// Handed to the bearers; no answer yet.
  static const sent = 'sent';

  /// `s:ack` — it reached a device.
  static const delivered = 'delivered';

  /// `s:read` — it was opened.
  static const read = 'read';

  /// Ordered, so a late `ack` cannot walk `read` backwards.
  static const _rank = {sent: 0, delivered: 1, read: 2};
  static bool advances(String from, String to) =>
      (_rank[to] ?? -1) > (_rank[from] ?? -1);
}

class TxRecord {
  TxRecord(this.id, this.peer, this.state, this.ms);
  final String id;
  final String peer;
  String state;
  int ms;
}

class XprsOutbox {
  XprsOutbox._();
  static final XprsOutbox instance = XprsOutbox._();

  /// Bounded: a pocket, not a ledger. Oldest goes first, and losing the
  /// oldest row costs a tick on a message from hours ago.
  static const int maxRows = 500;

  final Map<String, TxRecord> _rows = {};

  static int recorded = 0;
  static int advanced = 0;
  static int unknown = 0;

  /// Remember that we sent [id] to [peer].
  void noteSent(String id, String peer) {
    if (id.isEmpty) return;
    if (_rows.containsKey(id)) return;
    if (_rows.length >= maxRows) _rows.remove(_rows.keys.first);
    _rows[id] = TxRecord(id, peer.toUpperCase(),
        TxState.sent, DateTime.now().millisecondsSinceEpoch);
    recorded++;
  }

  /// A verified receipt arrived for [id]. [state] is `ack` or `read`.
  ///
  /// Publishes the change so the wapp that drew the bubble can draw a tick on
  /// it, instead of asserting a state the core never confirmed.
  void noteReceipt(String id, {required String state, String? peer}) {
    final to = state == 'read' ? TxState.read : TxState.delivered;
    final row = _rows[id];
    if (row == null) {
      // No local record of sending it: the row aged out of this pocket, or the
      // outbox is empty because the app restarted (it is session-lived). The
      // tick a person SEES lives in the wapp's persistent per-message status,
      // not here, so a VERIFIED receipt must still reach it -- otherwise a read
      // receipt for an older message updates nothing and the bubble is stuck on
      // one check forever. The wapp ranks the status monotonically, so a late
      // `ack` arriving after a `read` cannot walk the bubble backwards.
      unknown++;
      if (peer != null && peer.isNotEmpty) {
        LogService.instance
            .add('XPRS: $id is $to ($peer) — status only, no outbox row');
        WappDelivery.instance.deliverStatus(id: id, peer: peer, state: to);
      }
      return;
    }
    if (!TxState.advances(row.state, to)) return;
    row.state = to;
    row.ms = DateTime.now().millisecondsSinceEpoch;
    advanced++;
    LogService.instance.add('XPRS: $id is $to (${row.peer})');
    WappDelivery.instance.deliverStatus(id: id, peer: row.peer, state: to);
  }

  String? stateOf(String id) => _rows[id]?.state;

  int get length => _rows.length;

  static void debugReset() {
    instance._rows.clear();
    recorded = advanced = unknown = 0;
  }
}
