---
name: justify-protocol-additions
description: Max challenges new protocol fields that look like existing ones; justify against what already exists before proposing
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 898b2dda-321d-44ec-ba27-41b4ee842623
  modified: 2026-08-28T08:10:27.886Z
---

Before proposing any new XPRS field, state explicitly why the existing fields
do not already do the job. Max reads a proposal against the current vocabulary
and pushes back when two fields look alike — he asked "why is `route:` needed,
right now it seems to overlap/duplicate the function of `via:`" and rejected the
plan until it answered.

**Why:** the specification's own design rules forbid redundancy (rule 5: one
type carries every kind of observation; §34: a new field takes an unused key and
never redefines an assignment). A field that duplicates another is a defect, so
the burden is to show the distinction, not to assert it.

**How to apply:** when two fields share a shape, separate them on the axes that
matter and quote the spec. The worked example: `relay:` / `via:` / `route:` all
hold a comma-list of callsigns, but §9.1 excludes `via:` from the signature *by
necessity* — "a signature covering it would break at the first hop and every
relayed packet would read as forged" — so `via:` is unsigned and unverifiable
while `route:` is inside `sig:` and is evidence. Asked · happened · attested.

See [[read-the-whole-xprs-spec]] — the same instinct: read the document before
inventing, and cite it when you do.
