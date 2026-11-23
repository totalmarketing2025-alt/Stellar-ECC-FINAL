enum GroupCallPhase { ringing, connecting, connected, ended, failed }
enum GroupMemberCallState { invited, joining, connected, left, failed }

class GroupCallRoom {
  const GroupCallRoom({
    required this.roomId,
    required this.chatId,
    required this.membersDigest,
    required this.members,
    required this.inviter,
    required this.video,
    required this.phase,
    required this.joined,
    required this.connectionStates,
    required this.remoteVideo,
    required this.localVideo,
    this.joinedAt,
  });

  final String roomId;
  final String chatId;
  final String membersDigest;
  final List<String> members;
  final String inviter;
  final bool video;
  final GroupCallPhase phase;
  final Set<String> joined;
  final Map<String, GroupMemberCallState> connectionStates;
  final Map<String, bool> remoteVideo;
  final bool localVideo;
  final DateTime? joinedAt;

  bool get isIncoming => phase == GroupCallPhase.ringing;
  int get connectedPeers => connectionStates.values
      .where((state) => state == GroupMemberCallState.connected).length;
  int get participantCount => 1 + connectedPeers;

  GroupCallRoom copyWith({
    GroupCallPhase? phase,
    Set<String>? joined,
    Map<String, GroupMemberCallState>? connectionStates,
    Map<String, bool>? remoteVideo,
    bool? localVideo,
    DateTime? joinedAt,
  }) => GroupCallRoom(
    roomId: roomId,
    chatId: chatId,
    membersDigest: membersDigest,
    members: members,
    inviter: inviter,
    video: video,
    phase: phase ?? this.phase,
    joined: joined ?? this.joined,
    connectionStates: connectionStates ?? this.connectionStates,
    remoteVideo: remoteVideo ?? this.remoteVideo,
    localVideo: localVideo ?? this.localVideo,
    joinedAt: joinedAt ?? this.joinedAt,
  );
}
