import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = 'android/app/src/main/kotlin/ecc/stellar/app/';
  final service = File('${native}WantedModeForegroundService.kt').readAsStringSync();
  final monitor = File('${native}WantedModeEventMonitor.kt').readAsStringSync();
  final store = File('${native}WantedModeChallengeStore.kt').readAsStringSync();
  final activity = File('${native}MainActivity.kt').readAsStringSync();
  final boot = File('${native}WantedModeBootReceiver.kt').readAsStringSync();
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final app = File('lib/app/app.dart').readAsStringSync();
  final router = File('lib/app/router.dart').readAsStringSync();
  final security = File(
    'lib/presentation/screens/security/security_center_screen.dart',
  ).readAsStringSync();

  test('every pending event uses the same urgent notification path', () {
    expect(service, contains('buildEventAlertNotification(pending.first(), pending.size)'));
    expect(service, contains('EVENT_ALERT_CHANNEL_ID'));
    expect(service, contains('NotificationManager.IMPORTANCE_HIGH'));
    expect(service, contains('putExtra(EXTRA_CHALLENGE_ID, challenge.id)'));
    expect(service, contains('PendingIntent.FLAG_IMMUTABLE'));
    expect(service, isNot(contains('buildPowerAlertNotification(')));
    expect(service, contains('lastAlertFingerprint'));
  });

  test('notification target survives lock and routes to exact check', () {
    expect(activity, contains('PREF_PENDING_SECURITY_CHALLENGE_ID'));
    expect(activity, contains('putString(PREF_PENDING_SECURITY_CHALLENGE_ID, challengeId)'));
    expect(activity, contains('"challengeId" to (challengeId ?: "")'));
    expect(app, contains('if (!mounted || !ref.read(isUnlockedProvider)) return;'));
    expect(app, contains("'?wanted=1'"));
    expect(router, contains("s.uri.queryParameters['challengeId']"));
    expect(security, contains('_WantedModeOpenOnce('));
    expect(security, contains('widget.initialChallengeId'));
  });

  test('active deadlines use monotonic time and reboot-aware records', () {
    expect(store, contains('SystemClock.elapsedRealtime()'));
    expect(store, contains('Settings.Global.BOOT_COUNT'));
    expect(store, contains('recoveredFromReboot'));
    expect(activity, contains('"remainingMillis" to wantedModeChallengeStore.remainingMillis(it)'));
    expect(service, contains('newlyExpired &&'));
    expect(service, contains('canShowEventAlerts() &&'));
    expect(service, contains('it.id in previouslyPendingIds'));
    expect(service, isNot(contains('expiredAtStartup > 0 &&')));
  });

  test('boot recovery retains preference and health is measured', () {
    expect(manifest, contains('.WantedModeBootReceiver'));
    expect(manifest, contains('android.intent.action.BOOT_COMPLETED'));
    expect(boot, contains('WantedModeWipeState.isEnabled(context)'));
    expect(boot, contains('startForegroundService(service)'));
    expect(boot, contains('markPendingRecoveredFromBoot()'));
    expect(boot, contains('background_service_restart_restricted'));
    expect(monitor, contains('"listenersRegistered" to listenersRegistered'));
    expect(monitor, contains('"status" to status'));
    expect(activity, contains('"getMonitoringHealth"'));
  });

  test('Wi-Fi, Bluetooth, and USB host monitoring remain independent', () {
    expect(monitor, contains('BluetoothDevice.ACTION_ACL_CONNECTED'));
    expect(monitor, contains('connectivityManager.registerNetworkCallback('));
    expect(monitor, contains('usbManager.deviceList.keys'));
    expect(monitor, contains('"usbScope" to "HOST_ONLY"'));
    expect(monitor, contains(r'val dedupeKey = "$category:$action"'));
    expect(service, contains('eventMonitor.scanUsbHostDevices()'));
  });

  test('historical expired challenges can be PIN-acknowledged', () {
    expect(store, contains('fun acknowledgeExpired(id: String): Boolean'));
    expect(activity, contains('"acknowledgeExpiredChallenge"'));
    expect(security, contains('notifier.acknowledgeExpiredAfterPin('));
  });
}
