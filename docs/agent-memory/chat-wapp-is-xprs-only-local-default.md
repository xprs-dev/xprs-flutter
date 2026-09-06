---
name: chat-wapp-is-xprs-only-local-default
description: "Max's rules for the chat wapp: XPRS messages only (no LXMF/NomadNet anything), #LOCAL is the only default room, no pre-created rooms, one sqlite DB per conversation via hal_sqlite"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fff23a0f-37c9-40e8-971e-0bd96c106e69
  modified: 2026-09-04T09:26:40.488Z
---

The chat wapp accepts **XPRS messages only**. Max rejected a plan that kept
`lxmf:` conversation ids, LXMF names and the NomadNet channel: *"Stop including
lxmf things, that is not wanted, we only accept XPRS messages on the chat wapp."*
A row without a callsign sender is dropped at the door.

**Only `#LOCAL` exists by default.** Do not pre-create rooms for closed groups
(X5 callsigns), open groups (`#NEWS`) or callsigns (X1): *"Don't create fixed
primary keys for #NEWS and the X5 or X1 callsigns. The only room created there by
default is #LOCAL."* A room row appears when a message arrives for it or the
user opens/starts one.

**Why:** the 2026-09-04 session found the Local room empty because the wapp
stored nothing itself — membership ×3, dedup ×5, history only in a host DB the
wapp could not read. Max's decision: *"don't care about history, I want a great
simplified chat architecture"* — clean slate, no migration.

**How to apply:** one sqlite DB per conversation through `hal_sqlite_*`
(circles is the precedent), `messages.mid` PRIMARY KEY as the only dedup, one
inbound door (`room_admit`), host `ConversationStore` is a memory-only render
cache (`"conversations":"wapp"` manifest flag). `hal_kv` keeps only `chan`.
Plan: `~/.claude/plans/please-look-into-the-quirky-reef.md`.

Related: [[fix-at-the-receive-point-not-the-display-end]], [[ble5-carries-xprs-not-reticulum]]
