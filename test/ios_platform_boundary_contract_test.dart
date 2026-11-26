import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final backgroundHandler =
      File('lib/core/network/push_background_handler.dart').readAsStringSync();
  final wantedMode =
      File('lib/presentation/state/security_providers.dart').readAsStringSync();
  final database = File('lib/core/storage/database.dart').readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final launchScreen =
      File('ios/Runner/Base.lproj/LaunchScreen.storyboard').readAsStringSync();
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

  test('iOS Wanted Mode is limited to protected-data lock verification', () {
    expect(wantedMode, contains('Platform.isIOS'));
    expect(wantedMode, contains("'getPendingLockChallenge'"));
    expect(wantedMode, contains("'clearPendingLockChallenge'"));
    expect(wantedMode, contains("'isDevicePasscodeAvailable'"));
    expect(appDelegate, contains('protectedDataWillBecomeUnavailableNotification'));
    expect(appDelegate, contains('wantedModePendingLockKey'));
    expect(appDelegate, contains('revealPendingLockChallenge'));
    expect(
      File('lib/presentation/screens/security/security_center_screen.dart')
          .readAsStringSync(),
      contains('iOS does not allow continuous USB, Wi-Fi, Bluetooth or battery monitoring'),
    );
  });

  test('iOS explicitly loads SQLCipher instead of system SQLite', () {
    expect(database, contains('OperatingSystem.iOS'));
    expect(database, contains("DynamicLibrary.open('SQLCipher.framework/SQLCipher')"));
  });

  test('iOS launch screen avoids unsupported runtime attributes', () {
    expect(launchScreen, isNot(contains('userDefinedRuntimeAttributes')));
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
    expect(podfile, contains("config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'"));
    expect(podfile, contains("config.name == 'Debug' ? 'development' : 'production'"));
    expect(entitlements, contains(r'$(APS_ENVIRONMENT)'));
  });

  test('iOS CI builds and runs the SQLCipher simulator smoke test', () {
    expect(iosWorkflow, contains('runs-on: macos-15'));
    expect(iosWorkflow, contains('tool/prepare_ios_project.sh'));
    expect(iosWorkflow, contains('flutter analyze --no-fatal-infos'));
    expect(iosWorkflow, contains('flutter build ios --simulator --no-codesign'));
    expect(
      iosWorkflow,
      contains('integration_test/ios_sqlcipher_smoke_test.dart'),
    );
  });
}
