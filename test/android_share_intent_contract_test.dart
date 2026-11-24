import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final nativeActivity =
      File('android/app/src/main/kotlin/ecc/stellar/app/MainActivity.kt')
          .readAsStringSync();
  final app = File('lib/app/app.dart').readAsStringSync();
  final router = File('lib/app/router.dart').readAsStringSync();
  final shareScreen =
      File('lib/presentation/screens/share/share_target_screen.dart')
          .readAsStringSync();
  final translations =
      File('lib/l10n/stellar_translations.dart').readAsStringSync();

  test('Android advertises single and multiple file share targets', () {
    expect(manifest, contains('android.intent.action.SEND"'));
    expect(manifest, contains('android.intent.action.SEND_MULTIPLE"'));
    expect(manifest, contains('android:mimeType="*/*"'));
  });

  test('native bridge stages bounded files and preserves share text', () {
    expect(nativeActivity, contains('MAX_SHARED_FILE_BYTES = 8L * 1024L * 1024L'));
    expect(nativeActivity, contains('openInputStream(uri)'));
    expect(nativeActivity, contains('takePendingSharedContent'));
    expect(nativeActivity, contains('Intent.EXTRA_TEXT'));
    expect(nativeActivity, contains('sharedContentAvailable'));
  });

  test('shared items wait for unlock and route through the conversation picker', () {
    expect(app, contains('ShareIntentBridge.instance.initialize()'));
    expect(app, contains('ref.read(isUnlockedProvider)'));
    expect(app, contains("go('/share', extra: items)"));
    expect(router, contains("path: '/share'"));
  });

  test('chosen chats send shared files through encrypted attachment messaging', () {
    expect(shareScreen, contains('repository.sendDirectMessage'));
    expect(shareScreen, contains('attachmentBytes: bytes'));
    expect(shareScreen, contains('attachmentMimeType: item.mimeType'));
    expect(shareScreen, contains('target.defaultTtlSeconds'));
  });

  test('share screen labels are present in supported translations', () {
    expect(translations, contains('"Share to Stellar": "Сподели во Stellar"'));
    expect(translations, contains('"Share to Stellar": "Ndaj në Stellar"'));
    expect(translations, contains('"Share to Stellar": "Поделиться через Stellar"'));
  });
}
