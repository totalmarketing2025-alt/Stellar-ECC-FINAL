class Contact {
  const Contact({
    required this.nickname,
    required this.identityPublicKeyFingerprint,
    this.verified = false,
  });

  final String nickname;
  final String identityPublicKeyFingerprint; // safety-number source, see Phase 3 §7
  final bool verified;

  Contact copyWith({bool? verified}) => Contact(
        nickname: nickname,
        identityPublicKeyFingerprint: identityPublicKeyFingerprint,
        verified: verified ?? this.verified,
      );
}

enum GroupRole { owner, admin, member }

class GroupMember {
  const GroupMember({
    required this.nickname,
    required this.role,
    required this.joinedAt,
  });

  final String nickname;
  final GroupRole role;
  final DateTime joinedAt;
}
