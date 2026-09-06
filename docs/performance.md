# Performance

How XPRS burns CPU and memory, what we fixed, how to measure it, and what is
still on the table. Written after a day that started with the app frozen solid
for hours on a phone and ended with it idling at 8% of a core.

Everything here is measured, not assumed. Where a number appears, the method
that produced it is given, because **the wrong method produces confident
nonsense** — see [Measurement discipline](#measurement-discipline).

---

## 1. The architecture, in CPU terms

XPRS runs a full Reticulum node, a NOSTR relay/engine, a BLE mesh and a WASM
wapp runtime inside a Flutter app. Almost all of that used to sit on the **UI
isolate**. It doesn't any more:

| Isolate | Owns | Spawned by |
|---|---|---|
| `main` | UI, wapp engines, LXMF/files/relay subsystems, all the sqlite stores except the NOSTR feed | Flutter |
| `rns-transport` | RnsTransport: announce validation, dedup, path table, transit forwarding, rebroadcast, passive governor | `RnsTransportClient.spawn` (`rns_transport_engine.dart`) |
| `rns-crypto` | Every hot Curve25519 op (verify / sign / derive / ECDH / keygen), keypair cache, bounded queue | `_CryptoWorker` (`rns_crypto.dart`) — one per isolate that uses RnsCrypto, so there are normally two |
| `nostr-engine` | Public-relay firehose: WS receive, decode, verify, `nostr_feed.sqlite3`, like/reply tallies | `NostrClient.spawn` (`nostr_engine.dart`) |
| `i2p` (opt-in) | The I2P node | `i2p_worker.dart` |

Two things follow from this and are easy to forget:

1. **Main-isolate metrics can look perfectly clean while a worker burns a
   core.** The task monitor only measures main. A worker at 100% shows up as
   *zero* stalls and *zero* task CPU. This actually happened — see §3.2.
2. **Radios stay on the root isolate.** BLE5 and WiFi-Direct are plugin
   (MethodChannel) bound and cannot move; there is no
   `BackgroundIsolateBinaryMessenger` anywhere in the tree. Anything that needs
   them bridges raw bytes over ports. That is why the transport engine registers
   the owner's sockets/radios as *external* interfaces rather than owning them.

---

## 2. Telemetry — read this before profiling anything

All of it lands in the in-app log ring, served by `GET /api/log`. None of it
needs a debug build.

| Line | Source | Tells you |
|---|---|---|
| `perf: main isolate stalled ~Nms` | `main.dart` 500ms heartbeat | The UI event loop blocked for N ms. Steady state should be **zero**. |
| `perf: cpu tasks total …` | `TaskMonitorService.startCpuSummary` | Per-task **main-isolate** CPU, ranked, every 60s. |
| `perf: crypto-worker edVerify=… x25519Gen=… edSign=…` | `RnsCrypto.drainCryptoStats` | Curve25519 ops per minute **by type**. The composition is the diagnosis (see §3.4). |
| `perf: nostr-engine seen=… stored=… reactions=… profileLookups=…` | `NostrRelayHub.drainEventStats` | Relay firehose volume + how much sqlite it is provoking. |
| `perf: rns-transport announces/s=… paths=… passive=…` | `RnsService` | The announce flood the transport engine is chewing. |
| `perf: <task> tick took Nms` | `TaskMonitorService.reportSuccess` | Any monitored tick over 48ms. |
| `vmService` in `GET /api/status` | `main.dart` + `LogService.vmServiceUri` | The Dart VM service URI **with its auth token**. |

**Why `vmService` is pinned in `/api/status`:** when the app wedges, live isolate
stacks are the only way in, and the URI scrolls out of both logcat and the log
ring within minutes on a busy node — gone exactly when you need it. It is now
always one request away.

### Getting live isolate stacks / heaps

```sh
adb forward tcp:13456 tcp:3456
URI=$(curl -s http://127.0.0.1:13456/api/status | python3 -c "import json,sys;print(json.load(sys.stdin)['vmService'])")
PORT=${URI#http://127.0.0.1:}; PORT=${PORT%%/*}
TOKEN=$(echo "$URI" | sed "s|http://127.0.0.1:$PORT/||;s|/$||")
adb forward tcp:14990 tcp:$PORT
# then talk JSON-RPC to ws://127.0.0.1:14990/$TOKEN/ws :
#   getVM, getStack, getMemoryUsage, getAllocationProfile, pause/resume
```

`getStack` on a paused isolate is the poor-man's profiler and it found two of
the bugs below. **The CPU profiler (`getCpuSamples`) is compiled out of our
debug builds** and returns "Profiler is disabled"; `setFlag('profiler', true)`
reports success but still yields zero samples. Don't burn time on it.

**A profiled isolate showing 0 frames while its thread burns 100% CPU means it
is inside a native FFI call** (sqlite3, wasmtime) — the Dart profiler cannot see
those frames. That signature is itself the clue.

---

## 3. Fixed: what was actually wrong

### 3.1 The freeze (`rns_crypto.dart`)

The app hard-froze for hours: main thread pegged, one DartWorker at 100% whose
**TID rotated**, heap climbing, event loop dead.

Cause: `ed25519Verify` was doing `Isolate.run` **per verification**, serialized
through a cap-1 semaphore with an **unbounded waiter queue**. Per-verify isolate
spawn/teardown churned the main isolate (hence the rotating worker), and the
backlog held key/message copies alive (hence the heap → GC spiral).

Then, with verifies offloaded, live stacks caught main *inside* `ed25519Sign`'s
per-call keypair derivation, and then inside `x25519Generate` — the responder's
ephemeral keypair for **every inbound link request**.

Fix: **one persistent `rns-crypto` worker isolate** for all of it, keypair cache
by seed, bounded pending map. Inbound verifies shed under backlog (fail closed —
a forged signature can never pass); our own ops queue with backpressure.

> **Rule: never `Isolate.run` per item on a hot path.** The spawn/teardown cost
> lands on the caller and an unbounded backlog is a memory leak with extra steps.
> Use one long-lived worker + a bounded queue.

### 3.2 The pegged core with nothing to show for it (`nostr_engine.dart`)

A DartWorker sat at 100% while *every* counter said idle. Invisible to the Dart
profiler because it was inside native sqlite. Three causes, all **work redone
forever**:

- **`_syncMyFollows()` ran on every 400ms tick**: a sqlite query for our kind-3
  contact list, then a re-parse of every `p` tag in it (contact lists routinely
  carry thousands). The dedup guard suppressed only the outbound *message* —
  never the work. Now gated on the stored event: the hub flags it dirty when a
  new kind-3 of ours actually lands.
- **Profile lookups cached only hits.** Every author whose kind-0 never arrives —
  most of a public firehose — was re-queried against sqlite on every tick,
  forever. Now misses are remembered too (5-min retry), and lookups per tick are
  bounded.
- **Reaction receipts were persisted for the entire kind-7 firehose** (a
  regression introduced the same day): one unbatched INSERT per inbound reaction,
  *ahead of the rate cap*, for rows nobody would ever read. Now persisted only
  for posts we actually track — exactly the ones the UI shows.

> **Rule: cache the miss, not just the hit.** A cache that only remembers
> successes re-does the failure forever, and failures are the common case on a
> public network.

### 3.3 The log ring held ~50MB (`log_service.dart`)

Allocation profiling found ~50MB of heap in ~2,200 giant strings. The 2,000-line
ring retained full announce dumps, and profile announces embed **base64 avatars**
— single lines ran tens of KB (UTF-16 for anything with an emoji). That standing
heap kept old-space GC churning: the residual ~1s stalls after the isolate
migration. Lines are now capped at 512 chars with an elided-byte marker.
Reclaimed ~300MB RES.

### 3.4 The idle-node CPU: a keypair we threw away (`rns_link.dart`)

Screen-off CPU sat at 17–44% of a core on an *idle* node. The crypto counters
gave it away by their **composition**:

```
perf: crypto-worker x25519Gen=37 edGen=37 x25519Shared=29 edSign=33 edVerify=16
                    ^^^^^^^^^^^^^^^^^^^^^ identical counts → paired → a full keypair mint
```

~37 link handshakes/minute — peers across the network querying this phone's
relay index, and the log showed most answered `relay: answered REQ -> 0
event(s)`. Each handshake cost **four Curve25519 scalar multiplications** in pure
Dart.

One of the four was pure waste: the per-link Ed25519 keypair's **private half is
never used**. The proof is signed with the *identity* key (`rns_link.dart`
`buildProof`); the ephemeral `_edPub` only ever goes onto the wire. We minted a
full keypair per link to produce a key we immediately discarded.

Fix: share one ephemeral Ed25519 public key across links, rotated every 10
minutes so it stays short-lived rather than a permanent cross-link identifier.
The **X25519 pair stays fresh per link** — it is the ECDH half and reusing it
would destroy forward secrecy.

**Screen-off CPU: 17–44% → 8% of a core.**

### 3.5 Smaller, still real

- **Image cache**: Flutter's default is 100MB / 1000 images — desktop-sized. The
  launcher's carousel feeds it full-resolution network photos. Capped to 32MB /
  100 on Android+iOS (`main.dart`).
- **Wapp SVG icons were re-read from disk on every build** (a platform-channel
  round trip per tile, per frame — 700ms build frames while dragging the app
  sheet). Cached and prewarmed after the scan.
- **discoF subscription leak**: the NOSTR discovery fetch created a subscription
  every 3s and never unsubscribed. The filter set grew forever and every inbound
  event paid an O(subs) match. TTL-reaped at 30s.

---

## 4. Measurement discipline

**This section exists because ignoring it produced a confidently wrong
conclusion.** Mid-investigation, a 45-second A/B "showed" the background chat
wapp cost 78% of a core. Proper 5-minute windows: chat running **17%**, chat
stopped **18%**. Chat costs essentially nothing. The 45s windows had landed on
bursts.

Rules:

1. **App CPU is bursty. Use ≥5-minute windows for any CPU claim.** Anything
   shorter is noise. Announce floods, DHT replication and relay queries arrive in
   clumps.
2. **Measure screen-OFF for battery claims,** and *verify* the screen is actually
   off — the human may have woken the phone:
   ```sh
   adb shell dumpsys power | grep -o "mWakefulness=[A-Za-z]*"   # want: Asleep
   ```
   Screen-on adds ~5% raster + GPU purely from the carousel animating. That is
   not a bug; it is a screen being on.
3. **Read process CPU and per-thread CPU in ONE device-side command.** Iterating
   `/proc/$PID/task/*` over adb takes long enough that the process window and the
   thread windows no longer line up, and the totals stop reconciling.
   ```sh
   adb shell "P1=\$(awk '{print \$14+\$15}' /proc/$PID/stat)
     for t in /proc/$PID/task/*; do echo \"A \$(basename \$t) \$(cat \$t/comm) \$(awk '{print \$14+\$15}' \$t/stat)\"; done
     sleep 300
     P2=\$(awk '{print \$14+\$15}' /proc/$PID/stat)
     for t in /proc/$PID/task/*; do echo \"B \$(basename \$t) \$(cat \$t/comm) \$(awk '{print \$14+\$15}' \$t/stat)\"; done
     echo \"PROC \$P1 \$P2\""
   ```
   Ticks are 100/s; `delta*100/(seconds*100)` = % of one core.
4. **A/B by turning things off.** `POST /api/wapp/stop {"wapp":"chat"}` is the
   cleanest lever the app has. Just do it over long windows.
5. **Thread names matter.** `.xprs.aurora` is the platform/main thread,
   `1.raster` is Flutter's rasteriser, `DartWorker` are isolate threads (the VM
   pool reuses them, so a name does not identify an isolate), `mali-*` is the GPU
   driver.

