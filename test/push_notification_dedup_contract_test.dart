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

  final backgroundHandler = File(
    'lib/core/network/push_background_handler.dart',
  ).readAsStringSync();

  test('FCM wakes sync first and do not post generic duplicate alerts', () {
    expect(service, contains('scheduleBackgroundMessageSync()'));
    expect(service, isNot(contains('StellarMessageNotifications.show(')));
    expect(service, isNot(contains('showGenericMessageNotification')));
    expect(helper, contains('manager.notify(notificationTag(messageKey), 0'));
    expect(helper.split('.notify(').length - 1, 1);
    expect(helper, isNot(contains('.setGroupSummary(true)')));
    expect(helper, contains('POST_NOTIFICATIONS'));
  });

  test('only decrypted chat messages post one idempotent local alert', () {
    expect(backgroundHandler, contains('receivedMessage != null'));
    expect(backgroundHandler, contains('Platform.isAndroid'));
    expect(backgroundHandler, contains("'showMessageNotification'"));
    expect(backgroundHandler, contains('envelope.deliveryToken'));
    expect(
      runner,
      contains('StellarMessageNotifications.show(context, messageKey)'),
    );
    expect(runner, contains('StellarMessageNotifications.show('));
    expect(runner, contains('call.arguments as? String'));
  });

  test('call push stays on separate call notification path', () {
    expect(service, contains('if (data["type"] == "call")'));
    expect(service, contains('handleIncomingCall(data)'));
    expect(service, contains('StellarIncomingCallNotification.show('));
  });
}
