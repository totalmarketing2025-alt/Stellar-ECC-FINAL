import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Small, identity-authenticated mesh rooms. Never allow a room to expand
/// beyond four total devices without a different, audited media architecture.
class GroupCallProtocol {
  static const maxParticipants = 4;
  static const types = <String>{
    'group-invite', 'group-join', 'group-reject', 'group-leave',
    'group-offer', 'group-answer', 'group-ice', 'group-media',
  };

  static String normalize(String nickname) =>
      nickname.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();

  static List<String> members(Iterable<String> nicknames) =>
      nicknames.map(normalize).where((name) => name.isNotEmpty).toSet().toList()
        ..sort();

  static String membershipDigest(Iterable<String> nicknames) =>
      sha256.convert(utf8.encode(jsonEncode(members(nicknames)))).toString();

  static bool validMembers(List<String> names, String localNickname) =>
      names.length >= 2 && names.length <= maxParticipants &&
      names.contains(normalize(localNickname));

  static bool isValidGroupSignal(Map<String, dynamic> payload) {
    final type = payload['type'];
    final roomId = payload['roomId'];
    final digest = payload['membersDigest'];
    if (type is! String || !types.contains(type) ||
        roomId is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(roomId) ||
        payload['callId'] != roomId ||
        digest is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      return false;
    }
    if (type == 'group-offer' || type == 'group-answer') {
      final sdp = payload['sdp'];
      final sdpType = payload['sdpType'];
      return sdp is String && sdp.isNotEmpty &&
          sdpType == (type == 'group-offer' ? 'offer' : 'answer');
    }
    if (type == 'group-ice') {
      final value = payload['candidate'];
      return value is Map && value['candidate'] is String &&
          (value['candidate'] as String).isNotEmpty &&
          (value['sdpMid'] == null || value['sdpMid'] is String) &&
          (value['sdpMLineIndex'] == null ||
              (value['sdpMLineIndex'] is int && value['sdpMLineIndex'] >= 0));
    }
    if (type == 'group-media') {
      final enabled = payload['videoEnabled'];
      final revision = payload['mediaRevision'];
      return enabled is bool && revision is int && revision > 0 &&
          revision <= 0x7fffffff;
    }
    return true;
  }

  /// The alphabetical first participant sends the offer, eliminating glare.
  static bool shouldOffer(String local, String remote) =>
      normalize(local).compareTo(normalize(remote)) < 0;
}
