---
name: the-app-is-xprs-not-aurora
description: "The product's only name is XPRS; \"Aurora\" AND \"geogram\" are retired and must not be used in speech, code, or docs"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-23T12:18:12.010Z
---

Max renamed the product: there is no more "Aurora", there is only **XPRS** (2026-08-23).

**Why:** One product, one name — same reasoning as the Indexer/Archiver merge and the one-port rule (4242): a second name for the same thing is a standing source of confusion.

**How to apply:** Never call the app Aurora in replies, commit messages, code, comments, or docs. New user-visible strings say XPRS. Legacy identifiers that still say `aurora` (package name, data dir `~/.local/share/aurora`, binary path) are migration surfaces, not licence to keep the name alive — renaming them needs a data-dir migration for installed devices. Related: [[read-performance-md-before-coding]].

**2026-08-25 — `geogram` is retired the same way.** Max: "don't use geogram as a name any longer, rename to xprs". It is the ESP32 tree's pervasive prefix: 65 component directories under `common/`, ~158 files, plus C identifiers (`geogram_ble_peer_t`, `geogram_mesh_*`, `geogram_wifi_*`). Rename them.

**The exception that matters, in BOTH renames:** a name that is on the wire or in flash is an IDENTIFIER, not a label. NVS namespaces (`"xprsrns"`, `"rns"` — these hold identity keys, so renaming mints a new Reticulum identity and the station becomes a stranger to every peer), RNS destination app names (`xprs.wapp` vs the dongle's `xprs.chat`), the FTP default user, and HKDF strings like the frozen `aurora-*-v1`. Migrate deliberately or leave them; never sweep them along with a mechanical rename.
