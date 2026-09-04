/*
 * When a 1:1 may skip the air and go point to point (docs/ble5.md §9).
 *
 * The advert window is five seconds a minute shared by every registered frame,
 * so a 1:1 broadcast to the whole street is airtime taken from the street. It
 * may be suppressed ONLY for a peer we can dial right now AND that told us, in
 * its own MSP HELLO, that it takes custody of messages.
 *
 * The previous version of this gate asked `MeshTable.neighbors` for a device
 * class and a bidirectional flag. Both look right; both are structurally
 * absent, because the table is fed only by the 0x4D mesh beacon and a phone
 * deliberately airs none. Those tests passed against a feature that was dead on
 * hardware — so these ones assert on the signal that is actually transmitted,
 * and are mostly about what must NOT be suppressed.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/mesh/mesh_custody.dart';
import 'package:xprs/services/mesh/mesh_session.dart';

/// What a phone offers: msgCustody | bulkRx | bulkTx | gossip — the `caps=0xf`
/// observed from X3ARK on the bench (docs/ble5.md §9.1).
const int kPhoneCaps = MspCaps.msgCustody |
    MspCaps.bulkRx |
    MspCaps.bulkTx |
    MspCaps.gossip;

void main() {
  group('a 1:1 may go point to point', () {
    test('to a peer we can dial that offered msgCustody', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: true, peerCaps: kPhoneCaps),
          isTrue);
    });

    test('msgCustody alone is enough — the bulk lane is a separate question',
        () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: true, peerCaps: MspCaps.msgCustody),
          isTrue);
    });
  });

  group('a 1:1 is worth STARTING a session for', () {
    test('a peer in reach whose caps we do not know yet', () {
      // First contact: the advert still goes out, but the dial that records
      // the caps -- and carries the message in ~2 s -- starts now, not after
      // the second message.
      expect(
          MeshCustodyDelegate.worthDialing(
              dialableNow: true, capsKnown: false, peerCaps: 0),
          isTrue);
    });
    test('a peer that offered msgCustody', () {
      expect(
          MeshCustodyDelegate.worthDialing(
              dialableNow: true, capsKnown: true, peerCaps: kPhoneCaps),
          isTrue);
    });
    test('never a peer that declared caps without custody (a dongle)', () {
      const dongle = MspCaps.bulkRx | MspCaps.bulkTx;
      expect(
          MeshCustodyDelegate.worthDialing(
              dialableNow: true, capsKnown: true, peerCaps: dongle),
          isFalse);
    });
    test('never a peer we cannot dial', () {
      expect(
          MeshCustodyDelegate.worthDialing(
              dialableNow: false, capsKnown: false, peerCaps: 0),
          isFalse);
    });
  });

  group('and must NOT, for anything else', () {
    test('a peer we have never held a session with', () {
      // No HELLO, no caps. The FIRST 1:1 to a peer is always aired; the session
      // it provokes records the caps and the next one goes direct. Suppressing
      // on a guess costs two minutes of silence.
      expect(
          MeshCustodyDelegate.pointToPointOk(dialableNow: true, peerCaps: 0),
          isFalse);
    });

    test('a peer whose caps do not include msgCustody', () {
      // An ESP32 excludes itself here: a dongle goes deaf during an MSP session
      // and relaying is what dongles are FOR, so it needs to overhear the
      // broadcast. No device-class byte is required to reach that conclusion.
      const dongle = MspCaps.bulkRx | MspCaps.bulkTx;
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: true, peerCaps: dongle),
          isFalse);
    });

    test('a peer that has gone stale in the dial registry', () {
      // It offered custody once; it is not in range now. The radio has moved on
      // and the message must take its chances on the air.
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: false, peerCaps: kPhoneCaps),
          isFalse);
    });

    test('a peer that is neither dialable nor known', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(dialableNow: false, peerCaps: 0),
          isFalse);
    });

    test('gossip-only caps — a peer that swaps tables but takes no mail', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: true, peerCaps: MspCaps.gossip),
          isFalse);
    });
  });

  group('which address may be dialled', () {
    // The bug this exists for: two phones in one room, `neighbors: 0` for
    // hours. Every tick dialled the address a beacon carried — the extended
    // advertising set's MAC, which is setConnectable(false) — and Android took
    // 30 s to answer GATT_CONNECTION_TIMEOUT(147) into a log nobody read.
    test('a beacon MAC is refused, and says so', () {
      final why = MeshCustodyDelegate.undialableReason(
        callsign: 'X3ARK',
        addr: 'AA:BB:CC:DD:EE:FF',
        verifiedAddr: null,
      );
      expect(why, isNotNull);
      expect(why, contains('cannot'));
    });

    test('an address proven by a presence advert or a HELLO is dialled', () {
      expect(
          MeshCustodyDelegate.undialableReason(
            callsign: 'X3ARK',
            addr: 'AA:BB:CC:DD:EE:FF',
            verifiedAddr: 'AA:BB:CC:DD:EE:FF',
          ),
          isNull);
    });

    test('a peer whose address changed under us is refused, not dialled', () {
      // The extended set rotates its address; the connectable one does not.
      // A sighting under a new MAC must not overwrite what we proved.
      final why = MeshCustodyDelegate.undialableReason(
        callsign: 'X3ARK',
        addr: '11:22:33:44:55:66',
        verifiedAddr: 'AA:BB:CC:DD:EE:FF',
      );
      expect(why, isNotNull);
      expect(why, contains('11:22:33:44:55:66'));
    });
  });

  group('the fallback deadline', () {
    test('is longer than the scheduler is allowed to spend on one dial', () {
      // A dial alone gets 110 s in the scheduler, so a shorter deadline would
      // re-air a message that is still being delivered.
      expect(MeshCustodyDelegate.suppressedGrace.inSeconds, greaterThan(110));
    });
  });
}
