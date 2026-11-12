import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression contract for Android heads-up call notification actions.
///
/// These checks do not replace device-level background and lock-screen tests.
/// They prevent accidentally reverting to BroadcastReceiver -> startActivity,
/// which Android may block while another application is in the foreground.
void main() {
  final notification = File(
    'android/app/src/main/kotlin/ecc/stellar/app/calls/'
    'StellarIncomingCallNotification.kt',
  ).readAsStringSync();
  final activity = File(
    'android/app/src/main/kotlin/ecc/stellar/app/calls/'
    'StellarIncomingCallActivity.kt',
  ).readAsStringSync();

  test('notification actions use user-initiated Activity PendingIntents', () {
    expect(notification, contains('val answerPending = PendingIntent.getActivity('));
    expect(notification, contains('val rejectPending = PendingIntent.getActivity('));
    expect(notification, isNot(contains('PendingIntent.getBroadcast(')));
    expect(notification, contains('StellarIncomingCallActivity::class.java'));
  });

  test('Answer and Decline forward their call IDs to Flutter', () {
    expect(activity, contains('forwardAction("answer", callId, remote, kind, chatId)'));
    expect(activity, contains('forwardAction("reject", callId, remote, kind, chatId)'));
    expect(activity, contains('StellarCallManager.setCallEnded(this, callId)'));
    expect(activity, contains('callId.isBlank() || remote.isBlank()'));
  });
}
