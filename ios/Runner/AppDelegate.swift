import UIKit
import Flutter
import Firebase

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var privacyBlurView: UIVisualEffectView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // iOS has no screenshot-PREVENTION API (see Phase 8 platform-limitation
  // note) — the closest available mitigation is blurring content the
  // instant the app is about to be backgrounded, so it isn't visible in
  // the app-switcher snapshot. Actual screenshot events are detected and
  // disclosed to the chat participant from the Dart layer via
  // UIApplication.userDidTakeScreenshotNotification (ScreenshotObserver).
  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard let window = self.window else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    blur.frame = window.bounds
    blur.tag = 999
    window.addSubview(blur)
    privacyBlurView = blur
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }
}
