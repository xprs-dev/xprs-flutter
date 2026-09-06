---
name: rns-reachability-use-diagnostic-endpoints
description: "To judge whether two phones can reach each other over Reticulum, use /api/rns/haspath, /api/rns/route, /api/xprs/whois — never a chat screenshot or grey dot. Reticulum DOES route between NAT'd phones via public hubs."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fff23a0f-37c9-40e8-971e-0bd96c106e69
  modified: 2026-09-05T14:45:13.417Z
---

Max (2026-09-05, angry after I reported a phone↔phone internet test as "blocked by CGNAT" from screenshots): "Read about reticulum, in particular our own internal documentation… do a proper investigation."

**Why:** `docs/reticulum-connections.md` and memory [[rns-path-requests]] say plainly: **Reticulum routes fine between two NAT'd phones via the public hubs** — the "broken inbound / change network / dedicated hardware" conclusion was explicitly marked WRONG. And "a display list is not a reachability list": the mesh screen, an empty chat, a grey presence dot are NOT evidence about reachability. I used exactly those and drew the wrong conclusion.

**How to apply — the tools that "answer in one second what a screenshot cannot":**
- `GET /api/xprs/whois?call=X1WATT` → the callsign's current lxmfDest (+ declared, sightings). `remote_api_service_io.dart:1579`.
- `GET /api/rns/haspath?dest=<32hex>` → `{has: true/false}`.
- `GET /api/rns/route?dest=<hex>` → next hop, via, hops, ageMs (null = no path).
- `GET /api/rns/status` → up, mode, identity, lxmfDest, lxmfPropDest, passive, annRate.
- `POST /api/rns/requestpath {dest}` pulls a path (passive announce-flooding between different networks often fails; path requests restore it). `POST /api/rns/lxmf/send`, `POST /api/rns/lxmf/pull` (store-and-forward).

Bar for "it works" (docs/reticulum-connections.md): a **delivered line** — sender `RNS/lxmf: delivered to <dest> over a direct link`, recipient `Courier: delivered a carried packet from <call> (via rns)` + the bubble on screen — not a screenshot of an empty thread. Related: [[chat-is-xprs-only-no-lxmf-in-core-path]], [[reticulum-needs-no-inbound-ports]].
