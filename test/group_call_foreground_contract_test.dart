import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'android/app/src/main/';
  const kotlin = '${root}kotlin/ecc/stellar/app/';
  String read(String path) => File(path).readAsStringSync();

  test('group service is private and declares media foreground types', () {
    final manifest = read('${root}AndroidManifest.xml');
    final service = RegExp(
      r'<service\s+android:name="\.calls\.StellarGroupCallForegroundService"[^>]*>',
    ).firstMatch(manifest)?.group(0);
    expect(service, isNotNull);
    expect(service, contains('android:exported="false"'));
    expect(service, contains('android:foregroundServiceType="microphone|camera"'));
    expect(manifest, contains('FOREGROUND_SERVICE_MICROPHONE'));
    expect(manifest, contains('FOREGROUND_SERVICE_CAMERA'));
  });

  test('group service has separate notification and room-scoped stop', () {
    final group = read('${kotlin}calls/StellarGroupCallForegroundService.kt');
    final direct = read('${kotlin}calls/StellarCallForegroundService.kt');
    expect(group, contains('ID = 42002'));
    expect(direct, contains('NOTIFICATION_ID = 42001'));
    expect(group, contains('if (activeRoom == room)'));
    expect(group, contains('START_NOT_STICKY'));
    expect(group, contains('VISIBILITY_PRIVATE'));
  });

  test('Flutter and Android agree on foreground channel operations', () {
    final activity = read('${kotlin}MainActivity.kt');
    final coordinator = read('lib/core/calls/group_call_coordinator.dart');
    for (final method in ['startGroupForeground', 'stopGroupForeground']) {
      expect(activity, contains('"$method"'));
      expect(coordinator, contains("'$method'"));
    }
    expect(activity, contains('ecc.stellar.app/group_calls'));
    expect(coordinator, contains('ecc.stellar.app/group_calls'));
  });
}
