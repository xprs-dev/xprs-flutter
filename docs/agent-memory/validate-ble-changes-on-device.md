---
name: validate-ble-changes-on-device
description: "How to observe and prove BLE/mesh behaviour on the C61 bench, including airing a test XPRS frame from this laptop"
metadata: 
  node_type: memory
  type: project
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-21T10:31:50.169Z
---

Max expects BLE/mesh fixes to be *proven on the bench*, not argued for. The
observation path that works:

```sh
adb forward tcp:3458 tcp:3456
curl -s localhost:3458/api/status | jq '.mesh'        # neighbors, gatt counters, scheduler
curl -s "localhost:3458/api/log?n=400"                # note: ?n=, not ?limit=
adb shell dumpsys bluetooth_manager                   # OS ground truth: scanner map, advertiser map
```

`dumpsys bluetooth_manager`'s "GATT Scanner Map" is authoritative for whether
the app is actually scanning — but **grep it with `awk '/GATT Scanner Map/,/GATT
Client Map/'`**, not `grep -A<n>`: the per-entry stats blocks are long enough
that a fixed `-A` truncates the listing and hides `com.xprs.app` entirely. I
misread it that way once and briefly concluded the app never scanned at all.

When no ESP32 station is on the bench (they are often unplugged), air a test
XPRS frame from this laptop's `hci0` instead — that is what `tool/xprs_air.dart`
is for. BlueZ here refuses `RegisterAdvertisement` for anything needing extended
advertising, so **the manufacturer payload must fit legacy: ≤24 bytes**
(31 − 3 flags − 4 header), i.e. 2 bytes of marker/subtype plus ~22 of wire.
`t:ping f:X9T mail:3` fits; a full `t:observation` beacon does not. A
`bluetoothctl` session held open works when the Dart tool's own registration
fails:

```sh
{ echo 'menu advertise'; echo 'manufacturer 0xFFFF 0x3E 0x58 <hex bytes>'; \
  echo 'back'; echo 'advertise on'; sleep 400; } | bluetoothctl
```

Frames aired this way are heard and decoded by the phone, and they exercise the
poll — but they have no GATT presence, so `dialable` stays empty and anything
gated on dialling a station cannot be validated without real hardware.

Related: [[read-performance-md-before-coding]]