### 4.1 Measure a CLEAN process, or measure nothing

Every one of these produced a wrong number that I believed for a while.

6. **`force-stop` before you measure. Stopping the wapps is not enough.** Background
   services keep running, and worse, the debug API leaves wreckage behind:
   after a few `POST /api/wapp/stop` + `/start` cycles, a `DartWorker` sat at
   **~105% of a core and stayed there with every wapp stopped**. Only a full
   `am force-stop` cleared it. So a measurement taken after A/B-ing wapps through
   the API is measuring the leak, not the app.
   ```sh
   adb shell am force-stop com.xprs.app
   adb shell pidof com.xprs.app        # must print nothing
   adb shell am start -n com.xprs.app/.MainActivity
   ```
7. **Never quote CPU from a `--profile` build.** It has the VM service, an
   unoptimised-ish AOT, and observatory overhead. A profile build read **106%**
   where the release build on the same code, same phone, same window read **5.8%**.
   Profile builds are for *finding* a hot isolate, never for *quantifying* one.
8. **Let it settle.** Boot is a storm — announce flood, NOSTR history replay,
   sqlite backfill, wapp seeding. Give it **5 minutes after launch** before the
   measurement window starts, or the number is the startup cost, not the idle cost.
9. **A wapp's tick time is NOT its cost.** The task monitor reports
   `wapp.bg.messages=103ms(0.2%)` — that is only what the tick burned on the main
   isolate. The work a wapp *provokes* through the HAL (a relay fetch, a profile
   subscription, a sqlite write) lands in **other isolates** and is invisible in
   that line. A wapp can read 0.2% and still be the reason a `DartWorker` is
   pegged. Attribute by bisecting with `force-stop`, not by reading the tick.
10. **A pegged isolate with ZERO Dart frames is inside native code.** `getStack`
    across every isolate returning nothing, while a `DartWorker` burns a core, is
    the fingerprint of **FFI — usually sqlite**. The Dart profiler cannot see it.
    Do not conclude "the profiler shows nothing, so nothing is wrong".

### 4.1.1 The wapp-page CPU leak — mostly fixed, not fully (2026-07-12)

Opening and closing ONE wapp page took an idle phone from 8% of a core to 50%,
permanently, screen off. Every user who opens a wapp hit it.

**Cause: a wapp's NOSTR subscriptions outlived its engine.** The engine is
disposed and recreated on every page open/close (the page takes the engine over,
then hands it back). `WappEngine.dispose()` reclaimed subprocesses and file
handles but not subscriptions, so each cycle left one live in the hub forever —
still re-querying relays, still paying a **secp256k1 Schnorr verify per event**.
Chat made it acute by subscribing to bare group names as tags (`t:NEWS`), i.e.
the public relays' `#news` firehose.

**How it was found** — the method matters more than the bug:

1. Process at 109%, one `DartWorker` at ~104%, `getStack` empty on every isolate.
   The empty-stack fingerprint says *native/FFI*, which pointed at sqlite. **That
   was a red herring.**
2. **Pause each isolate in turn and watch the process CPU.** Pausing
   `nostr-engine` dropped it 109% → 6%. Nothing else mattered. This is the single
   most useful trick in this file: it names the culprit in one minute, without a
   profiler.
   ```python
   rpc('pause', {'isolateId': iso['id']}); measure(); rpc('resume', …)
   ```
3. `getCpuSamples` on *that* isolate (profile build, `setFlag profiler=true`):
   all of it in `_BigIntImpl._binaryGcd` / `modPow` — signature verification, not
   sqlite.

Measured on C61, release, screen off (verified), 7-minute windows:

| | idle | after one page open/close |
|---|---|---|
| before | 8.1% | **50.1%** (persistent) |
| after `dispose()` closes the subs | 6.0% | 25.3%, decaying to 17.6% |

**Still open.** The subscription leak was the main mechanism but not the whole of
it: a page cycle still leaves CPU elevated. Remaining suspects: other per-engine
host resources `dispose()` does not reclaim, and the re-query burst each resumed
subscription pays on start.

### 4.2 The battery-drain patterns to look for

The two real drains found so far were both **a cheap call in a hot loop**, not an
expensive algorithm:

