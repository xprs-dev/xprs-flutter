/*
 * THE FIRST MINUTE ON BLE.
 *
 * A message was handed to the BLE5 bearer once, and docs/ble5.md section 1
 * says what one airing is worth: "a frame transmitted once may not be
 * observed at all". The next thing that re-aired a 1:1 was the custody
 * ladder, minutes later; nothing re-aired a Local post at all.
 *
 * So the send door airs the same wire three times inside a minute -- the
 * IDENTICAL wire, in the SAME slot, so the section 5 identifier and `ts:` are
 * unchanged (section 9.3, section 31.1) -- and stops early for a 1:1 the
 * moment its receipt arrives. This file is the schedule, spelled out.
 */
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_airtime.dart';
import 'package:xprs/services/xprs/xprs_body.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_outbox.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_send.dart';

const _local = 't:message f:X1VCVM ts:2026-09-04_10:00:00 scope:local';
const _direct = 't:message f:X1VCVM d:X1ARKL ts:2026-09-04_10:00:00';

class _FakeBearer implements XprsBearer {
  _FakeBearer(this.name, {required this.shortRange, this.answer = XprsSendResult.sent});
  @override
  final String name;
  @override
  String get archiveBearer => name;
  @override
  final bool shortRange;
  final XprsSendResult answer;
  final List<String> sent = [];
  final List<String> slots = [];
  final List<int> atS = [];
  @override
  Future<bool> get active async => true;
  @override
  Future<XprsSendResult> send(String wire,
      {required int part, String slot = 'status', Duration? ttl}) async {
    sent.add(wire);
    slots.add('$slot:$part');
    atS.add(_clock.nowMs ~/ 1000);
    return answer;
  }
}

/// The fake clock the ledger reads and the schedule advances.
class _Clock {
  int nowMs = 1700000000000;
}

final _clock = _Clock();

/// Let the unawaited repeat run: every hop in it is a completed future.
Future<void> _settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<XprsPacket> _build(String head, String text) {
  final built = xprsBuildDirect(
      head: XprsPacket.parse(head)!, text: text, private: false);
  expect(built.ok, isTrue);
  return built.packets;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeBearer ble;

  setUp(() {
    _clock.nowMs = 1700000000000;
    XprsRetryLedger.instance
      ..reset()
      ..now = () => _clock.nowMs;
    XprsOutbox.debugReset();
    XprsSend.debugReset();
    XprsSend.repeatAfter = const [Duration(seconds: 20), Duration(seconds: 20)];
    // No real waiting: the clock moves instead.
    XprsSend.wait = (d) async {
      _clock.nowMs += d.inMilliseconds;
    };
    ble = _FakeBearer('ble5', shortRange: true);
    XprsPublisher.instance.bearers = [ble];
  });

  tearDown(() {
    XprsSend.wait = (d) => Future.delayed(d);
    XprsSend.repeatAfter = const [Duration(seconds: 20), Duration(seconds: 20)];
    XprsRetryLedger.instance.now =
        () => DateTime.now().millisecondsSinceEpoch;
  });

  group('a Local post', () {
    test('is aired three times inside a minute, the same wire, the same slot',
        () async {
      final parts = _build(_local, 'anyone got a 10 mm spanner?');
      final id = xprsIdentifier(parts.first);

      await XprsSend.instance.airBroadcast(parts, id: id);
      await _settle();

      expect(ble.sent, hasLength(3));
      expect(ble.sent.toSet(), hasLength(1),
          reason: 'a retry is not a new packet (§31.1): identical bytes, '
              'identical ts:, identical identifier');
      expect(ble.slots.toSet(), {'message:$id:1:1'},
          reason: 'the same slot refreshes the rotation entry rather than '
              'adding one');
      expect(ble.atS.last - ble.atS.first, 40,
          reason: 'at +0, +20 s and +40 s -- all inside the first minute');
      expect(XprsRetryLedger.instance.attempts(id), 3,
          reason: 'one ledger for the whole core: the custody ladder that '
              'follows must see these airings');
      expect(XprsSend.repeated, 1);
    });

    test('every part of a split post is repeated, each under its own slot',
        () async {
      final parts =
          _build(_local, List.generate(90, (i) => 'w$i').join(' '));
      expect(parts.length, greaterThan(1),
          reason: 'the fixture has to split to test anything');
      final id = xprsIdentifier(parts.first);

      await XprsSend.instance.airBroadcast(parts, id: id);
      await _settle();

      expect(ble.sent, hasLength(parts.length * 3));
      expect(ble.slots.toSet(), hasLength(parts.length));
    });
  });

  group('a 1:1', () {
    test('is aired three times too', () async {
      final parts = _build(_direct, 'are you there?');
      final id = xprsIdentifier(parts.first);

      await XprsSend.instance.airDirect(parts, dest: 'X1ARKL', id: id);
      await _settle();

      expect(ble.sent, hasLength(3));
      expect(ble.sent.toSet(), hasLength(1));
      expect(ble.slots.toSet(), {'message:$id:1:1'},
          reason: 'per record, not per destination: a second message to the '
              'same station must not be evicted by the first one\'s repeat');
      expect(XprsOutbox.instance.stateOf(id), TxState.sent);
    });

    test('stops the moment its receipt arrives (§13.7)', () async {
      final parts = _build(_direct, 'are you there?');
      final id = xprsIdentifier(parts.first);
      // The receipt lands during the first wait.
      XprsSend.wait = (d) async {
        _clock.nowMs += d.inMilliseconds;
        XprsOutbox.instance.noteReceipt(id, state: 'ack');
      };

      await XprsSend.instance.airDirect(parts, dest: 'X1ARKL', id: id);
      await _settle();

      expect(ble.sent, hasLength(1),
          reason: 'the receipt is what ends re-airing; a second copy after '
              'it is airtime spent saying what was already heard');
      expect(XprsOutbox.instance.stateOf(id), TxState.delivered);
    });

    test('is not repeated when ble5 did not air it', () async {
      // The session lane, an inactive radio, a refusal: none of them is an
      // advert that may have been missed, so none of them is repeated here.
      ble = _FakeBearer('ble5', shortRange: true, answer: XprsSendResult.refused);
      XprsPublisher.instance.bearers = [ble];
      final parts = _build(_direct, 'are you there?');
      final id = xprsIdentifier(parts.first);

      await XprsSend.instance.airDirect(parts, dest: 'X1ARKL', id: id);
      await _settle();

      expect(ble.sent, hasLength(1));
      expect(XprsRetryLedger.instance.attempts(id), 0);
      expect(XprsSend.repeated, 0);
    });
  });

  test('the ledger, not the schedule, refuses an airing that comes too soon',
      () async {
    // A schedule that fires with no time passed: the ledger has the last
    // word, and section 31.1's spacing holds even if the schedule is wrong.
    XprsSend.wait = (_) async {};
    final parts = _build(_local, 'hello the room');
    final id = xprsIdentifier(parts.first);

    await XprsSend.instance.airBroadcast(parts, id: id);
    await _settle();

    expect(ble.sent, hasLength(1));
    expect(XprsRetryLedger.instance.attempts(id), 1);
  });
}
