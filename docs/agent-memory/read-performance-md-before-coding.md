---
name: read-performance-md-before-coding
description: "Max requires docs/performance.md to be read and honoured before any code change in xprs-flutter, and its rules cited in the plan"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-21T10:31:34.898Z
---

Before writing or planning any code change in `xprs-flutter`, read
`docs/performance.md` and state explicitly how the change honours it. Max
rejected a plan that was otherwise complete because it had not done this.

**Why:** the doc is not general advice — it is a list of specific regressions
that already shipped in this app (a multi-hour freeze, a pegged core, 50MB of
log heap, 17-44% idle CPU), each with the mistake that caused it. Max treats it
as "the list of errors you tend to commit and must avoid". Reviewing it changed
real decisions: it caught that `MeshService._sweepTimer` is a bare
`Timer.periodic` that Android throttles in a pocket, which would have made a new
poll silently stop on exactly the device it was written for.

**How to apply:** the rules that bind most often are §8.1 (plugin/MethodChannel
work — BLE5, WiFi-Direct — must stay on the root isolate; no new isolates on
instinct), §8.2/§8.5 (background-survivable work rides the native `BgService`
heartbeat via `AndroidForegroundService.addTickListener`, never a bare
`Timer.periodic`), §6.5 (a poll interval is a battery setting; justify it as
cost-per-hour-screen-off, fire once then settle), §3.3 (the log ring is 2000
lines — never log per-frame on a live path), and §4/§4.1 for measurement
(release build only, `am force-stop` first, settle 5 min, ≥5-min windows,
verify the screen is actually off). Baseline before the change so the comparison
is measured rather than remembered.

Related: [[validate-ble-changes-on-device]]

**2026-08-24, second correction — this became real:** funnel code written without reading performance.md put a per-beacon curve verify + per-packet sqlite on the main isolate; the C61 wedged at 1.5GB/170% CPU ("When the app is OOM, humans are not able of using it and this defeats the whole overall goal"). Fixed in ee74a2f (quota-peek before verify, RAM debounce before sqlite, throttle before probe). The rule is literal: READ the file before writing ANY receive-path/periodic code, and check every new hot-path step against §4.2 (cheap checks first) and §8.5 (the checklist). A slow leak of ~2MB/min = a wedged phone the same day.
