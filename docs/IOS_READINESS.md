# Stellar ECC iOS readiness

## Current status

The Flutter application is intended to share its Dart UI, Signal protocol,
relay, and local data layer across Android and iOS. The repository currently
contains selected iOS Runner resources, but not a complete Xcode project. The
`feature/ios-platform` branch provides a repeatable macOS bootstrap and an iOS
simulator CI workflow. An iOS release is not ready until the simulator build,
SQLCipher smoke test, and physical-device checks pass.

## Shared capabilities to validate on iPhone

- Onboarding, encrypted 1:1 chats, attachment transfers, delivery/read states,
  and expiry behavior.
- Voice recording and media picking through the existing Flutter plugins.
- Foreground 1:1 and group audio/video using WebRTC.
- Face ID app lock, Keychain storage, app-switcher privacy blur, and local wipe.

The iOS Runner already declares camera, microphone, photo library, Face ID,
and contacts usage descriptions. These do not replace runtime permission and
device testing.

## iOS-only implementation still required

1. Register bundle ID `ecc.stellar.app` in the Firebase project and replace the
   placeholder values in `lib/app/firebase_options.dart` and
   `ios/Runner/GoogleService-Info.plist`. Configure APNs credentials and the
   Xcode Push Notifications capability before testing FCM on a real device.
2. Implement PushKit and CallKit for incoming calls while locked/backgrounded,
   including native call actions and server-side VoIP token registration.
   Current custom call channels are implemented only in Android's MainActivity.
3. Implement iOS background expiry scheduling or explicitly guarantee secure
   cleanup on app resume/start. There is no iOS `BGTaskScheduler` registration;
   Dart timers are foreground best-effort.
4. Add iOS share-sheet intake if receiving files from other apps is required.
   The current share-intent native channel is Android-only; in-app media picking
   is a separate supported flow.
5. Keep Wanted Mode hardware monitoring Android-only. iOS may expose app PIN,
   Face ID, and user-triggered local wipe, but must not claim Android's
   continuous hardware-event monitoring or unattended wipe behavior.
6. Confirm `PRAGMA cipher_version` at runtime on an iOS simulator and physical
   iPhone. Debug and Release xcconfigs select the SQLCipher framework because
   Firebase Messaging may also link regular SQLite.

## Build and verification

On macOS with Xcode and Flutter 3.27.4:

```sh
bash tool/prepare_ios_project.sh
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
flutter build ios --simulator --no-codesign
flutter test integration_test/ios_sqlcipher_smoke_test.dart -d <iPhone-simulator-id>
```

GitHub Actions also builds the iOS simulator app and runs the SQLCipher smoke
test on macOS. Android APK and Windows release builds remain separate CI checks
on this branch so shared Dart changes are covered before any merge.

## Release prerequisites

- A valid Apple Developer Team, signing certificate, provisioning profile, and
  App Store Connect record for bundle ID `ecc.stellar.app`.
- Production APNs key and Firebase registration for the iOS app.
- Physical-device checks for permission denial/recovery, audio route changes,
  foreground/background/locked call behavior, push delivery, attachment sizes,
  SQLCipher startup, local wipe, and VoiceOver/layout behavior.
