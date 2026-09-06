---
name: read-esp32-md-before-firmware
description: "Read xprs-esp32/docs/esp32.md before any firmware work — it is the measured list of traps that already cost days"
metadata:
  node_type: memory
  type: feedback
---

Max (2026-08-25): "read the ESP32.md to avoid common coding mistakes and save our time" — said while reviewing a firmware plan, the same instruction shape as [[read-performance-md-before-coding]].

**Why:** `/home/brito/code/xprs/xprs-esp32/docs/esp32.md` (~1400 lines) is the firmware's paid-for knowledge, and every rule in it is a bug someone already found the slow way. Planning firmware without it means re-deriving them.

**How to apply:** Read it BEFORE writing or planning ESP32 code. The load-bearing ones:
- **Heap is the binding constraint, check it first** — the T-Dongle sits at ~14 KB free / 4 KB largest block, and one Reticulum hub socket costs 12,676 B. Heap failures never look like memory (`wifi:m f null` = the driver can't allocate a keepalive frame).
- **Pin blocking work to core 1** — `xTaskCreatePinnedToCore(...,1)`; plain `xTaskCreate` leaves NO affinity, which is not the same thing.
- **SD/FatFs:** never write from a receive path; drain in ~2 s bursts; the store needs its own mutex; read the active segment through the handle writing it; `fsync()` or lose the whole file on power cut. `CONFIG_FATFS_LFN_HEAP=y` must be in THAT board's `sdkconfig.defaults` (segments are `seg_<10 digits>.bin`, over 8.3).
- **A store does not need an SD card** — the M5Stack pattern gives ~14 MB of wear-levelled FAT on internal flash.
- **PSRAM is not headroom** — a task stack, DMA buffer, or anything touched with the flash cache off can never live there, and it costs internal RAM.
- **Measuring:** opening the serial port REBOOTS the board (~28 s, M5Stack ~45 s), so measure over the network with no serial open; identify a board by MAC/callsign, never by port (three bench boards log under the same `xprs:` tag); check the build timestamp in `/api/diag`, not `version.txt`, to know whether a flash landed.
