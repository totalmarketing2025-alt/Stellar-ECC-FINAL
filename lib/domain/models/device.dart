class LinkedDevice {
  const LinkedDevice({
    required this.deviceId,
    required this.label,
    required this.lastActive,
    required this.isCurrentDevice,
  });

  final int deviceId;
  final String label; // e.g. "iPhone 15 Pro" or "Pixel 8" — set at link time, never a persistent ad-id
  final DateTime lastActive;
  final bool isCurrentDevice;
}

class ActiveSession {
  const ActiveSession({
    required this.contactNickname,
    required this.deviceId,
    required this.establishedAt,
    required this.isVerified,
  });

  final String contactNickname;
  final int deviceId;
  final DateTime establishedAt;
  final bool isVerified; // safety number compared out-of-band, Phase 3 §7
}
