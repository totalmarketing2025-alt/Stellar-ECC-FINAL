import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final service = File(
    'android/app/src/main/kotlin/ecc/stellar/app/'
    'StellarFirebaseMessagingService.kt',
  ).readAsStringSync();
  final runner = File(
    'android/app/src/main/kotlin/ecc/stellar/app/'
    'StellarPushBackgroundRunner.kt',
  ).readAsStringSync();

  test('FCM message wake coalesces into one stable notification', () {
    expect(service, contains('manager.notify('));
    expect(service, contains('MESSAGE_ID_BASE'));
    expect(service, isNot(contains('System.currentTimeMillis() % 100000')));
    expect(service, contains('scheduleBackgroundMessageSync()'));
  });

  test('headless background notifications share the same stable ID', () {
    expect(runner, contains('private const val MESSAGE_ID_BASE = 1001'));
    expect(service, contains('private const val MESSAGE_ID_BASE = 1001'));
    expect(runner, isNot(contains('System.currentTimeMillis() % 100000')));
    expect(runner, contains('manager.notify('));
  });

  test('call push stays on separate call notification path', () {
    expect(service, contains('if (data["type"] == "call")'));
    expect(service, contains('handleIncomingCall(data)'));
    expect(service, contains('StellarIncomingCallNotification.show('));
  });
}
