import 'dart:convert';

/*
 * hal_permissions — which HAL surface a wapp is allowed to reach.
 *
 * Until this file existed, a wapp claimed a route by IMPORTING ITS SYMBOL.
 * `WappEngine._bindImports` offers every HAL import to every module and
 * swallows the failure when the module does not declare one:
 *
 *     for (final imp in allImports) {
 *       try { builder.addImports([imp]); } catch (_) { }
 *     }
 *
 * So the wasm's own import table was the access-control list, written by
 * whoever compiled the wasm. Any wapp that added `hal_lxmf_recv` received
 * every private message on the device -- `_lxmfInbox` has no recipient test --
 * and could raise its own notifications for them. That one is gone outright:
 * a permission is the wrong answer to a door that should not exist, and the
 * core delivers a message on the event bus instead. `hal_ble_scan_read` hands
 * out raw radio frames, with `from` and `rssi`, which is a transport opinion a
 * wapp is not supposed to have at all (docs/architecture.md §1) -- that one is
 * a copy taken after the receive door, so it is gated rather than removed.
 *
 * That is tolerable while every wapp in the tree is ours. It stops being
 * tolerable the moment somebody else's wapp can be installed, and designing
 * for that is the reason to do this before there are many of them rather than
 * after.
 *
 * ── The rule ─────────────────────────────────────────────────────────────
 * Anything that touches a communication path is GATED. A wapp reaches it only
 * if its `manifest.json` names the permission, which makes the claim explicit,
 * reviewable before install, and visible in one file rather than implied by a
 * symbol table nobody reads.
 *
 * Ungated, and deliberately so: the content APIs and the event bus. A wapp
 * hands the core CONTENT (`hal_xprs_send`) and is handed content back
 * (`hal_event_*`, `hal_msg_*`). Neither names a radio, so neither is a
 * transport. That pair is the whole intended surface, and a wapp built to it
 * needs no permission at all.
 */

/// A capability a wapp must declare in `manifest.json` to be granted.
class HalPermission {
  /// Read and write Reticulum datagrams directly.
  static const rnsRaw = 'transport.rns.raw';

  /// Open arbitrary TCP sockets (the APRS-IS uplink is the only user).
  static const socket = 'transport.socket';

  /// Send and receive NOSTR events and relay DMs.
  static const nostr = 'transport.nostr';

  /// The whole heard-traffic spool and the live monitor ring.
  static const spool = 'archive.read';

  static const all = [rnsRaw, socket, nostr, spool];
}

/// Every gated import, by the name the wasm imports it under, mapped to the
/// permission that unlocks it. An import absent from this map is ungated.
///
/// Keyed on the import NAME rather than the Dart symbol, because that is what
/// a wasm module actually asks for and what a reviewer reads in a manifest.
const Map<String, String> kGatedImports = {
  // NO RADIO ENTRY, because there is no radio import left to gate.
  //
  // `ble_scan_*` and `ble_advertise*` are deleted from the host. A permission
  // was the wrong answer to them: gated or not, they handed a wapp every frame
  // this radio heard — with the advertiser's address and its RSSI, for traffic
  // addressed to other people — and let it put arbitrary bytes on the air under
  // a subtype the core had to GUESS from their content. Through them a wapp ran
  // a second digipeater and aired frames under other stations' callsigns.
  //
  // NO LXMF ENTRY either. `lxmf_send`/`lxmf_send2` named one Reticulum
  // destination, which is a wapp choosing a transport — and choosing the one
  // that cannot reach a station standing in the same room.
  //
  // A wapp says what it wants said with hal_xprs_message. What it hears
  // arrives on the event bus. Neither is gated, because neither is a lane.

  // Reticulum, raw.
  'rns_available': HalPermission.rnsRaw,
  'rns_recv': HalPermission.rnsRaw,
  'rns_broadcast': HalPermission.rnsRaw,
  'rns_send_to': HalPermission.rnsRaw,
  'rns_pull': HalPermission.rnsRaw,

  // Arbitrary sockets.
  'socket_open': HalPermission.socket,
  'socket_send': HalPermission.socket,
  'socket_recv': HalPermission.socket,
  'socket_close': HalPermission.socket,
  'socket_status': HalPermission.socket,

  // NOSTR, including decrypted relay DMs.
  'nostr_event_recv': HalPermission.nostr,
  'nostr_subscribe': HalPermission.nostr,
  'nostr_unsubscribe': HalPermission.nostr,
  'nostr_post': HalPermission.nostr,
  'relay_dm_recv': HalPermission.nostr,
  'relay_dm_fetch': HalPermission.nostr,
  'relay_dm_send': HalPermission.nostr,

  // The spool and the live ring: everything this station ever heard.
  'xprs_history': HalPermission.spool,
  'xprs_traffic': HalPermission.spool,
  'xprs_stations': HalPermission.spool,
};

/// Whether [importName] may be bound for a wapp holding [granted].
///
/// Default is REFUSE for anything gated. A wapp that declares nothing gets
/// the content APIs and the event bus, which is the surface a well-behaved
/// wapp is supposed to be written against.
bool halImportAllowed(String importName, Set<String> granted) {
  final needs = kGatedImports[importName];
  if (needs == null) return true;
  return granted.contains(needs);
}

/// The permissions a wapp package declares, or an empty set.
///
/// Read from `manifest.json`'s `permissions` array. Anything unparseable is
/// an empty grant rather than a full one: a manifest that cannot be read is
/// not a manifest that consents.
/// `"conversations": "wapp"` in `manifest.json`: the wapp keeps its own
/// conversation history (through `hal_sqlite_*`) and the host's conversation
/// stores are a render cache it repaints -- nothing is persisted host-side.
/// Absent or anything else: the host persists, as before.
bool wappOwnsConversations(String? manifestJson) {
  if (manifestJson == null || manifestJson.isEmpty) return false;
  try {
    final m = jsonDecode(manifestJson);
    return m is Map && m['conversations'] == 'wapp';
  } catch (_) {
    return false;
  }
}

Set<String> declaredPermissions(String? manifestJson) {
  if (manifestJson == null || manifestJson.isEmpty) return const {};
  try {
    final m = jsonDecode(manifestJson);
    if (m is! Map) return const {};
    final p = m['permissions'];
    if (p is! List) return const {};
    return p.whereType<String>().toSet();
  } catch (_) {
    return const {};
  }
}
