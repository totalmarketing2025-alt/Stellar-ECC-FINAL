import 'dart:io';

import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';

/// Windows-only system toast notifications. Message previews stay generic so
/// plaintext never appears in the Windows notification center.
class WindowsNotificationService {
  WindowsNotificationService._();

  static final WindowsNotificationService instance =
      WindowsNotificationService._();

  final FlutterLocalNotificationsWindows _plugin =
      FlutterLocalNotificationsWindows();
  Future<void>? _initializing;
  int _lastNotificationId =
      DateTime.now().millisecondsSinceEpoch & 0x7fffffff;

  Future<void> initialize() {
    if (!Platform.isWindows) return Future<void>.value();
    final activeInitialization = _initializing;
    if (activeInitialization != null) return activeInitialization;
    final initialization = _initialize();
    _initializing = initialization;
    return initialization.catchError((Object error, StackTrace stackTrace) {
      _initializing = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<void> _initialize() async {
    const settings = WindowsInitializationSettings(
      appName: 'Stellar ECC',
      appUserModelId: 'IWorks.StellarECC',
      guid: 'a2218824-27b4-4f54-a72b-f199e7d4f028',
    );
    await _plugin.initialize(settings);
  }

  Future<void> showIncomingMessage() async {
    await _show(
      title: 'Stellar ECC',
      body: 'You have a new secure message.',
    );
  }

  Future<void> showIncomingCall({required bool video}) async {
    await _show(
      title: 'Stellar ECC',
      body: video ? 'Incoming video call' : 'Incoming voice call',
      duration: WindowsNotificationDuration.long,
    );
  }

  Future<void> _show({
    required String title,
    required String body,
    WindowsNotificationDuration? duration,
  }) async {
    if (!Platform.isWindows) return;
    try {
      await initialize();
      final id = _nextNotificationId();
      await _plugin.show(
        id,
        title,
        body,
        details: WindowsNotificationDetails(duration: duration),
      );
    } catch (error) {
      // A disabled Windows notification setting must not interrupt chat/calls.
      print('WINDOWS_NOTIFICATION_FAILED: $error');
    }
  }

  int _nextNotificationId() {
    _lastNotificationId = (_lastNotificationId + 1) & 0x7fffffff;
    if (_lastNotificationId == 0) _lastNotificationId = 1;
    return _lastNotificationId;
  }
}