- **A HAL call that does more than it says.** `hal_nostr_profile` reads a cache
  *and subscribes to the peer's kind-0*. Calling it every tick for every peer
  whose name was missing asked the host to re-fetch a profile that was never
  coming, ~40×/minute, forever — all of it landing in the NOSTR engine isolate.
  Fixed by throttling to once a minute. **A cosmetic value never deserves a hot
  loop.**
- **Polling on a timer nobody chose.** Feed/relay polls default to seconds because
  that is what feels responsive while developing. On a phone in a pocket, the
  screen is off and nobody is reading the feed: a poll interval is a battery
  setting, not a freshness setting. See §6.5.

Rule of thumb before adding any periodic work: *what does this cost per hour with
the screen off, and who is awake to see the result?*

---

## 5. Build & device traps (each of these cost real time)

- **`adb uninstall` WIPES app data.** The identity survives (`identity-backup.json`
  in shared storage → "Restore <callsign>" card on next launch), **wapp data does
  not**. Do not reach for uninstall to resolve an install conflict.
- **The CI/release build is signed with the release key.** A debug APK cannot
  update it (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). Build a **release-signed**
  APK instead and it updates in place, data intact.
- **versionCode**: debug builds are `278` (from `pubspec.yaml`), the CI release is
  `21541+` → `INSTALL_FAILED_VERSION_DOWNGRADE`. Pass
  `--build-number=NNNNN` (higher than installed).
- **Profile builds are now release-signed** (`android/app/build.gradle.kts`), so
  they update an installed release in place *and* carry the Dart VM service at
  release-grade AOT speed. **This is the build to profile with** — debug numbers
  are distorted by JIT (~45MB of extra heap in `Instructions`/`Code`/`ICData`
  alone).
- **`cd android` inside a shell persists across commands.** `build/` then resolves
  to `android/build/` and the APK looks "missing" while Flutter cheerfully reports
  it built.
- **`adb monkey` injects a random tap** after launching. Use
  `am start -n com.xprs.app/.MainActivity`.

---

## 6. Open ideas, roughly by value

### 6.1 Native crypto (the big one)

The remaining ~90 crypto ops/min (x25519Gen + x25519Shared + edSign + edVerify)
are *inherent* to answering link handshakes — with **pure-Dart curve math**, tens
of ms each. `cryptography_flutter` swaps in platform BoringSSL/Conscrypt behind
the identical `cryptography` API: same algorithms, same wire bytes, typically
10–100× faster. It would collapse essentially all remaining crypto CPU and make
the whole shed/budget apparatus mostly unnecessary.

Against it: it adds a native dependency, and the package header states the design
principle "*All pure Dart, no native binaries*" (chosen for portability —
desktop, web, and wire-compat confidence). This is an **architecture decision, not
a patch** — hence flagged here rather than taken.

If adopted: keep the pure-Dart path as the fallback (`cryptography` already does
this), and verify wire compatibility against the Python reference before shipping.

### 6.2 The handshake tax — SOLVED by connectionless probes (NPD)

*This section was an open question. It now has an answer, kept here because the
reasoning generalises.*

We were answering strangers' relay queries — 98 times out of 98 with **zero
events** — and paying a full Curve25519 link handshake for each.

The fix is not to refuse the queries (peers legitimately fetch our posts and
profile that way). It is to answer them **without a link**, and to answer "I have
nothing" with **silence**:

**NPD — NOSTR Probe Datagram** (`reticulum-dart/lib/src/util/npd.dart`): a
connectionless PLAIN Reticulum packet carrying a query encrypted to the target's
**NOSTR npub**.

The insight that makes it free:

| | key material | can the ECDH be cached? |
|---|---|---|
| Reticulum link | **ephemeral** per link | **No** — 2 scalar mults + a signature, *every query, forever* |
| NPD | **long-term** (our nsec × their npub) | **Yes** — one secp256k1 mult per peer, *ever* |

After first contact with a peer, an exchange is symmetric AES only: **zero
asymmetric crypto**. And a node holding nothing sends **no packet at all**.

Design points worth keeping in mind:

- **Silence is the signal.** A reply *implies* the peer has data. Honest cost: a
  dropped packet is indistinguishable from "nothing" — acceptable because these
  queries re-run on the feed's refresh cycle, so a lost probe costs freshness,
  never correctness.
- **The cleartext header is deliberate** (`magic/ver/type/senderPub/replyDest/nonce`):
  traffic stays classifiable on the wire while its *contents* stay encrypted.
- **Encrypt-then-MAC, over the header too.** AES-CBC is malleable, and the header
  carries `replyDest` — without a MAC over it, an attacker could aim our reply at
  a victim and turn every probe into an amplification vector.
- **A nonce is mandatory**: the transport dedups by packet hash, so two identical
  probes would otherwise be silently dropped. The reply *echoes* it, which is how
  an answer finds its waiting query with no per-peer state.
- **Capability-negotiated** (`RelayCap.probe` in the relay announcement) so old
  nodes keep getting links and interop is preserved with no timeout guessing.
  **Leaves advertise it too** — a leaf still answers queries about its own posts,
  and is the node that can least afford handshakes.
- **NOT for private mail.** Static-key ECDH has no forward secrecy (the same
  property NIP-04 DMs already have). Fine for queries about *public* NOSTR data;
  that is exactly why LXMF is out of scope.

Also fixed alongside: `RelayNode._accept` / `_acceptDhtLink` did **no link-id
dedup** and ran *ahead* of the transport's packet dedup, so one peer's single
LINKREQUEST arriving on N interfaces bought **N full handshakes**. Duplicates now
re-send a cached proof (re-calling `buildProof` would sign again).

Measured, two devices, release-grade AOT:

```
perf: npd silent=6 answered=1 replay=2 badmac=0 ratelimited=0
```

`silent` = real inbound queries answered with no link, no handshake, no packet.
On the node whose peer supports probes, link handshakes fell to `x25519Gen=3`/min
and relay REQs served over links dropped to 1.

**Multi-hop through a reference `rnsd` hub: PROVEN.** This was the one assumption
the design rested on that could not be checked by reading our own code — the
intermediaries are Python RNS, not us. Tested with C61 on home Wi-Fi
(`192.168.178.0/24`) and TANK2 on a phone hotspot (`172.20.10.0/24`), mutually
unreachable at IP level, so every packet between them had to traverse a public
hub:

```
C61   RNS: npd tx req to 33603ff5 via tcp:use.inertia.chat:4242 hops=2
TANK2 RNS: npd rx req  from eebc6d47 via tcp:use.inertia.chat:4242 hops=1   <- arrived, MAC ok
C61   RNS: npd rx have from 1b4e5d36 via tcp:use.inertia.chat:4242 hops=1   <- reply came home
C61   RNS: npd answer from 33603ff5
perf: npd silent=1 answered=1 replay=0 badmac=0 ratelimited=0
```

Reference RNS forwards PLAIN by `transport_id` + destination table without
regard to dest type, and does not mangle the payload (`badmac=0` end to end). The
connectionless-SINGLE fallback is **not needed**.

**Still open:** the benefit on the *responder* side only fully arrives as the
network updates — old peers keep opening links until they carry `RelayCap.probe`.

### 6.2.1 The bug this test uncovered: a stale "fastest medium" pin

The multi-hop test could not even start, because C61 could not reach TANK2 by
**any** transport — link, LXMF, or PLAIN. Not a PLAIN problem: a routing bug.

`RnsTransport._identityFastVia` pins an identity to the fastest interface it has
been heard on, so a co-located peer is reached over the LAN even when that one
destination's (lossy, broadcast) LAN announce was missed. The pin was
**permanent**. When a peer *leaves* the LAN, every hub-heard announce was still
rewritten back to `via: lan, hops: 1, nextHop: null` — aiming all its traffic at
a network it had left.

It could not self-heal, because the path-preference rule refuses to replace a
faster-ranked (LAN) entry with a slower-ranked (hub) one: the dead path outranked
the live one **forever**, and the peer stayed unreachable until the app restarted.

