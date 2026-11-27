import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/windows/windows_notification_service.dart';

/// Local incoming-message signal. Windows also raises a generic toast; no
/// message content or sender data is exposed in the notification.
final ValueNotifier<int> stellarIncomingMessagePulse = ValueNotifier<int>(0);

void notifyStellarIncomingMessage() {
  stellarIncomingMessagePulse.value++;
  if (Platform.isWindows) {
    unawaited(WindowsNotificationService.instance.showIncomingMessage());
  }
}
