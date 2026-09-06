---
name: ble5-carries-xprs-not-reticulum
description: "BLE5 is the XPRS lane; Reticulum is the internet path. File bytes ride the MSP bulk lane, never RNS resources over adverts."
metadata: 
  node_type: memory
  type: project
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-26T13:34:45.123Z
---

**BLE5 carries XPRS.** One extended advertisement, one packet, ≤250 bytes
(248 on the ESP32), subtype `0x58`, never fragmented. **Reticulum is the
internet path.** They are different lanes and must not be mixed.

How a file moves between two stations (XPRS.md §25.2.2, "A file transfer, on
the wire"):

1. `t:command cmd:file file:<sha> [off:]` on the **advert channel**
2. `t:result code:202`
3. bytes on the **MSP bulk lane** — `4D 01`, FILE_OFFER/ACCEPT/CHUNK/WIN_ACK/
   FILE_DONE/FILE_OK, over a short auto-paired GATT session
4. `t:result code:200`, aired only after the receiver's own sha check

MSP is BUILT and validated (`docs/mesh.md` M2): 5 MB phone→phone at 27 kB/s.
What is missing is only the XPRS ask in front of it — §37's status table says
so in as many words.

**"Auto-paired" GATT means auto-dialled, NOT bonded.** Characteristics are
plain (`Ble5.kt:1019`, `:1030`), there is no `createBond()`, and `Ble5.kt:935`
says "this transport must pair with nobody, ever". A pairing dialog is a
stop-work bug — it once came from the `ble_peripheral` plugin, now refused on
BLE5 devices.

**Why:** I spent a day trying to force RNS resources through the BLE advert
channel — fixing MTU negotiation, TTLs and path-request throttles that had
nothing to do with the problem. Max: "BLE5 communication is pure XPRS, has
nothing to do with RNS or reticulum."

**How to apply:** before touching a BLE transfer, decide which lane it is. If
it is bytes between two stations, it is MSP + an XPRS bracket, and both already
exist — reuse them. Related: [[ble-bulk-transfer-limits]] (whose conclusion
that BLE bulk is unusable was WRONG for this reason).
