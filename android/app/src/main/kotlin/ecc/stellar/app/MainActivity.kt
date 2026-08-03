package ecc.stellar.app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/**
 * FLAG_SECURE is applied window-wide here rather than per-screen in Dart,
 * since it's an Android WindowManager flag, not something the Flutter
 * widget tree can express directly. This blocks screenshots, screen
 * recording, and recent-apps thumbnails system-wide for the whole app —
 * matches the "prevent screenshots where supported by the OS" requirement
 * and the platform-limitation note from Phase 7 (no iOS equivalent exists).
 *
 * If a future screen genuinely needs to opt out (e.g., a QR code the user
 * WANTS to screenshot for account recovery), toggle the flag off/on around
 * that specific screen via a MethodChannel call rather than removing this
 * default-on baseline.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }
}
