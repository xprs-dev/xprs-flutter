---
name: closed-group-chat-rendering
description: "Closed groups (X5) end to end — where membership is decided (core, never the wapp), how an invite reaches a cellular-only peer, and the traps hit on 2026-09-06"
metadata: 
  node_type: memory
  type: project
  originSessionId: fff23a0f-37c9-40e8-971e-0bd96c106e69
  modified: 2026-09-06T14:44:44.918Z
---

Closed groups as wired on 2026-09-06 (chat wapp 0.7.18+, app 1024040+). Max's
rule, said three times that day: **discovery, membership, connecting, relaying
are CORE. The chat wapp renders what the core hands it and puts the core's
answers into words. Never a membership decision in a wapp.**

Where each decision lives now:
- **Receive door** — `WappDelivery.groupAuthorMayPost` (wapp_delivery.dart): a
  `t:message` to an `X5…` group from an author not on the verified roster is
  not handed to any wapp. Counter `refusedGroupAuthor`, reported on
  `/api/xprs/history`. Fails open when the roster can't be verified (§26.7).
- **Send door** — `XprsPublisher.mayAir` + `publishWire` refuse a post to a
  group this station isn't in (every caller, API included); `hal_xprs_send`
  returns **-2** so the wapp can say "post here once you accept". The wapp's
  old `xgroup_may_post` send gate is gone.
- **Inviting someone who only has Reticulum** needed three core fixes, all in
  `_sendToMembers` / `XprsIngest.reticulum`: (1) a `t:moderate` is addressed
  to the callsigns it NAMES (an invitee is `invited`, not a member, and was
  skipped); (2) the invitee also gets the group's `t:identity` + stored acts
  (§26.8 bootstrap — announces don't cross hubs, and a newcomer's roster
  otherwise holds only itself so its own acceptance has no target); the
  archive is `flush()`ed first because it flushes every 20 s and a grant sent
  seconds after `create` found nothing to bundle; (3) the internet lane now
  feeds `t:moderate` to `XprsGroups.offer()` like the radio lane — it only
  archived them, so the live roster moved only after a restart.
- **Admin in the roster**: `create()` self-grants + self-accepts; a same-`ts`
  grant/accept pair sorts grant-first in `_replay` (the id tie-break dropped
  the acceptance at random).
- **Rooms**: a group you belong to gets a chat room on `core.groups`; the wapp
  opens an X5 from Find as the `#`group room (never a 1:1 with the address);
  member panel = `hal_xprs_group_roster` rendered verbatim.

Traps worth the memory:
- `grep` here is **ugrep**, which silently returns nothing for
  `rns_service.dart` (11k lines, valid UTF-8) — use `grep -a`. Cost me an hour
  of "definitions that don't exist".
- The archive is SQL + a 20 s pending queue: `/api/xprs/history` is not a
  "received?" probe within 20 s.
- The log ring on a busy node scrolls in seconds — capture right after an act.
- `pgrep -f`/`pkill -f bundle/xprs` match the shell's own command line; use
  `pidof xprs`.
- The `moderate wire — …:refused` verdict lines right after `create` are the
  self-grant/accept (no targets but me), not the grant you just sent.
- `xprs_archive_test` "reticulum lane … monitor untouched" had been failing on
  main since 0c57aee (2026-09-04); assertion updated to that commit's intent.

See [[transport-fixes-live-in-the-core-bearer]],
[[fix-at-the-receive-point-not-the-display-end]],
[[chat-wapp-is-xprs-only-local-default]].
