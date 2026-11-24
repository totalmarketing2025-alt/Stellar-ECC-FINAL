import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Call kind is fixed for the lifetime of a call and binds its signed signals.
/// Camera state is independent and can change without creating a new call.
class CallMediaState {
  const CallMediaState({required this.enabled, required this.revision});

  final bool enabled;
  final int revision;

  static CallMediaState? parse(Map<String, dynamic> payload, int lastRevision) {
    final enabled = payload['videoEnabled'];
    final revision = payload['mediaRevision'];
    if (enabled is! bool || revision is! int ||
        revision <= lastRevision || revision > 0x7fffffff) {
      return null;
    }
    return CallMediaState(enabled: enabled, revision: revision);
  }
}

/// Existing 1:1 capture borrowed by the group mesh during an in-call upgrade.
/// The original CallService owns these streams until the upgrade completes.
class CallGroupMedia {
  const CallGroupMedia({
    required this.audioStream,
    this.videoStream,
  });

  final MediaStream audioStream;
  final MediaStream? videoStream;
}
