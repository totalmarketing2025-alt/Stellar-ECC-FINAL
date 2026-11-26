import UIKit
import Flutter
import LocalAuthentication

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var privacyBlurView: UIVisualEffectView?
  private var wantedModeChannel: FlutterMethodChannel?
  private var protectedDataObservers: [NSObjectProtocol] = []
  private let wantedModeEnabledKey = "stellar.wantedMode.enabled"
  private let wantedModePendingLockKey = "stellar.wantedMode.pendingProtectedDataLock"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "ecc.stellar.app/wanted_mode_monitor",
        binaryMessenger: controller.binaryMessenger
      )
      wantedModeChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(FlutterError(code: "UNAVAILABLE", message: "App delegate unavailable", details: nil))
          return
        }
        switch call.method {
        case "isDevicePasscodeAvailable":
          let context = LAContext()
          var error: NSError?
          result(context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error))
        case "setWipeEnabled":
          let arguments = call.arguments as? [String: Any]
          let enabled = arguments?["enabled"] as? Bool ?? false
          UserDefaults.standard.set(enabled, forKey: self.wantedModeEnabledKey)
          if !enabled {
            UserDefaults.standard.removeObject(forKey: self.wantedModePendingLockKey)
            self.stopProtectedDataMonitoring()
          }
          result(true)
        case "startMonitoring":
          guard UserDefaults.standard.bool(forKey: self.wantedModeEnabledKey) else {
            result(false)
            return
          }
          self.startProtectedDataMonitoring()
          result(true)
        case "stopMonitoring":
          self.stopProtectedDataMonitoring()
          result(true)
        case "getPendingLockChallenge":
          result(UserDefaults.standard.bool(forKey: self.wantedModePendingLockKey))
        case "revealPendingLockChallenge":
          let pending = UserDefaults.standard.bool(forKey: self.wantedModePendingLockKey)
          if pending { self.removePrivacyBlur() }
          result(pending)
        case "clearPendingLockChallenge":
          UserDefaults.standard.removeObject(forKey: self.wantedModePendingLockKey)
          self.removePrivacyBlur()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      if UserDefaults.standard.bool(forKey: wantedModeEnabledKey) {
        startProtectedDataMonitoring()
      }
      if UserDefaults.standard.bool(forKey: wantedModePendingLockKey) {
        addPrivacyBlur()
      }
    }
    return launched
  }

  private func startProtectedDataMonitoring() {
    guard protectedDataObservers.isEmpty else { return }
    let center = NotificationCenter.default
    let willLock = center.addObserver(
      forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self,
            UserDefaults.standard.bool(forKey: self.wantedModeEnabledKey) else { return }
      UserDefaults.standard.set(true, forKey: self.wantedModePendingLockKey)
    }
    protectedDataObservers.append(willLock)
  }

  private func stopProtectedDataMonitoring() {
    for observer in protectedDataObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    protectedDataObservers.removeAll()
  }

  // iOS has no screenshot-PREVENTION API (see Phase 8 platform-limitation
  // note) — the closest available mitigation is blurring content the
  // instant the app is about to be backgrounded, so it isn't visible in
  // the app-switcher snapshot. Actual screenshot events are detected and
  // disclosed to the chat participant from the Dart layer via
  // UIApplication.userDidTakeScreenshotNotification (ScreenshotObserver).
  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    addPrivacyBlur()
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    if UserDefaults.standard.bool(forKey: wantedModePendingLockKey) {
      addPrivacyBlur()
      return
    }
    removePrivacyBlur()
  }

  private func addPrivacyBlur() {
    guard privacyBlurView == nil, let window = self.window else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blur.tag = 999
    window.addSubview(blur)
    privacyBlurView = blur
  }

  private func removePrivacyBlur() {
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }
}
