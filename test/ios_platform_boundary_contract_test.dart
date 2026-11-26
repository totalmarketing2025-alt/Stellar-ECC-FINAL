import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final backgroundHandler =
      File('lib/core/network/push_background_handler.dart').readAsStringSync();
  final wantedMode =
      File('lib/presentation/state/security_providers.dart').readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
  final podfile = File('ios/Podfile').readAsStringSync();
  final entitlements =
      File('ios/Runner/Runner.entitlements').readAsStringSync();
  final iosWorkflow =
      File('.github/workflows/ios-platform.yml').readAsStringSync();

  test('Android-only background channel is guarded on other platforms', () {
    expect(backgroundHandler, contains("import 'dart:io';"));
    expect(backgroundHandler, contains('final wipePending = Platform.isAndroid'));
    expect(backgroundHandler, contains('if (Platform.isAndroid) {'));
    expect(backgroundHandler, contains("'backgroundComplete'"));
  });

  test('Wanted Mode remains explicitly Android-only', () {
    expect(wantedMode, contains('if (!Platform.isAndroid) {'));
    expect(
      wantedMode,
      contains('Wanted Mode monitoring is currently Android-only.'),
    );
  });

  test('iOS initializes Firebase through the guarded Flutter setup', () {
    expect(appDelegate, contains('GeneratedPluginRegistrant.register(with: self)'));
    expect(appDelegate, isNot(contains('FirebaseApp.configure()')));
  });

  test('unimplemented iOS background modes are not declared', () {
    expect(infoPlist, isNot(contains('<string>voip</string>')));
    expect(infoPlist, isNot(contains('<string>processing</string>')));
  });

  test('Runner links SQLCipher and selects APNs by build configuration', () {
    expect(podfile, contains("'-framework', 'SQLCipher'"));
    expect(podfile, contains("config.name == 'Debug' ? 'development' : 'production'"));
    expect(entitlements, contains(r'$(APS_ENVIRONMENT)'));
  });

  test('iOS CI builds and runs the SQLCipher simulator smoke test', () {
    expect(iosWorkflow, contains('runs-on: macos-15'));
    expect(iosWorkflow, contains('tool/prepare_ios_project.sh'));
    expect(iosWorkflow, contains('flutter build ios --simulator --no-codesign'));
    expect(
      iosWorkflow,
      contains('integration_test/ios_sqlcipher_smoke_test.dart'),
    );
  });
}
