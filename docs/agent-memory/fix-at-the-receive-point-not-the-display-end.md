---
name: fix-at-the-receive-point-not-the-display-end
description: "Max's rule after a bad session — fix incoming-message problems at the central receive funnel, never with patches at each display end"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-28T21:10:56.585Z
---

When something is wrong with messages arriving, fix it **where the message is
received**, not at the end of each delivery path. Max's words: *"There is
central point for handling the incoming messages, so stop fucking it up with
super complicated approaches in the end of the workflow rather than when the
message is received."*

He also rejects patch-stacking outright: *"I don't want patches to complicate
things more. This situation needs to be simplified."* A plan that adds N steps
to N different code paths will be refused, and rightly.

**Why:** on 2026-08-28 I enforced one rule — "protocol never reaches a person" —
in seven places, each at the end of a different path, each with a slightly
different test. Every one was its own bug, and fixing one kept breaking another.
Three rounds of "fixed it" that were not fixed, and a regression that silently
lost a real message. That is what burned his evening.

**How to apply:**
- Find the single door everything passes through and put the rule there.
  In this app: `XprsIngest.heard` for inbound packets;
  `RnsService._admitToInbox` for anything a person will read.
- Prefer changes that DELETE decision points. Count call sites before and after.
- Measure before changing: he accepts one counter that answers the question
  over a plan that guesses. Invisible work is unmeasurable work.
- Verify on both phones and say plainly what is still broken. Do not report
  success from counters alone — send a real message and look at the screen.

Related: [[read-performance-md-before-coding]], [[validate-ble-changes-on-device]]