Two things kept it invisible:
- the rewrite refreshes `updatedMs`, so the dead path looks *fresh* (`ageMs` of a
  few seconds) — this is what fooled the first diagnosis;
- `existing.via == via`, so it never logs a path transition.

`/api/rns/route` is what exposed it: `via: lan, hops: 1` for a peer on a
different subnet is a contradiction — the phones could not even ICMP each other.
**A `via` that names a medium the peer cannot possibly be on is the signature of
a stale pin.** This is almost certainly the same bug as the original "TANK2 shows
zero devices until the app is killed" report; restart-clears-it is its fingerprint.

Fixed in `rns_transport.dart`: the pin is now **evidence, not a fact** — it
carries a last-heard-on-that-interface timestamp (12-min TTL, comfortably beyond
the 5-min worst-case announce cadence) and a miss counter (4 announces heard on a
slower medium with none on the pinned one). On expiry the paths it pinned are
**actively demoted** (`_demoteIdentityPaths`) — dropping the pin alone is not
enough, precisely because of the rank rule above. A false demote is cheap (traffic
takes the hub: slower, but *working*); a false pin is a black hole. It errs toward
demoting.

Locked by `reticulum-dart/test/path_pin_staleness_test.dart`, which fails on the
pre-fix code and passes after — including the case that must NOT regress: a peer
still on the LAN keeps its fast path despite interleaved hub announces.

> Note on the device evidence: the deploy restarted both phones, which *also*
> clears the pin, so the live LXMF-now-succeeds result does not by itself isolate
> the fix from the restart. The unit test is what discriminates. The remaining
> device check is the self-heal *without* a restart: form the pin on a shared LAN,
> move one phone to another network, confirm it recovers within the TTL/miss
> window.

### 6.3 Cheap wins not yet taken

- ~~**Pause UI-only timers when the app is not visible.**~~ Taken: the status
  bar and the carousel are lifecycle-gated now (`LauncherVisibility`), and every
  `BackgroundService` coalesces its ticks to the power tier (§8.11).
- **`nostr-engine` pushes a relays snapshot every 400ms tick** whether or not it
  changed. Send on change.
- **`RnsService` still owns the LXMF / files / relay / DHT subsystems and ~10
  sqlite stores on main.** After the transport migration the main isolate idles,
  so there is *no measured reason* to move them — recorded here so nobody
  "optimises" it on instinct. Revisit only if a measurement says so.

### 6.4 Explicitly NOT worth doing (measured)

- **Moving background wapp WASM engines to a worker isolate.** The background
  chat wapp's tick costs **0.2–0.3% of main**. Doing this means routing ~114
  main-isolate singleton touchpoints through port bridges *inside the messaging
  path* — a real risk of dropped messages — to reclaim a third of a percent. The
  WASM runtime (`wasm_run`/wasmtime) is synchronous and runs on the calling
  isolate, and the HAL is soaked in `RnsService.instance` (61 references),
  `ProfileService`, `BleService`. Several HAL calls are *synchronously* answered
  from main state (`hal_rns_available`, `nostr_subscribe`, `event_recv`) and have
  no cheap port equivalent. **Don't revive this without new data.**

---

### 6.5 Poll intervals are battery settings, not freshness settings

Every poll interval in this app was originally chosen by how it *felt at a
desk with the app open*. That is the wrong question. The phone spends its life in
a pocket with the screen off and nobody reading the feed, and a poll that runs
"just in case" runs ~8,640 times a day.

What was actually there:

| Poll | Was | Now |
|---|---|---|
| NOSTR discovery-feed fetch (`nostr_relay_hub`) | **every 3 s** | 10 min |
| Reticulum NOSTR relay re-query (`nostr_rns_client`) | every 30 s | 10 min |
| Hero/novelties drain (local buffer, no network) | every 20 s | 1 min |

`kNostrPollInterval` (reticulum-dart, `nostr_relay_hub.dart`) is the one knob.

Two things make the slow interval free of any UX cost, and both are the point:

1. **The `wss` relays PUSH.** A live subscription delivers a post the moment a
   connected relay has it. The polls above are only for the transports that
   *cannot* push (a Reticulum relay is request/response) and for the discovery
   query. Slowing them delays nothing that a relay would have pushed anyway.
2. **Every poll fires once immediately, then settles into the interval.** A cold
   start fills the feed at once; the interval only governs how often we go *back*.
   Get this wrong (timer-only, no immediate call) and a 10-minute interval means
   a blank hero for 10 minutes on first launch.

The general rule, before adding any periodic work: **what does this cost per hour
with the screen off, and who is awake to see the result?**

---

## 7. Current numbers (C61, release-grade AOT, busy public hub + BLE peer)

| | frozen (before) | now |
|---|---|---|
| main-isolate stalls | wedged solid | **0** |
| main thread CPU | ~100% pegged | ~0–7% |
| screen-off process CPU | — | **8% of one core** |
| RES | 890MB, climbing | ~250–300MB, flat |
| `/api/log` during load | dead | alive |

Regressions to watch for, in one command:

```sh
curl -s http://127.0.0.1:3456/api/log?n=800 | grep -aoE 'perf: [^"]*' | tail -20
```

If `main isolate stalled` reappears, or `crypto-worker` shows a paired
`xGen`/`edGen` count again, or `nostr-engine profileLookups` climbs — something
regressed to a pattern documented above.

---

## 8. Adding new work without regressing any of this

Everything above was paid for once. This section is how to not pay for it again.
It is the design half of the file: §1–7 say what went wrong, §8 says how to add a
new subsystem, background task, or wapp so it never joins that list.

### 8.1 New CPU work goes off the UI isolate — decide it up front, not after a freeze

The freeze in §3.1 and the pegged core in §3.2 were both **work on the wrong
isolate that nobody chose to put there** — it landed on `main` because that is the
default and moving it later is surgery. The isolate table in §1 is the shape to
extend, not the shape to fight.

The decision rule, before writing the work:

- **Touches a Flutter plugin / MethodChannel (BLE, WiFi-Direct, path_provider,
  shared_preferences, audio)?** It **must** stay on the root/main isolate — there
  is no `BackgroundIsolateBinaryMessenger` in this tree (§1.2). Bridge raw bytes to
  a worker if the *processing* is heavy, exactly as `RnsTransport` registers the
  owner's sockets/radios as *external* interfaces and the worker only ever sends
  `['tx', label, bytes]` back to main for the actual I/O.
- **Pure CPU (crypto, parsing, sqlite, compression), no plugins?** It belongs on a
  worker isolate. Two idioms already exist — copy one, don't invent a third:
  - **One-shot heavy call inside an existing tick:** `BackgroundService.runOffThread(fn)`
    (= `Isolate.run`) in `services/background_service.dart`. For a *single* offload,
    not a hot path.
  - **A stream of items on a hot path:** a **long-lived worker + bounded queue**.
    This is the §3.1 rule made concrete: never `Isolate.run` per item — the
    spawn/teardown cost lands on the caller and an unbounded backlog is a memory
    leak with extra steps.

> **The worker boilerplate (one shape for all of them).** `ReceivePort` in the
> owner → `Isolate.spawn(entrypoint, port.sendPort, debugName: 'my-worker')` →
> the entrypoint's **first** message back is its own `inbox.sendPort` (the
> handshake) → the owner stores that as its command port and completes a `ready`
> Completer → all later traffic is tagged `List`s, request/response correlated by an
> incrementing int id + `Map<int, Completer>` → register `iso.addOnExitListener` so
> a crash fails the backlog and allows a lazy respawn. Reference implementations:
> `rns_crypto.dart` `_CryptoWorker` (request/response pool with `_shedCap`/`_hardCap`
> back-pressure), `rns_transport_engine.dart` `RnsTransportClient.spawn` (long-lived
> engine + external-interface radio bridge), `nostr_engine.dart` `NostrClient.spawn`.
> All three live in the sibling `reticulum-dart` package.

