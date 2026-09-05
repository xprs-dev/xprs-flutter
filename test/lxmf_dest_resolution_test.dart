/*
 * A callsign resolves to ONE destination — the current one, not a dead twin.
 *
 * Bench 2026-09-05: a phone that changed identity (a recreated profile, a new
 * LXMF delivery dest) left its OLD dest in the on-disk directory forever,
 * because the dedup only dropped a row for the SAME dest. The fallback
 * resolver returned the first name match, so every send to that callsign hit
 * the dead old dest, held for relay, and retried a hash nothing had a path to
 * (49 messages queued to it) while the live dest sat unused.
 *
 * lxmfDestForCallsign reads the live observed table first (ranked by key
 * verification, recency, path) and the on-disk directory only as a fallback;
 * this covers the fallback, where the immortal twin lived. The directory map
 * is updated in memory regardless of whether preferences are available, so
 * the test needs no on-disk store.
 */
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/reticulum/rns_service.dart';

void main() {
  final rns = RnsService.instance;

  // Two DIFFERENT 32-hex destinations for one callsign — an identity change.
  const oldDest = '0737a64b73c31d3858498c5c9c9c50b5';
  const newDest = '9fe08ecdc2df5c0a9d65294f79a9cf40';
  const call = 'X1WATT';

  test('a changed dest replaces the old one — no immortal twin', () {
    rns.rememberLxmfIdentity(oldDest, call);
    expect(rns.lxmfDestForCallsign(call), oldDest,
        reason: 'the only known dest so far');

    // The peer re-announces a new identity for the same callsign.
    rns.rememberLxmfIdentity(newDest, call);

    expect(rns.lxmfDestForCallsign(call), newDest,
        reason: 'the current dest, not the dead old one the send used to pick');
  });

  test('the old dest no longer resolves that callsign', () {
    rns.rememberLxmfIdentity(oldDest, call);
    rns.rememberLxmfIdentity(newDest, call);
    // The reverse map still knows both hexes as names, but the forward
    // resolver — the one the send path uses — must yield exactly the new dest.
    final got = rns.lxmfDestForCallsign(call);
    expect(got, newDest);
    expect(got, isNot(oldDest));
  });

  test('an unknown callsign resolves to nothing', () {
    expect(rns.lxmfDestForCallsign('X9NOONE'), isEmpty);
  });
}
