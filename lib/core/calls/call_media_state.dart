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
