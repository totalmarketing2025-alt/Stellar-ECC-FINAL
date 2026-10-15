import 'dart:convert';

/// Internal call-history events transported as ordinary Signal-encrypted
/// direct messages. Unrecognised or malformed text is never treated as an
/// event.
class CallEventPayload {
  const CallEventPayload({
    required this.callId,
    required this.chatId,
    required this.phase,
    required this.kind,
    this.outcome,
    this.durationSeconds,
  });

  static const String prefix = 'STELLAR_CALL_EVENT_V1:';

  static const Set<String> outcomes = {
    'completed',
    'declined',
    'no_answer',
    'cancelled',
    'failed',
  };

  final String callId;
  final String chatId;
  final String phase;
  final String kind;
  final String? outcome;
  final int? durationSeconds;

  String encode() {
    final value = <String, Object?>{
      'v': 1,
      'callId': callId,
      'chatId': chatId,
      'phase': phase,
      'kind': kind,
      if (outcome != null) 'outcome': outcome,
      if (durationSeconds != null) 'durationSeconds': durationSeconds,
    };
    return '$prefix${jsonEncode(value)}';
  }

  static CallEventPayload? tryParse(String text) {
    if (!text.startsWith(prefix)) return null;

    try {
      final decoded = jsonDecode(text.substring(prefix.length));
      if (decoded is! Map<String, dynamic>) return null;

      if (decoded['v'] != 1) return null;

      final callId = decoded['callId'];
      final chatId = decoded['chatId'];
      final phase = decoded['phase'];
      final kind = decoded['kind'];
      final outcome = decoded['outcome'];
      final duration = decoded['durationSeconds'];

      if (callId is! String ||
          !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(callId)) {
        return null;
      }

      if (chatId is! String || chatId.trim().isEmpty) return null;
      if (phase != 'started' && phase != 'ended') return null;
      if (kind != 'voice' && kind != 'video') return null;

      if (phase == 'started' && (outcome != null || duration != null)) {
        return null;
      }

      if (phase == 'ended' &&
          (outcome is! String || !outcomes.contains(outcome))) {
        return null;
      }

      if (duration != null &&
          (duration is! int || duration < 0 || duration > 604800)) {
        return null;
      }

      return CallEventPayload(
        callId: callId,
        chatId: chatId,
        phase: phase,
        kind: kind,
        outcome: outcome as String?,
        durationSeconds: duration as int?,
      );
    } catch (_) {
      return null;
    }
  }
}
