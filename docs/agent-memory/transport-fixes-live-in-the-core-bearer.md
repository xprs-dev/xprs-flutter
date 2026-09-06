---
name: transport-fixes-live-in-the-core-bearer
description: "Max's standing rule, restated 2026-09-05 — every transport fix goes into the core's ONE existing send/receive path (publisher fan-out, bearer, PacketGateway), never into a wapp and never as a parallel path"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fff23a0f-37c9-40e8-971e-0bd96c106e69
  modified: 2026-09-04T22:20:53.289Z
---

Max (2026-09-05, approving the BLE-stack-restart fix): "all implementation must be done on the core level, not inside the wapp. There is a unified way to transmit and receive packets, so don't create a new one and improve the existing one."

**Why:** the app's whole architecture is one door out (`XprsPublisher._fanOut` → bearer → `Ble5Bus.advertiseFrame`/`XprsLan.send`) and one door in (`Ble5.kt onScanResult`/LAN socket → `PacketGateway.receive`). Earlier wapp-side transports (hal_ble_advertise, a wapp digipeater) were deleted in the 2026-09-02 cleanup precisely because they drifted from the core's rules. A "fix" that adds a second path recreates that.

**How to apply:** when a bearer misbehaves (dead advertising set, socket died, radio off), repair the bearer's own lifecycle inside that path and surface it on the existing event channel and `/api/status`. Do not add a new event channel, a new sender, or wapp-side workarounds. Related: [[fix-at-the-receive-point-not-the-display-end]], [[gatt-msp-lane-already-exists]].