> **Rule: a worker at 100% is invisible to the main-isolate metrics (§1.1).** When
> you add a worker, add its telemetry line to `TaskMonitorService.startCpuSummary`
> the same day — a `perf: my-worker …/min` counter whose *composition* is a
> diagnosis (the §3.4 win came entirely from reading paired counts). A worker with
> no counter is a core you cannot see burning.

> **Do not move work to an isolate on instinct.** §6.4 is a worked *rejection*:
> moving the background wapp engine off main would route ~114 singleton touchpoints
> through port bridges inside the messaging path to reclaim 0.2%. And §6.3 records
> that `RnsService` keeps ~10 sqlite stores on a *now-idle* main isolate with **no
> measured reason** to move them. Off-isolate is for measured hot CPU, not for tidiness.

### 8.2 Continuous work must survive a suspended phone — the Android background stack

A Dart `Timer` is throttled to near-nothing once Android backgrounds the app, and
the process itself can be killed. Anything that must keep running with the screen
off — a relay answering queries, a download, an APRS-IS mailbox — cannot rely on
Dart timers or on the Activity being alive. The stack that already solves this:

- **A foreground service holds the process up.** `BgService.kt` is a `START_STICKY`
  foreground service (persistent notification on channel `aurora_service`,
  `NOTIF_ID=7001`, `FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE` — the old
  `aurora_bg` channel was deleted because its badge setting was sticky). It
  acquires a `PARTIAL_WAKE_LOCK` (`aurora:bg`), a WifiLock (`aurora:wifi`) and a
  multicast lock, so an asleep device keeps CPU cycles, stays reachable for
  inbound connections, and still hears Reticulum's LAN broadcast discovery.
  **The first two are now tier-dependent (§8.11); the multicast lock is not —
  dropping it makes the phone deaf to its neighbours.** Don't add a second
  foreground service for a new task — hold the existing one.
- **A native heartbeat drives Dart, because Dart timers can't drive themselves.**
  `BgService` posts a `Handler` runnable every `tickMs` (2 s active, 10 s on
  battery, 30 s low — §8.11) that calls `onTick` over the
  `com.xprs.app/bg_service` MethodChannel. Dart side:
  `AndroidForegroundService._onCall` → `BackgroundWappManager.tickAllFromNative()`
  → every `BackgroundService.tickNow()`. **This is why `BackgroundService` has both
  a Dart `Timer.periodic` and a `tickNow()`:** the timer runs foreground, the native
  heartbeat runs background. New periodic work that must survive suspension has to
  ride `onTick`/`tickNow` — a bare `Timer.periodic` you add yourself will silently
  stop in a pocket.
- **The service is ref-counted, not owned.** `AndroidForegroundService` keeps a
  `Set<String>` of holders (`'ble'`, `'mesh'`, `'player'`, …); `hold(reason)`
  / `release(reason)` bring the native service up and down. A new always-on
  subsystem takes its own `hold('myThing')` and releases it when idle — it does not
  start or stop the service directly.
- **Headless from boot.** `BootReceiver` (gated on the `flutter.autoStartOnBoot`
  pref, kept in sync by `syncBootAutostart()`) → `BgService.startFromBoot` →
  `XprsApplication.ensureFlutterEngine()` runs Dart `main()` with **no Activity**.
  One cached engine (`ENGINE_ID = "aurora_engine"`) is reused by the Activity when
  the UI opens (`MainActivity.provideFlutterEngine`, `shouldDestroyEngineWithHost() =
  false`) so opening the app never spawns a second isolate / second BLE stack.
  `NativeBridgeRegistry.attach` binds each native bridge exactly once per engine.

> **Rule: background-survivable work rides the native heartbeat, never a Dart timer.**
> If it must run screen-off, it is a `BackgroundService` (so `tickNow()` reaches it)
> or it holds the foreground service and is driven off `onTick`. A `Timer.periodic`
> is a foreground-only convenience.

> **Rule: cost-per-hour-screen-off is the metric that matters (§4.2, §6.5).** A poll
> interval is a battery setting, not a freshness setting: "every 3 s" runs ~8,640×/day
> in a pocket where nobody is looking. Fire once immediately, then settle into a slow
> interval; let `wss` push handle freshness for anything that *can* push. Before adding
> any periodic work, answer: what does this cost per hour with the screen off, and who
> is awake to see the result?

### 8.3 Reuse the `BackgroundService` template — don't hand-roll a loop

Every recurring task should be a subclass of `BackgroundService`
(`lib/services/background_service.dart`). You get, for free, the four things a
raw `Timer.periodic` does not have and §3–4 proves you need:

1. **`tickNow()`** — so the Android native heartbeat keeps it alive screen-off (§8.2).
2. **TaskMonitor registration** — it appears in `perf: cpu tasks total`, ranked,
   every 60 s, and any tick over 48 ms logs `perf: <task> tick took Nms`. Invisible
   work is unmeasurable work.
