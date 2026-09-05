/*
 * The LAN bearer's counters, which existed and nothing read.
 *
 * Bench 2026-09-05: a phone off its WiFi logged "LAN bearer on UDP 4242
 * (broadcast, 0 subnets)" fifty-six times and failed every send with "Network
 * is unreachable", and from /api/status it was indistinguishable from a quiet
 * LAN. The status row now carries the subnet count and the reopen count.
 */
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_lan.dart';

void main() {
  test('the status row says whether the bearer has a network at all', () {
    final j = XprsLan.instance.statusJson();
    expect(j['up'], isFalse, reason: 'never started in this test');
    expect(j['port'], 4242);
    expect(j.containsKey('subnets'), isTrue);
    expect(j['subnets'], 0);
    expect(j.containsKey('reopened'), isTrue);
    expect(j['reopened'], 0);
  });
}
