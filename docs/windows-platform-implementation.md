# Windows platform implementation

This branch contains Windows-only behavior for desktop notifications, call
ringing, and permission guidance. Android Kotlin code and iOS native code are
not changed. Shared Dart entry points call the Windows adapters only when
`Platform.isWindows` is true.

## Included

- Incoming messages create separate Windows toast notifications. Toast text is
  generic and does not expose message contents or sender names.
- Incoming voice/video offers create a toast and play a bundled Windows-only
  ringtone. Outgoing calls play a separate ringback tone. Existing call
  cleanup paths stop either sound on answer, reject, timeout, failure, or end.
- The Windows runner registers a stable AppUserModelID and Start Menu shortcut
  required by classic desktop toast notifications.
- Settings links directly to Windows notification, microphone, and camera
  privacy pages.
- Firebase Messaging is skipped on Windows because the configured FlutterFire
  plugin has no Windows implementation. Windows receives messages and call
  signals over Stellar's live relay connection.

## Windows permission setup

In Windows Settings, enable **Notifications** for Stellar ECC and allow desktop
apps to access the microphone and camera. The app's Settings page opens these
Windows pages. Voice/video calls continue to use the existing WebRTC media
capture path; Windows may also require selecting an available device in system
settings.

## Delivery boundary

Toasts and ringing work while Stellar is running and connected to the relay,
including when its window is minimized. A fully closed app cannot receive a
relay event. Closed-app delivery requires a Windows push channel (WNS) and
backend support to register and send to its channel URI; that service is not
part of this branch. The Windows workflow must build and package the desktop
installer before release.
