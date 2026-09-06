---
name: chat-is-xprs-only-no-lxmf-in-core-path
description: "Max (2026-09-05, furious) — the chat wapp and the core's XPRS message door have NO LXMF/Reticulum dependency; signatures are optional NOSTR per XPRS.md §9.1; the core picks the way back, local bearers first, internet last"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: fff23a0f-37c9-40e8-971e-0bd96c106e69
  modified: 2026-09-05T08:21:33.300Z
---

Max, 2026-09-05, after I proposed keeping an LXMF hex on the XPRS delivery path: "There is no fucking LXMF on the chat at all… The chat only cares for XPRS packets and what is specified on XPRS.md… It does not even know what is 'reticulum' except for a tag when relating to know from where the packet was received. Only NOSTR key pairs are accepted and even there are optional." And: "It is the job of that core to decide how to send a packet back… When the device talks to you in BLE then talk to it in BLE or any faster local method when available, for example LAN… internet only as last measure for devices outside our direct reach."

**Why:** the phone's `MeshCourier.deliverXprs` still required `RnsService.lxmfDestForCallsign(from)` (an RNS-identity-derived hex) before delivering a `t:message`, so a BLE/LAN-only ESP32 station's 1:1 was parked 24 h and dropped. That was a leftover of the LXMF-keyed inbox; the chat files rooms by callsign and reads only `call/content/id/sig/ts/bearer`. XPRS.md §9.1: an unsigned packet must be accepted; keys are NOSTR secp256k1.

**How to apply:** an XPRS `t:message` goes `PacketGateway → XprsIngest → MeshCourier → WappDelivery.deliverMessage` with callsign, body, ts, id, bearer tag and NOSTR sig verdict — never through `injectLxmf`, `_lxmfInbox` or any LXMF address. Never make delivery, signing or bearer choice depend on Reticulum. The way back is `XprsPublisher._preferredBearer` (station's declared `link:`, ranked lan → ble5 → reticulum, fan-out without evidence) — do not add static routes. Related: [[chat-wapp-is-xprs-only-local-default]], [[transport-fixes-live-in-the-core-bearer]], [[justify-protocol-additions]].
