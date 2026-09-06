---
name: durable-per-group-store-not-selfheal
description: "Max's fix for closed-group membership lost on restart — a durable per-X5-group sqlite, NOT archiver/self-heal machinery"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fff23a0f-37c9-40e8-971e-0bd96c106e69
  modified: 2026-09-06T17:46:59.581Z
---

When closed-group membership is lost after a mere **restart** (not a wipe
reinstall), the fix Max wants is the simple, durable one: **each X5 group's
state (its key + `t:moderate` acts) lives in an sqlite store** so the roster
survives a restart — mirroring how each chat conversation already has its own
sqlite. Reuse `XprsGroupKeys`'s existing `xprs_groups.sqlite3`.

**Why:** the roster (`XprsGroups._acts`) is memory-only and was scavenged back
from the general archive, where a cellular member's group `t:identity` (key)
was never persisted (bound in memory only, refused by the declaration gate).

**How to apply:** do NOT reach for §26.8 archiver/admin re-fetch, self-heal, or
`concernsUs` changes when the cause is a plain restart — Max called that
"complicating the situation." Persist the state; the roster then never
collapses. Distinguish clearly: `adb install -r`/`launch-android.sh` keep app
data (a restart — membership MUST survive); only `adb uninstall` wipes (a
reinstall — losing membership is normal, and the group stays discoverable via
its owner/archivers, a separate later concern).

Also: a wipe reinstall still leaves the group **list/roster recoverable** because
the owner and archivers hold the group's info (§26.8/§26.9). But that is the
reinstall path, not the restart bug. See [[closed-group-chat-rendering]].
