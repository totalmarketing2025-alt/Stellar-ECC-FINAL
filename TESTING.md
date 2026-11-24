# Stellar ECC test and validation guide

This guide reflects the Android-first application and current `main` code. CI checks code and build contracts; it does not prove that voice/video calls, push delivery or Cloudflare services work end-to-end on real devices.

## Local Android checks

Run from the repository root with the Flutter version used by CI (Flutter 3.27.4):

```sh
flutter pub get
flutter gen-l10n
flutter analyze
flutter test
flutter build apk --debug
```

Run Android native unit tests with:

```sh
cd android
./gradlew :app:testDebugUnitTest --no-daemon
```

The debug APK is written to `build/app/outputs/flutter-apk/app-debug.apk`. This is a test build, not a production release.

## GitHub Actions

- [Internal Audit](.github/workflows/internal-audit.yml) generates Flutter localizations, runs `flutter analyze`, and runs `flutter test`.
- [GUARD Phase 05 verification](.github/workflows/guard-phase05.yml) runs GUARD backend tests, Flutter GUARD contract/UI tests, builds a debug APK and runs a native Android policy test.
- [Group call validation](.github/workflows/group-call-validation.yml) runs localization generation, Flutter analysis/tests, Android debug compilation and a native group-call wake test on pull requests to `main`, pushes to `main`, and the group-call feature branch.

Recent successful runs validate only the commit and checks shown in GitHub Actions. CI does not confirm live calling, push delivery, release signing, or production Worker configuration.

## Live service configuration

The app uses the Cloudflare Worker URLs configured in `lib/presentation/state/app_providers.dart`:

- Directory: `https://stellar-ecc-directory.totalmarketing2025.workers.dev`
- Relay WebSocket: `wss://stellar-ecc-final.totalmarketing2025.workers.dev/v1/connect`

These are configured endpoints; CI tests do not guarantee that a deployed Worker, TURN credentials, FCM registration or current production secrets are healthy. Check the Directory and Relay `/health` endpoints and inspect the relevant deployment workflows before a live test. Push delivery also depends on valid Firebase configuration and the required Worker secrets.

## Manual test matrix

Use at least two Android phones with separate test identities for one-to-one messaging/calls. Use three or four phones in the same group chat to verify group mesh behavior.

- Send and receive text, media and expiring messages with both phones online; repeat with one device offline and reconnecting.
- Test 1:1 voice, 1:1 video, voice-to-video and video-to-voice switching; verify camera permission denial leaves audio usable.
- Start group voice and group video from a group chat. Test adding a participant from an active 1:1 call, participant decline/leave, camera/microphone controls, Wi-Fi-to-mobile handoff, TURN-only connectivity and reconnect.
- Test incoming group invitations while Stellar is open, backgrounded, screen-locked and removed from recents. Group calls do not yet have the same verified native background ringing/lock-screen flow as 1:1 calls; treat those cases as a known limitation until verified on devices.
- Change Android system language to English, Macedonian, Albanian and Russian. Verify app UI, incoming-call UI, message notifications, call notifications, group-call notifications, Wanted Mode alerts and notification-channel names.
- Test Wanted Mode only on a disposable device identity. Verify enabled/disabled notifications, 10-second PIN expiry, low-battery threshold below 20%, rearming at 25%, reboot recovery, lock-only and manual local wipe.
- Test GUARD only with disposable accounts in staging. All reports remain pending until an authorized moderator reviews them; a nine-digit code identifies an account but is not evidence of theft.

Record Android version, device model, system language, network type, Worker deployment version, steps and logs for every failed case. Do not treat a green CI build as a replacement for this matrix.

## Release and platform limits

- Android compilation and targeting use API level 36. This meets Google Play's current Android 16 submission target, but it does not replace Play Console validation or real-device testing of Android 16 behavior.

- Release builds require a production keystore configured through the `STELLAR_RELEASE_STORE_FILE`, `STELLAR_RELEASE_STORE_PASSWORD`, `STELLAR_RELEASE_KEY_ALIAS` and `STELLAR_RELEASE_KEY_PASSWORD` environment variables. CI builds and uploads a clearly labeled debug APK only.
- This repository does not currently contain `ios/Runner.xcodeproj/project.pbxproj`. An iOS build is therefore not validated by the current project.
- Group calls use a small peer-to-peer mesh capped at four participants. Do not infer four-device performance or production reliability from unit tests and successful compilation alone.
