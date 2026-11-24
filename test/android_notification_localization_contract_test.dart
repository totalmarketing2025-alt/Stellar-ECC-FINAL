import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const locales = <String>[
    'values',
    'values-mk',
    'values-sq',
    'values-ru',
  ];
  const requiredResources = <String>[
    'app_name',
    'notification_new_message',
    'notification_channel_messages',
    'notification_channel_incoming_calls',
    'notification_channel_incoming_calls_description',
    'notification_incoming_voice_call',
    'notification_incoming_video_call',
    'notification_answer',
    'notification_reject',
    'notification_join',
    'notification_decline',
    'notification_channel_group_calls',
    'notification_incoming_group_call',
    'notification_channel_active_group_calls',
    'notification_group_call_in_progress',
    'notification_channel_active_calls',
    'notification_channel_active_calls_description',
    'notification_stellar_call_fallback',
    'notification_stellar_voice_call',
    'notification_stellar_video_call',
    'notification_wanted_channel',
    'notification_wanted_channel_description',
    'notification_wanted_power_channel',
    'notification_wanted_power_channel_description',
    'notification_wanted_event_channel',
    'notification_wanted_event_channel_description',
    'notification_wanted_pin_title',
    'notification_wanted_battery_low',
    'notification_wanted_category_usb',
    'notification_wanted_category_bluetooth',
    'notification_wanted_category_network',
    'notification_wanted_category_power',
    'notification_wanted_action_connected',
    'notification_wanted_action_disconnected',
    'notification_wanted_action_changed',
    'notification_wanted_action_low',
    'notification_wanted_event_description',
    'notification_wanted_event_summary_one',
    'notification_wanted_event_summary_many',
    'notification_wanted_wipe_pending',
    'notification_wanted_storage_corrupted',
    'notification_wanted_expired_count',
    'notification_wanted_active',
    'notification_contact_avatar',
    'notification_call_ringing',
  ];

  test('every Android notification resource exists in every supported locale', () {
    for (final locale in locales) {
      final xml = File('android/app/src/main/res/$locale/strings.xml')
          .readAsStringSync();
      for (final name in requiredResources) {
        expect(xml, contains('<string name="$name">'), reason: '$locale/$name');
      }
    }
  });

  test('native notification surfaces use Android localized resources', () {
    final files = <String>[
      'android/app/src/main/kotlin/ecc/stellar/app/StellarFirebaseMessagingService.kt',
      'android/app/src/main/kotlin/ecc/stellar/app/StellarPushBackgroundRunner.kt',
      'android/app/src/main/kotlin/ecc/stellar/app/WantedModeForegroundService.kt',
      'android/app/src/main/kotlin/ecc/stellar/app/calls/StellarCallForegroundService.kt',
      'android/app/src/main/kotlin/ecc/stellar/app/calls/StellarGroupCallForegroundService.kt',
      'android/app/src/main/kotlin/ecc/stellar/app/calls/StellarGroupCallNotification.kt',
      'android/app/src/main/kotlin/ecc/stellar/app/calls/StellarIncomingCallNotification.kt',
      'android/app/src/main/kotlin/ecc/stellar/app/calls/StellarIncomingCallActivity.kt',
    ];
    for (final path in files) {
      expect(File(path).readAsStringSync(), contains('R.string.'));
    }
  });
}
