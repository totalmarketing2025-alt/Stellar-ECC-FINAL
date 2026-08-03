enum CallState { ringing, connecting, connected, ended, failed }
enum CallKind { voice, video }

class CallSession {
  const CallSession({
    required this.callId,
    required this.chatId,
    required this.kind,
    required this.state,
    this.connectedAt,
    this.remoteNickname,
    this.isSafetyNumberVerified = false,
  });

  final String callId;
  final String chatId;
  final CallKind kind;
  final CallState state;
  final DateTime? connectedAt;
  final String? remoteNickname;
  final bool isSafetyNumberVerified;

  Duration get elapsed =>
      connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);

  CallSession copyWith({CallState? state, DateTime? connectedAt}) => CallSession(
        callId: callId,
        chatId: chatId,
        kind: kind,
        state: state ?? this.state,
        connectedAt: connectedAt ?? this.connectedAt,
        remoteNickname: remoteNickname,
        isSafetyNumberVerified: isSafetyNumberVerified,
      );
}
