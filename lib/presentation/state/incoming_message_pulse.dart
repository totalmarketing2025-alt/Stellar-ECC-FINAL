import 'package:flutter/foundation.dart';

/// Foreground-only visual signal. No message content or sender data is exposed.
final ValueNotifier<int> stellarIncomingMessagePulse = ValueNotifier<int>(0);

void notifyStellarIncomingMessage() {
  stellarIncomingMessagePulse.value++;
}
