---
name: gossip-and-super-archivers
description: "Max's names for the archiver federation — \"gossip\" (reachability exchange) and \"super-archivers\" (internet-scale servers)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-23T20:13:59.304Z
---

Max named the XPRS federation vocabulary (2026-08-23), used in XPRS.md §36:

- **Gossip** — the archiver↔archiver exchange of REACHABILITY (never content): who was heard, where, when. Three layers: L1 declared (`t:mailbox hold:`, authoritative), L2 visit history (last ~100 distinct radio-side archivers per callsign, never expires), L3 live sightings (TTL'd). Validity rules: signer-credited, radio-only for L2, per-source quotas, byte budgets.
- **Super-archivers** — `serve:archive,super`: full internet servers (or satellites/off-planet stores — store-and-forward is delay-tolerant by design) keeping gossip for every active callsign and serving thousands of asks/min. Humble nodes (ESP32, phones) keep need-to-know gossip and ask a super-archiver on a miss.

**Why:** APRS-IS parity without a centre; ESP32s cannot hold the world.
**How to apply:** use these exact names in spec, code, and replies. Related: [[the-app-is-xprs-not-aurora]].
