import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = 'android/app/src/main/kotlin/ecc/stellar/app/';
  final policy = File('${native}WantedModeBatteryGuardPolicy.kt').readAsStringSync();
  final monitor = File('${native}WantedModeEventMonitor.kt').readAsStringSync();
  final store = File('${native}WantedModeChallengeStore.kt').readAsStringSync();
  final service = File('${native}WantedModeForegroundService.kt').readAsStringSync();
  final screen = File('lib/presentation/screens/security/security_center_screen.dart')
      .readAsStringSync();

  test('battery triggers strictly below 20 percent and rearms at 25', () {
    expect(policy, contains('TRIGGER_BELOW_PERCENT = 20'));
    expect(policy, contains('REARM_AT_PERCENT = 25'));
    expect(policy, contains('percent < TRIGGER_BELOW_PERCENT && armed'));
    expect(policy, contains('percent >= REARM_AT_PERCENT'));
  });

  test('Android battery readings come from protected broadcast and real extras', () {
    expect(monitor, contains('Intent.ACTION_BATTERY_CHANGED'));
    expect(monitor, contains('Context.RECEIVER_NOT_EXPORTED'));
    expect(monitor, contains('BatteryManager.EXTRA_LEVEL'));
    expect(monitor, contains('BatteryManager.EXTRA_SCALE'));
    expect(monitor, contains('BatteryManager.EXTRA_PRESENT'));
    expect(monitor, contains('if (level < 0 || scale <= 0 || level > scale) return'));
  });

  test('persistent battery latch prevents repeat challenges after service restart', () {
    expect(monitor, contains('KEY_BATTERY_ARMED'));
    expect(monitor, contains('prefs.getBoolean(KEY_BATTERY_ARMED, true)'));
    expect(monitor, contains('.putBoolean(KEY_BATTERY_ARMED, decision.armed)'));
    expect(monitor, contains('if (decision.triggerChallenge)'));
    expect(monitor, contains('if (stickyBattery != null) observeBattery(stickyBattery)'));
    expect(monitor, contains('appContext.unregisterReceiver(batteryReceiver)'));
  });

  test('battery event enters same 10-second challenge and automatic wipe path', () {
    expect(monitor, contains('record("battery", "low", percent)'));
    expect(monitor, contains('"battery" -> "BATTERY"'));
    expect(store, contains('"BATTERY"'));
    expect(store, contains('"low"'));
    expect(store, contains('TIMEOUT_MILLIS = 10_000L'));
    expect(service, contains('it.id in previouslyPendingIds && !it.recoveredFromReboot'));
    expect(service, contains('WantedModeWipeState.request(applicationContext)'));
    expect(service, contains('newlyExpired &&'));
    expect(service, isNot(contains('challenge.category != "BATTERY"')));
  });

  test('battery events reuse security notification and expose monitoring state', () {
    expect(service, contains('challenge.category == "BATTERY"'));
    expect(service, contains('putExtra(EXTRA_CHALLENGE_ID, challenge.id)'));
    expect(monitor, contains('"batteryPercent" to prefs.getInt(KEY_BATTERY_PERCENT, -1)'));
    expect(monitor, contains('event.put("batteryPercent", batteryPercent)'));
    expect(screen, contains('Battery Guard:'));
  });
}
