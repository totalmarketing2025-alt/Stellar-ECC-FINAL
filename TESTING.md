# Testing Stellar ECC — What Works Right Now vs What Needs Setup

## Phone-only install (no PC/laptop needed)

A GitHub Actions workflow is already included at
`.github/workflows/build-apk.yml` — it builds the APK on GitHub's own
servers. Your phone only needs to get the code onto GitHub and then
download the finished file; it never compiles anything itself.

**1. Get a code editor + git app on your phone (both free):**
   - Android: install **Termux** from F-Droid (not the outdated Play Store
     version) — [f-droid.org/packages/com.termux](https://f-droid.org/packages/com.termux)

**2. Create a GitHub account and a new empty repository**, from your
   phone's browser at github.com — tap "New repository," name it e.g.
   `stellar-ecc`, leave it empty (no README), create it. Keep the page
   open, you'll need the repo URL in step 4.

**3. Get the project files onto your phone and unzip them.** Download
   `stellar_ecc_complete.zip` to your phone, then extract it — Android's
   built-in Files app can usually extract zips directly (tap the file,
   "Extract"), or use Termux: `unzip stellar_ecc_complete.zip`.

**4. Push the code to GitHub using Termux:**
   ```
   pkg install git
   termux-setup-storage
   cd storage/downloads/stellar_ecc_complete   # wherever you extracted it
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/YOUR_USERNAME/stellar-ecc.git
   git push -u origin main
   ```
   GitHub will prompt for a username + password — use a **Personal Access
   Token** instead of your real password (GitHub no longer accepts
   account passwords for git operations): on github.com, go to Settings →
   Developer settings → Personal access tokens → generate one with `repo`
   scope, and paste it in when git asks for a password.

**5. Watch it build.** As soon as the push lands, go to your repo's
   **Actions** tab in the GitHub app or mobile browser — you'll see "Build
   APK" running (takes a few minutes the first time).

**6. Download the APK.** Once it finishes (green checkmark), open that
   run, scroll to **Artifacts**, and download `stellar-ecc-debug-apk` —
   it's a zip containing `app-debug.apk`. Extract that on your phone.

**7. Install it.** Open the extracted `app-debug.apk` from Downloads —
   Android will prompt to allow installing from this source (expected for
   an unsigned debug build, not a sign of a problem) — tap through and
   install.

From then on, any time you want a fresh build after changes, just `git
add . && git commit -m "..." && git push` from Termux and repeat steps
5–7.

---

## Fastest path to an installable APK (if you do have a PC)

```bash
cd stellar_ecc_complete
flutter pub get
flutter build apk --debug
```

Output: `build/app/outputs/flutter-apk/app-debug.apk` — copy to your phone
and install, or run `flutter install` with the phone connected via USB
debugging (Developer Options > USB debugging must be on).

## What you can actually test today, fully offline

- Splash → onboarding flow (identity key generation is real, happens on-device)
- Choosing an @nickname
- App lock setup (biometric/PIN — real `local_auth` calls)
- Chat list UI, creating a new direct chat or group (rows persist to a real
  encrypted local SQLCipher database)
- Chat window: composing, TTL picker, reply, reactions, attach-file picker
- **Security Center**: score calculation, fingerprint display (a real
  SHA-256 fingerprint of your actual generated identity key), QR code
  generation, panic lock/wipe
- Settings screen toggles

## What will visibly fail, and why that's expected

- **Sending a message** will show status "failed" on the bubble. There is
  no relay server deployed at the placeholder `wss://relay.stellarecc.example`
  URL — the relay server code exists (see the Phase 9 doc / `relay-server/`
  design) but was never stood up on real infrastructure. This is the
  correct error-handling path working, not a crash.
- **Voice/video calls** will fail to connect for the same reason — no
  signaling relay is reachable.
- **Push notifications** won't arrive — `google-services.json` /
  `GoogleService-Info.plist` contain structurally-correct placeholder
  values, not a real Firebase project's credentials. `main.dart` now
  catches this gracefully at startup rather than crashing.

## Known gaps between this codebase and a green CI build

1. **`android/gradle/wrapper/gradle-wrapper.jar` is missing.** It's a
   binary fetched from `services.gradle.org`, which this environment had
   no network access to download. `gradlew`/`gradlew.bat` and
   `gradle-wrapper.properties` are in place. Fix, one-time, on a machine
   with Gradle installed:
   ```
   cd android && gradle wrapper --gradle-version 8.7
   ```
   Alternatively, just run `flutter build apk` — Flutter's tooling
   frequently bootstraps a working Gradle wrapper automatically on first
   run even when this file is absent; try it before assuming you need the
   manual fix above.

2. **`ios/Runner.xcodeproj/project.pbxproj` was never generated.** This is
   the actual Xcode project file (binary-ish plist format, normally
   produced by `flutter create`, not something hand-written). Without it
   Xcode can't open the iOS project at all yet — everything else iOS-side
   (Info.plist, entitlements, storyboards, AppDelegate.swift, app icons)
   is real and in place waiting for it. Fix: run `flutter create --platforms=ios .`
   from the project root on a machine with Flutter installed — it detects
   the existing `ios/Runner/` contents and fills in just the missing
   project file rather than overwriting your code.

3. **`libsignal_protocol_dart` API surface** — written from memory,
   unverified against the real package (no network access here to check
   it). If `flutter analyze` flags a method signature mismatch in
   `core/crypto/signal_stores.dart`, `session_manager.dart`, or
   `group_crypto.dart`, paste me the exact error and I'll fix it against
   the real API.

4. **No live backend.** Messaging/calls/push need the relay server
   deployed somewhere reachable and `wss://relay.stellarecc.example`
   (searched in `core/network/relay_client.dart` and
   `core/calls/call_service.dart`) pointed at it.

## If you want to add something next

Good next additions, roughly in order of "most useful for testing on a
single phone" to "needs a second phone / server":
- A local mock/loopback relay so you can send a message to yourself and
  see the full encrypt → store → decrypt round trip without a real server
- Deploying `relay-server/` (Phase 9) somewhere reachable (even a cheap
  VPS) and pointing the app at it, so two phones can actually message
  each other
- Running `flutterfire configure` against a real Firebase project to
  light up push notifications
- Filling in the `ios/Runner.xcodeproj` gap so you can test on iPhone too
