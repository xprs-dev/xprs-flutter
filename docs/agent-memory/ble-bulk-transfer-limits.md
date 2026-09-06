---
name: ble-bulk-transfer-limits
description: BLE5 carries XPRS control traffic fine but bulk file transfer stalls; and a stuck Android scanner needs a phone reboot
metadata: 
  node_type: memory
  type: project
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-26T10:22:06.004Z
---

Measured on the bench 2026-08-26 with TANK2 fully offline (see `docs/ble5.md` §9):

- **Control traffic over BLE works**: announces, gossip, RNS path requests,
  callsign resolution (`bearer: "ble"`). TANK2 brought Reticulum up by itself
  with "no bootstrap reachable — up on Bluetooth only".
- **CORRECTION (2026-08-26).** The bulk finding below was measured on the WRONG
  LANE: I was pushing Reticulum resources through the BLE advert channel. BLE5
  carries XPRS; file bytes ride the MSP bulk lane, which is built and measured
  at 27 kB/s. See [[ble5-carries-xprs-not-reticulum]]. The RNS-over-advert
  numbers below say nothing about whether BLE file transfer works.
- **`SCAN_FAILED_APPLICATION_REGISTRATION_FAILED` (error code 2) needs a phone
  reboot.** A Bluetooth toggle, an app force-stop, and both together all fail.
  Symptom is `scanResults: 0` with adverts going out cleanly. The app retries
  every 2 s forever with no backoff and never reports the radio as deaf.

**Why:** it is tempting to assume "transports are interchangeable" end to end
because the architecture says so — it is true for packets and not yet true for
files, and an app update is 47-61 MB.

**How to apply:** never claim a BLE file transfer works without seeing the file
arrive on the far side. When a phone seems to be "in an empty room", check
`scanResults` vs `rxEmitted` in `/api/ble/status` first, and reboot it before
debugging anything else. Related: [[validate-ble-changes-on-device]].
