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
  final helper = File(
    'android/app/src/main/kotlin/ecc/stellar/app/'
    'StellarMessageNotifications.kt',
  ).readAsStringSync();

  test('distinct FCM wakes keep separate grouped notifications', () {
    expect(service, contains('data["wakeId"]'));
    expect(service, contains('StellarMessageNotifications.show('));
    expect(helper, contains('manager.notify(notificationTag(wakeId)'));
    expect(helper, contains('.setGroup(GROUP_KEY)'));
    expect(helper, contains('.setGroupSummary(true)'));
    expect(helper, contains('POST_NOTIFICATIONS'));
    expect(service, contains('scheduleBackgroundMessageSync()'));
  });

  test('headless notifications use the same deduplicating notification helper', () {
    expect(runner, contains('StellarMessageNotifications.show('));
    expect(runner, isNot(contains('MESSAGE_ID_BASE')));
  });

  test('call push stays on separate call notification path', () {
    expect(service, contains('if (data["type"] == "call")'));
    expect(service, contains('handleIncomingCall(data)'));
    expect(service, contains('StellarIncomingCallNotification.show('));
  });
}
