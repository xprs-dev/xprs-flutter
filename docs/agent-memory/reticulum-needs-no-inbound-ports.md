---
name: reticulum-needs-no-inbound-ports
description: "Never propose port-forwarding/UPnP — Reticulum exists to connect NAT'd peers via outbound links through transports"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-24T07:19:23.084Z
---

Max's correction (2026-08-24) after I tried UPnP/port-forwarding to make two NAT'd devices reach each other: **"THERE IS NO NEED FOR THIS AT ALL ON RETICULUM."**

**Why:** Reticulum is used in this project specifically to solve NAT traversal. Both leaves dial OUT to transport hubs; announces propagate paths; links (and LXMF on top) are then routed THROUGH the transports. Two phones on different networks talk via the hub mesh with zero inbound ports.

**How to apply:** For cross-network XPRS traffic, use the LXMF/link lane through the public hubs (wappSendTo / lxmf, path via announces), never inbound TCP. My earlier "leaf↔leaf dead" finding applied only to the raw wapp-ANNOUNCE broadcast lane on community hubs — links are the designed answer. Read `docs/performance.md` and the project's reticulum docs before touching this area. Related: [[gossip-and-super-archivers]], [[read-performance-md-before-coding]].

**Also (2026-08-24):** public hubs FILTER — only identity announces and directed messages reliably cross. Cross-internet XPRS must be directed (wappSendTo/LXMF), never broadcast; standardized as XPRS.md §36.12.1. `lib/services/reticulum/rns_service.dart` contains a binary byte — grep it with `-a` or it silently matches nothing.