3. **The governor** — `TaskMonitorService` tracks a per-task EMA of
   `lastDuration/interval` and auto-pauses a non-critical task that overruns
   `overrunThreshold=0.8` for `overrunWindow=3` consecutive ticks, firing your
   `onPause`/`onResume`. Set `priority: TaskPriority.critical` only for work that
   genuinely must never be paused (it then can't be governed — justify it).
4. **`_runTick()` skips the body while paused but keeps the loop alive** — so a
   paused task resumes cleanly instead of dying.

Recipe: subclass, set `id` / `serviceName` / `priority` / `interval`, implement
`onStart` / `onTick` / `onStop` (and `onPause` / `onResume` if it owns its own
loops or an isolate), then `.start()`. For pure CPU inside the tick, offload with
`runOffThread` (§8.1). Register a one-shot init step through
`BootOrchestrator.instance.register(... mode: BootStart.parallel | sequential)` in
`main.dart` rather than calling it inline — sequential entries run alone in order
(use it only for true ordering constraints like profile-unlock-before-headless-boot);
parallel entries run concurrently with failures isolated. `I2pBackgroundService`
(`lib/services/i2p/i2p_worker.dart`) is the in-repo example of a `BackgroundService`
that also owns a worker isolate — copy its `onPause`/`onResume` stop/restart shape.

### 8.4 Wapps are *called on an interval*, they don't run services — the event-bus pattern

A wapp is WASM sandboxed behind the HAL; it **cannot** register a native callback,
open a socket, or hardcode itself into `BgService`. The host owns the schedule and
the events; the wapp is polled. This is deliberate — it is what lets a wapp run
identically foreground, headless, and from boot without the wapp knowing which.

Two mechanisms, both already built:

- **Cadence is the wapp's to declare, the host's to drive.** A wapp exports
  `module_tick_interval_ms` (default 5000 ms if omitted; `wapp_engine.dart`), read
  **once** at start. The host wraps the wapp in a `_WappBackgroundService` whose
  `interval` is that value, and calls the wasm `module_tick` export each tick —
  foreground via the Dart timer, background via `tickAllFromNative()` →
  `tickNow()`. A headless wapp runs purely through `onTick(): engine.tick(); _drain();`
  with **no UI page**; all `ui.*` outbox messages are ignored in that path, while
  `notify` (forced `scope: both`), `social.note`, `hero.*`, geochat/activity
  archival still happen. So a wapp's periodic work goes in `module_tick`, sized to
  its declared interval — and per §4.2, that interval is a battery setting.

- **Host events reach a wapp as `system.*` topics it subscribes to — the preferred
  pattern for "call me when X happens".** A wapp cannot subscribe to a Dart
  `EventBus` directly (it's WASM). Instead `HostEventBridge` (installed as a boot
  task) subscribes to the host `EventBus` and **republishes** each `AppEvent` onto
  the `WappEventBroker` as a JSON `system.*` topic: `system.app.started`,
  `system.wapp.loaded`, `system.wapp.unloaded`, `system.wapp.crashed`,
  `system.error`. The wapp calls `hal_event_subscribe("system.app.started")`, and on
  its next `module_tick` drains the event from its private broker queue
  (`hal_event_available` / `hal_event_recv`). The broker also fires a
  `WappEventBridgeEvent` on the host `EventBus` so Dart observers can watch the same
  traffic, and it fans wapp↔wapp `publish` out to every subscribed engine's queue
  (cap 1024, drops oldest).

> **Why this shape, not a service the wapp installs.** A wapp lives and dies with
> its engine (which the page open/close cycle disposes and recreates — see the §4.1.1
> subscription-leak that this same isolation caused and forced us to fix in
> `WappEngine.dispose()`). Letting a wapp hold a native service or a live host
> subscription would leak exactly like that, per open/close, forever. Polling on a
> host-owned tick + draining a bounded broker queue means a dead engine leaks
> nothing: the host stops ticking it and the queue is discarded. **Extending
> host→wapp signalling = add a new `system.*` topic in `HostEventBridge`, never a new
> callback into the wapp.**

To make a new wapp run on a schedule in the background: it opts into autostart
(`PreferencesService.setWappAutostart`, some ship autostart-by-default via
`_defaultAutostartWappIds`), which `syncBootAutostart()` reflects into the native
`flutter.autoStartOnBoot` flag; `BackgroundWappManager.startAutostart()` (the single
idempotent entry `PermissionGate.startGatedServices()` calls) then starts a headless
engine for it at boot. The wapp declares its cadence via `module_tick_interval_ms`,
does its work in `module_tick`, and reacts to host events by subscribing to
`system.*`. At no point does it touch the native service.

### 8.5 The one-line checklist for any new periodic/background subsystem

- Plugin-bound? → stays on main, bridge bytes to a worker if processing is heavy.
- Pure heavy CPU? → long-lived worker + bounded queue (never `Isolate.run` per item),
  and add a `perf:` counter for it the same day.
- Must survive screen-off? → `BackgroundService` (rides `tickNow` off the native
  heartbeat) or hold the existing foreground service; never a bare `Timer.periodic`.
- Recurring? → subclass `BackgroundService` for TaskMonitor + governor, don't hand-roll.
- It's a wapp? → cadence via `module_tick_interval_ms`, work in `module_tick`, host
  events via `system.*` topics — the host calls it, it installs nothing.
- Poll interval chosen? → justify it as cost-per-hour-screen-off, fire-once-then-settle.
- Network transfer? → resumable by checkpoint + hash, close idle links, sweep liveness
  on a tick — assume it breaks mid-flight (§8.6).

### 8.6 Never trust the network — resilient transfers and connection hygiene

The network is not a resource you *have*; it is one you *keep re-earning*. A phone
walks between cells, a hub drops you, a peer's socket dies mid-transfer, a Wi-Fi
network vanishes when the screen locks. Any code that assumes a connection stays up
for the length of an operation is a bug that only shows up in the field — never at
your desk on a stable LAN. Design for the connection dying at the worst moment,
because it will.

**Downloads and transfers must be resumable — never restart from zero.**

- **Content-address everything and checkpoint at a fine grain.** A break must cost
  the *chunk* in flight, not the whole file. Reticulum file transfer already works
  this way: `sha256`-addressed, per-segment, with the adaptive window reset per
  segment (see the rock-solid-transfer work) — a dropped link resumes at the last
  completed segment, and the final hash is the integrity proof. New transfer code
  follows the same shape: sized chunks, persisted "have" set, verify-by-hash on
  completion. **Keep what was already downloaded**; re-fetch only the gap.
- **A partial file is state to preserve, not garbage to delete.** On failure, hold the
  bytes and the have-set so the next attempt continues. Deleting a half-download on
  the first error throws away exactly the work the retry needs.
- **Retry with backoff, and treat a stalled transfer as a failure.** A socket that
  stops delivering bytes but never closes ("half-open") is the common real-world
  case — a WiFi-Direct fetch that hangs ~90s while the sender reports done, or a
  BitTorrent peer behind symmetric CGNAT. Bound every read with a stall timeout, tear
  the connection down, and resume from the checkpoint over whatever path is now up.

**Cut connections you are not using — an idle link is not free.**

- **Answer without holding a link where you can.** The §6.2 NPD work is the model:
  strangers' relay queries are answered with a *connectionless* probe and "I have
  nothing" is answered with *silence* — no link opened, nothing to keep alive or tear
  down. Prefer connectionless request/response over a standing connection whenever the
  exchange is short.
- **Close on idle.** A link kept open "in case" costs keepalives, holds crypto/session
  state, and — worse — becomes a **stale path** the transport will keep routing at
  (§6.2.1: a pin to a medium the peer already left made it unreachable by *every*
  transport until restart). When a transfer finishes or a peer goes quiet, close the
  link and drop the path; do not let a dead connection outrank a live one.
- **Every long-lived connection needs a liveness check on a periodic tick.** Ride the
  existing tick (`BackgroundService.onTick` / the native heartbeat, §8.2) to sweep open
  connections: is this link still delivering? last activity within the window? path
  still valid? Cut anything that fails — a periodic "prove you're alive or I close you"
  is cheaper than discovering a black-holed link mid-transfer. This is the same
  TTL+miss-counter discipline that fixed the stale pin: treat reachability as
  *evidence with an expiry*, not a fact.

> **Rule: assume the transfer will break and the peer will vanish.** Resumable by
> checkpoint, integrity-checked by hash, idle links closed, liveness swept on a tick.
> Code that only works while the network stays up doesn't work.

### 8.7 The three shapes that put a phone into swap (2026-08-26)

An OOM on the C61 came down to three faults, none of which is an expensive
algorithm and all of which read as free at the call site. They are now
machine-checked — see §8.8.

**A page fetched to be counted.** The catch-up poller asked

```dart
XprsArchive.instance.query(types: ['message'], limit: 1000).length
```

`query()` builds a Map per row with thirteen entries **including the whole
wire**, so this materialised up to a thousand of them to learn one integer —
once a minute, on the main isolate, forever, on the device whose archive is the
largest on the network. `.length` is what made it invisible: the expensive part
is the call it is attached to. `XprsArchive.countOf()` asks SQL for the number.

> **The general form**: any `.length` / `.isEmpty` on the result of a query, a
> directory walk or a network listing. If the answer is a number, ask for the
> number.

**A question re-asked after the answer stopped changing.** The same count ran
every sweep for the life of the process, though it fed a FIRST-RUN decision —
once the archive holds a conversation it never stops holding one. Latch
one-shot state and stop paying for it. A poll that cannot change its own answer
is pure heat.

**A guard that logs every occurrence of something that happens in a loop.** The
NOSTR engine's `runZonedGuarded` sent one port message to main per error. The
comment above it correctly names the error as expected and survivable — but
dart:io produces it in a tight loop: **800 identical lines spanning 56 ms, about
14,000 a second, sustained**. Each one was an allocation on main, a port
message, and a row in the log ring.

Two lessons, and the second is the one that generalises:

- An error that repeats is **one fact**, however often it repeats. Coalesce in
  the handler: same message inside N seconds → count it, report once.
- **A ring bounded in ROWS is not bounded in cost.** It still pays an
  allocation and a timestamp per line, and — worse — a component in an error
  loop pushes every other line out, so the one buffer that could explain the
  fault is full of the fault. `LogService.add` now collapses consecutive
  duplicates into a counted row.

**How it was found, which is the reusable part.** `perf:` counters looked clean
(§7's command showed only ordinary wapp ticks). The fault was visible only in
the raw log:

```sh
curl -s 'http://127.0.0.1:3456/api/log?n=800' \
  | python3 -c "import sys,json,collections,re; \
      L=json.load(sys.stdin)['lines']; \
      c=collections.Counter(re.sub(r'^\S+\s+','',l)[:60] for l in L); \
      print(len(L)); [print(n,m) for m,n in c.most_common(5)]"
```

**If one message is most of the log, that is the bug** — count the lines before
reading them. Measured on the C61 across the fix: PSS 295 MB → 230 MB, swap
**106 MB → 0.6 MB**, and a log with history in it again.

> Caveat kept deliberately: the after-figures came from a six-minute-old
> process and the before-figures from one up for hours, so the swap number is
> the trustworthy half of that comparison. A soak settles the rest.

### 8.8 The guard runs these rules for you

`tool/arch_guard.dart` grew a **cost** section, so the shapes above fail a
commit instead of being remembered:

| rule | what it refuses |
|---|---|
| `no-page-fetch-to-count` | `.query(…).length` / `.isEmpty` — counting by materialising rows |
| `no-sub-minute-poll` | `Timer.periodic` under a minute — §6.5's battery setting |
| `no-store-work-in-ui-layer` | raw SQL in `lib/ui`, `lib/launcher`, `lib/wapp/geoui` (modules named `*_db`/`*_store`/`*_archive` are exempt — they own the store) |
| `no-whole-file-read` | `readAsBytes()` / `readAsBytesSync()` — the whole file on the heap (§8.9) |
| `no-scan-for-one-row` | looping a `recent()` page to find one key — the store has an index (`byMid`) |
| `no-unbounded-select` | `SELECT` with no `LIMIT` outside a `*_db`/`*_store`/`*_archive` owner |

`no-store-work-in-ui-layer` covers all of `lib/wapp/**` since 2026-08-31: the
11,330-line `wapp_page.dart` sat outside the old `lib/wapp/geoui/` glob, which
is exactly where a dead ranking cache and a per-build 300-row `SELECT` survived
unseen.

`no-whole-file-read` baselined **18** existing calls when it was added. That is
the point of the baseline, not a failure of it: each is now a recorded decision
rather than something nobody has looked at. Two are worth someone's time —
`disk_folder.dart:219` serves a whole file to a whole-file fetcher, and
`rns_service.dart:9804/9983` read a disk file straight into `putBytes`.

Same contract as the architecture rules: baseline in `tool/arch_baseline.txt`
so only NEW violations fail, `// arch-ignore: <rule-id> <reason>` for a
deliberate exception, and `./tool/install-hooks.sh` puts it on pre-commit.
Verified by re-introducing the exact line that caused this OOM: the guard fails
the commit and prints why.

**When you find the next one of these, add the rule the same day.** A lesson in
a document is a lesson someone has to have read; a lesson in the guard is one
they cannot skip. The rules that pay are the ones matching a shape that *reads
as free* — those are precisely the ones review does not catch.

### 8.9 A file is not a photo: four places that read one whole (2026-08-26)

Moving a 56 MB app update between two phones found the same shape four times in
code that was correct for the thing it was written for — a chat attachment.

| where | what it did | why it was fine before |
|---|---|---|
| `MeshBulkSpool.readAt` | cached the WHOLE archive entry in `_cacheBytes` to serve one window | a photo is 200 kB |
| `MeshBulkSpool.verify` | `sha256.convert(f.readAsBytesSync())` | same |
| `MeshBulkSpool.completeInbound` | read the finished file into memory, then wrote it into sqlite as a BLOB | same |
| `UpdateNative.verifyFile` | `sha256.convert(await f.readAsBytes())` on the downloaded APK | it was never true; this one shipped |

Four times 56 MB, on the phone with 3.8 GB of RAM, on the path whose whole
purpose is a large file.

**The rule: a size that is fine for the median case is not a design.** Ask what
the biggest legitimate input is, and if the answer is "a file the user chose" or
"whatever we ship", the code has to stream. All four now do — chunked at 64 KiB,
and the receiver renames the finished `.part` into place rather than copying it
through memory into a database.

**The corollary that bit hardest**: `MediaArchive` stores content as a **sqlite
BLOB**. That is a fine store for thumbnails and a bad one for artifacts, and
"content-addressed store" reads like it will do for both. A large file gets a
path and a rename; only small content gets a row.

### 8.10 A log line per parcel is a log ring that only logs itself

`BLEQueue` wrote one line per parcel, per receipt, per send. During the 56 MB
transfer the transfer's own progress lines were gone from a 500-line window
within minutes, leaving `Received parcel 1 for IE` repeated to the horizon. The
one buffer that could explain the transfer was full of the transfer.

This is §8.7's third shape again — *a ring bounded in ROWS is not bounded in
cost* — and it is worth restating because it did not arrive as an error loop
this time. It arrived as ordinary, reasonable, per-event logging on a path that
became hot. **Any per-event log line is a bet that the event is rare.**

The fix is the same one the `perf:` lines already use next door: count, and say
what the counters did once a minute, and only when they did something.

```
perf: ble-queue parcels=812/40 receipts=3/12 msgs=2/1 retransmit=0 timeout=0
```

What keeps a line of its own is what somebody can act on: a message dropped
after its retries, a peer muted, a parse failure. Per-message narration lives
behind a flag for when you are chasing one transfer.

**How to spot it before it costs an afternoon**: the §8.7 recipe — count the log
lines before reading them. If one message is most of the window, that is the
bug, whether or not anything is failing.

### 8.11 The power tier: what the phone is allowed to cost right now (2026-08-31)

The always-on half of this app was proven and the battery half was a set of
constants — all of them sized for the screen being on, all of them still paid
for at 3 a.m.: a 2 s native heartbeat, a standing `PARTIAL_WAKE_LOCK`, a
`WIFI_MODE_FULL_HIGH_PERF` WifiLock, one BLE scan mode, a GPS stream at best
accuracy with no distance filter, and a hub-retry loop every 30 s forever.

`lib/services/power_state.dart` publishes ONE tier, and everything else keys off
it:

| tier | when | heartbeat | wake lock | WifiLock | BLE scan | `BackgroundService` ticks |
|---|---|---|---|---|---|---|
| `active` | screen on / foreground | 2 s | standing | `FULL_HIGH_PERF` | BALANCED | declared |
| `idle` | background, on charger | 2 s | standing | `FULL_HIGH_PERF` | BALANCED | declared |
| `battery` | background, discharging | 10 s | 3 s per tick | `FULL` | LOW_POWER | ×5 |
| `low` | background, under 20% | 30 s | 3 s per tick | `FULL` | LOW_POWER | ×10 |

Inputs: `battery_plus` (charging + level), the lifecycle observer, and a NATIVE
screen broadcast (`BgService.screenReceiver` → `power.screen`) — a headless
engine gets no lifecycle events at all, so the broadcast is the only screen
signal it ever sees.

Four rules this design is bounded by, none of them negotiable:

1. **The scan changes MODE, never state.** Suspending the scan during a GATT
   link once measured 10-of-10 delivered down to 0-of-10 (docs/ble5.md §4).
   LOW_POWER looks for ~0.5 s every 5 s instead of ~2 s of every 3; the misses
   are what store-and-forward and the courier re-transmits already absorb
   (docs/mesh.md §2).
2. **Tier changes are rare on purpose.** Android throttles an app to roughly
   five scan starts per thirty seconds, and a scan-mode change restarts the
   scan. `PowerState.minDwell` holds a demotion for 60 s so battery-percent
   noise cannot spend that budget. The promotion back to `active` is immediate
   — somebody is waiting for it.
3. **Delivery in flight is exempt.** `holdActive(reason)` pins the device at
   `active` cost: a GATT link up, a mesh dial in progress. A loop that must
   keep its cadence in every tier declares `tierThrottled: false` (or a
   `critical` priority) — courier pumps, custody re-airs, transfer schedulers.
4. **The radio never waits for the heartbeat — the wapp drain does.** A scan
   result or socket data wakes the process on its own, so nothing is *missed*
   by a slower tick: the frame is ingested and stored when it lands. What the
   tick drives is `_WappBackgroundService.onTick` → `engine.tick()` + `_drain()`,
   which is where a headless wapp turns a received message into a notification.
   So the honest figure is: **a background message can surface up to one tick
   late — ~10 s in `battery`, ~30 s in `low`** (`active`/`idle` are unchanged at
   2 s). That is the deliberate trade, and it is the first thing to shorten if
   it reads as slow in the hand; it is not a dropped or missed message.

Also fixed while in `Ble5.kt`, the open defect docs/ble5.md §9.4 recorded: a
scan whose registration fails (`SCAN_FAILED_APPLICATION_REGISTRATION_FAILED`
after a Bluetooth restart) was retried every 60 s forever, with nothing
anywhere saying so — a phone whose scan the controller was refusing looked
exactly like a phone in an empty room. The retry now backs off (60 s, 2 min,
4 min … capped at 15), the watchdog performs it instead of waiting for Dart to
ask again, and `radioStatus()` reports `scanDead`, `scanFailures` and
`scanLastFailCode`.

**Measurement status, honestly:** the code changes are in and the app builds;
the before/after numbers are NOT taken. No device was attached when this was
written. The protocol to close it out — and the shape the next entry here
should have — is §4's: `am force-stop`, relaunch, 5-min settle, release build,
screen-off verified with `dumpsys power | grep mWakefulness`, then the §4.3
per-thread sampler over ≥5-minute windows and an overnight
`dumpsys batterystats` soak (wakelock hold time, BLE scan time, WiFi lock time,
CPU ms), on C61 and TANK, before and after. Delivery is the gate, not the CPU
number: BLE message 10-of-10 both directions screen-off in the `battery` tier,
LAN reachability while asleep, hub round trip ≤ 5 s. Baseline to beat: 8% of
one core screen-off, 0 main-isolate stalls, ~250-300 MB RES.

### 8.12 A day on closed groups: five lessons that generalise (2026-09-06)

Making "C61 invites a phone on cellular into a closed group" work took a full
day and touched nothing that looked like the bug. What it cost, so it is not
paid again.

**Measure at the right point, or the fix lands in the wrong layer.** The first
symptom was "Hotwav never receives its invitation". I spent an hour inside
announce handling, LXMF-dest learning and the transport's fast-path pin — all
real, none of it the cause. The cause was one `continue` in
`_sendToMembers`: a group act fanned out to *existing members only*, and an
invitee is `invited`, so the one station the packet was for was never a
target. On a shared LAN this was invisible (the broadcast copy arrived by
accident); on cellular it was total. The lesson is the one §4 already states
for CPU: **read the send verdict of the packet in question, not the state of
the network around it.** `moderate wire — …reticulum:refused` right after
`create()` is the self-grant/accept (no target but me); the line for the
grant you sent comes later. I took the last line and chased a ghost.

**A door that is checked in a wapp is a door that is not checked.** The chat
wapp gated "may I post here" on the roster the core reported. Every other
caller — the HTTP API, any other wapp — aired freely, which is how a
non-member's post reached a member's archive during the test. Membership is
now decided once, in the core, at both doors: `WappDelivery` refuses a
non-member's group post before any wapp sees it, `XprsPublisher.mayAir`
refuses to air one, and `hal_xprs_send` returns `-2` so the wapp can *say* it.
The wapp's own check and the HAL it needed are gone. Same rule as
docs/architecture.md rule 1, and the same reason: a decision that exists in
one wapp exists nowhere.

**Three things the store does behind your back, each a false negative.**
- The archive keeps rows in a pending queue and flushes every **20 s**.
  `/api/xprs/history` is a SQL read, so a message that arrived 10 s ago is
  "not there". Two "delivery failures" in this work were this. A grant sent
  seconds after `create()` also found nothing to bundle for the same reason;
  `flush()` is public and cheap on an act somebody just tapped.
- The internet lane archived a `t:moderate` and never fed it to the live
  roster (`XprsGroups.offer` was called on the radio lane only). The roster
  moved *after a restart*, from the archive replay — the restart-fixes-it
  fingerprint §6.2.1 already warned about. Both lanes now call the same
  funnel.
- The §26.4 tie-break ("same `ts`, smaller id stands") sorted a self-grant
  and its own acceptance at random, dropping the acceptance about half the
  time. A rule written for contradicting acts by one signer was being applied
  to a causally-ordered pair by two. It failed silently and only sometimes —
  the worst kind.

**Cache the read of the thing that does not change.** `hal_xprs_group_roster`
called `XprsGroupKeys.mine()` — a full `SELECT` and a list build — to answer
"do we hold *this* group's key", on every roster change while a room was open.
§8.7's shape exactly; now one indexed row. It reads as free at the call site,
which is why the guard, not review, has to catch these.

**The tools lied, and each lie cost more than the bug.**
- `grep` here is `ugrep`, and it silently returns *nothing* for
  `rns_service.dart` (11k lines, valid UTF-8 — it classifies it as binary).
  Definitions "did not exist", call sites did. `grep -a`. An hour.
- `pgrep -f`/`pkill -f bundle/xprs` match the shell issuing them. "Desktop
  running" was my own command line; the desktop was down. `pidof xprs`.
- The log ring on a busy node scrolls in seconds; a verdict captured a minute
  later is a different packet's. Dump `n=60` *immediately* after the act.
- `xprs_archive_test` "monitor untouched" had been failing on `main` for two
  days (0c57aee made the internet lane a listed sighting on purpose). A red
  suite you did not cause still has to be understood before you trust green.

> **Rule: when a packet does not arrive, the first question is "what did the
> sender's publisher say about *that* packet", the second is "did the receiver's
> funnel call the same hooks it calls on the radio lane", and only then the
> network.** Every hour spent in the transport this day was spent before
> asking those two.

## Profiling native memory on a stock device (recipe)

The Dart VM service and Android's native heap profiler both work on a **profile
build**, which is what to reach for when `dumpsys meminfo` says Native Heap is
growing but the Dart heap is not. Neither needs root; `simpleperf` does, and is
refused by SELinux on stock builds.

```sh
flutter build apk --profile --target-platform android-arm --build-number=<high>
adb install -r build/app/outputs/flutter-apk/app-profile.apk
adb logcat -d | grep "Dart VM service"        # -> http://127.0.0.1:PORT/TOKEN=/
adb forward tcp:PORT tcp:PORT

# Dart side: heap AND external (malloc-backed typed data), per isolate.
curl -s http://127.0.0.1:PORT/TOKEN=/getVM
curl -s "http://127.0.0.1:PORT/TOKEN=/getMemoryUsage?isolateId=isolates/<id>"

# Native side: who malloc'd what, allocations minus frees.
adb shell "cat <<'EOF' | perfetto --txt -c - -o /data/misc/perfetto-traces/heap.pb
buffers { size_kb: 32768 }
data_sources { config { name: \"android.heapprofd\"
  heapprofd_config { sampling_interval_bytes: 4096 pid: <PID>
    continuous_dump_config { dump_phase_ms: 10000 dump_interval_ms: 20000 } } } }
duration_ms: 45000
EOF"
adb pull /data/misc/perfetto-traces/heap.pb
pip install perfetto   # then query heap_profile_allocation (count>0 = alloc,
                       # negative size rows = frees; net = sum(size))
```

Isolates spawned with `Isolate.spawn` share one heap, so `getMemoryUsage`
reports the same numbers for main/rns-crypto/rns-transport/nostr-engine — that
is the isolate GROUP, not a bug. Two `rns-crypto` entries are also expected:
the main isolate and the transport isolate each own a worker.

**Symbols.** Release/profile native libs are stripped, so heapprofd resolves
only `malloc`/`realloc` leaves; attribute by MAPPING (which `.so`) instead, or
build with symbols kept if a specific call stack is needed.

### What the device tools could NOT do (2026-08-07)

Save the next person the hours: on this stock tablet `simpleperf` is refused by
SELinux; **heapprofd sees only ~200 KB net while the process gains 8 MB**, so it
misses whatever this is; `getCpuSamples` returns zero samples even when the app
is launched with `--ez enable-dart-profiling true`; and
`setTraceClassAllocation` never fires for `_Map`, which is VM-internal.

What DID work is `getAllocationProfile` **diffed over time** — that is how the
runaway was pinned to the Dart heap and to ~330k {Map + index + 2 Lists +
String} units per 90 s. For the retaining path, reproduce on the Linux desktop
build and take a DevTools heap-snapshot diff; the device is the wrong place to
ask that question.
