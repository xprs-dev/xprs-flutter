---
name: gatt-msp-lane-already-exists
description: The GATT/MSP 1:1 session lane is already built — reuse it; and GATT is retired on every ESP32
metadata:
  type: project
---

Directed BLE traffic between two Android peers has a complete 1:1 lane already:
`MeshSessionManager` (`lib/services/mesh/mesh_custody.dart:77`), MSP protocol in
`mesh_session.dart` (magic `0x4D 0x01`), dialled by `MeshTransferScheduler`.
Sending one XPRS wire to one callsign is two existing calls:

    MeshStore.instance.offer(target: CS, sender: SELF, wire: bytes, ours: true);
    MeshTransferScheduler.instance.pokeFor(CS);

guarded by `BleService.meshCanTakeCustody(CS)`. `MeshStore.pendingFor` is
type-agnostic — it never inspects the wire. Sessions are deliberately **never
bonded**.

**Why:** Max corrected me for proposing to build a sender — "Don't reinvent,
this was already coded and is available". The lane exists because broadcasting
1:1 traffic on the advertising channel jams it past ~10 BLE devices in range.

**How to apply:** anything addressed to one station should take this lane, not
`publishWire`. The gate that currently limits it to `t:message` is
`mesh_custody.dart:490`.

**On ESP32: GATT is retired fleet-wide.** Both the T-Deck and the T-Dongle run
tinynimble (HCI only — no ATT, no connections); `gatt_mesh.c` is not even
compiled. Reviving it means switching BLE hosts, which was measured on the
T-Deck at **min-ever 16 bytes**. And `docs/ble5.md:245`: an ESP32 in a GATT
session does not scan. See [[ble5-carries-xprs-not-reticulum]].
