enum CallState { ringing, answering, connecting, connected, ended, failed }
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
    this.localVideoEnabled = false,
    this.remoteVideoEnabled = false,
  });

  final String callId;
  final String chatId;
  final CallKind kind;
  final CallState state;
  final DateTime? connectedAt;
  final String? remoteNickname;
  final bool isSafetyNumberVerified;
  /// Actual outgoing camera state; independent of the initial call kind.
  final bool localVideoEnabled;
  /// Authenticated camera state last advertised by the other participant.
  final bool remoteVideoEnabled;

  Duration get elapsed =>
      connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);

  CallSession copyWith({
    CallState? state,
    DateTime? connectedAt,
    bool? localVideoEnabled,
    bool? remoteVideoEnabled,
  }) => CallSession(
        callId: callId,
        chatId: chatId,
        kind: kind,
        state: state ?? this.state,
        connectedAt: connectedAt ?? this.connectedAt,
        remoteNickname: remoteNickname,
        isSafetyNumberVerified: isSafetyNumberVerified,
        localVideoEnabled: localVideoEnabled ?? this.localVideoEnabled,
        remoteVideoEnabled: remoteVideoEnabled ?? this.remoteVideoEnabled,
      );
}
