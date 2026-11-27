import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('account setup and recovery use the shared Stellar background', () {
    final screens = [
      'lib/presentation/screens/onboarding/identity_creation_screen.dart',
      'lib/presentation/screens/onboarding/choose_nickname_screen.dart',
      'lib/presentation/screens/onboarding/recovery_setup_screen.dart',
      'lib/presentation/screens/onboarding/recovery_restore_screen.dart',
      'lib/presentation/screens/onboarding/app_lock_setup_screen.dart',
      'lib/presentation/screens/onboarding/pin_unlock_screen.dart',
    ];

    for (final path in screens) {
      expect(source(path), contains('StellarOnboardingBackground('),
          reason: path);
    }

    final background = source(
      'lib/presentation/widgets/stellar_onboarding_background.dart',
    );
    expect(background, contains('assets/images/stellar_background.jpg'));
    expect(background, contains('BoxFit.cover'));
  });

  test('keyboard-sensitive forms can scroll instead of overflowing', () {
    final scrollableScreens = [
      'lib/presentation/screens/onboarding/choose_nickname_screen.dart',
      'lib/presentation/screens/onboarding/recovery_setup_screen.dart',
      'lib/presentation/screens/onboarding/recovery_restore_screen.dart',
      'lib/presentation/screens/onboarding/app_lock_setup_screen.dart',
      'lib/presentation/screens/onboarding/pin_unlock_screen.dart',
    ];

    for (final path in scrollableScreens) {
      expect(source(path), contains('SingleChildScrollView('), reason: path);
    }

    expect(
      source('lib/presentation/screens/groups/new_group_screen.dart'),
      contains('body: ListView('),
    );
    expect(
      source('lib/presentation/screens/moderation/moderation_room_screen.dart'),
      contains('child: SingleChildScrollView('),
    );
  });
}
