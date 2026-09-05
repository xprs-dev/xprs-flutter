/*
 * The Bluetooth stack under the app can die, and the app must notice.
 *
 * TANK2, 2026-09-04 22:55: the controller stopped answering an extended
 * advertising enable, com.android.bluetooth aborted, Android restarted it.
 * The app kept its AdvertisingSet -- a binder to a dead process -- and every
 * setAdvertisingData on it was swallowed by the framework, so for a night the
 * phone reported advOnAir with 13,593 airings and put nothing on the air. The
 * native side now rebuilds the set and tells Dart on the existing GATT event
 * channel; this checks the Dart end of that one channel.
 */
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/src/connections/bluetooth/ble5_bus.dart';

const _gattChannel = 'com.xprs.app/ble5_gatt';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var listening = false;

  setUpAll(() {
    final b = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    b.setMockStreamHandler(
      const EventChannel(_gattChannel),
      MockStreamHandler.inline(
        onListen: (args, sink) => listening = true,
        onCancel: (args) => listening = false,
      ),
    );
    Ble5Bus.instance.startGattEvents();
  });

  void deliver(Map<String, Object?> event) {
    expect(listening, isTrue, reason: 'nobody is listening on the GATT channel');
    final env = const StandardMethodCodec().encodeSuccessEnvelope(event);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(_gattChannel, env, (_) {});
  }

  test('an adapter restart reaches the hook with its count', () async {
    final seen = <int>[];
    Ble5Bus.instance.onAdapterRestarted = seen.add;

    deliver({'event': 'adapterRestarted', 'restarts': 2});
    await Future<void>.delayed(Duration.zero);

    expect(seen, [2]);
  });

  test('a restart is not an advert refusal', () async {
    // The two are different events with different consequences: a refusal
    // sends adverts down the legacy path for good, a restart just rebuilds.
    var refused = 0;
    Ble5Bus.instance.onAdvertFailed = (_) => refused++;
    final before = Ble5Bus.instance.advertFailures;

    deliver({'event': 'adapterRestarted', 'restarts': 3});
    await Future<void>.delayed(Duration.zero);

    expect(refused, 0);
    expect(Ble5Bus.instance.advertFailures, before);
  });
}
