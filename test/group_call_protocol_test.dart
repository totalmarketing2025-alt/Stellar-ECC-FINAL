import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/calls/group_call_protocol.dart';
import 'package:stellar_ecc/domain/models/group_call_room.dart';

void main() {
  group('four-participant group mesh policy', () {
    test('deduplicates and sorts names for stable membership digest', () {
      final a = GroupCallProtocol.members([' @Bob ', 'alice', 'BOB', 'carol']);
      final b = GroupCallProtocol.members(['carol', 'bob', '@Alice']);
      expect(a, ['alice', 'bob', 'carol']);
      expect(GroupCallProtocol.membershipDigest(a),
          GroupCallProtocol.membershipDigest(b));
    });

    test('requires local membership and rejects more than four users', () {
      expect(GroupCallProtocol.validMembers(['alice', 'bob'], 'ALICE'), true);
      expect(GroupCallProtocol.validMembers(['alice'], 'alice'), false);
      expect(GroupCallProtocol.validMembers(['alice', 'bob'], 'mallory'), false);
      expect(GroupCallProtocol.validMembers(
          ['alice', 'bob', 'carol', 'dave', 'eve'], 'alice'), false);
    });

    test('deterministic offer direction prevents simultaneous offers', () {
      expect(GroupCallProtocol.shouldOffer('alice', 'bob'), true);
      expect(GroupCallProtocol.shouldOffer('bob', 'alice'), false);
      expect(GroupCallProtocol.shouldOffer('CAROL', 'carol'), false);
    });

    test('rejects unsigned schema tricks before group dispatch', () {
      const roomId = '1234567890abcdef1234567890abcdef';
      const digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final base = <String, dynamic>{
        'type': 'group-invite',
        'roomId': roomId,
        'membersDigest': digest,
        'callId': roomId,
      };
      expect(GroupCallProtocol.isValidGroupSignal(base), true);
      expect(GroupCallProtocol.isValidGroupSignal({...base, 'roomId': 'wrong'}), false);
      expect(GroupCallProtocol.isValidGroupSignal({...base, 'callId': 'different'}), false);
      expect(GroupCallProtocol.isValidGroupSignal({...base, 'membersDigest': 'x'}), false);
      expect(GroupCallProtocol.isValidGroupSignal({...base, 'type': 'group-delete'}), false);
      expect(GroupCallProtocol.isValidGroupSignal({
        ...base, 'type': 'group-media', 'videoEnabled': true, 'mediaRevision': 1,
      }), true);
      expect(GroupCallProtocol.isValidGroupSignal({
        ...base, 'type': 'group-media', 'videoEnabled': 'true', 'mediaRevision': 1,
      }), false);
      expect(GroupCallProtocol.isValidGroupSignal({
        ...base, 'type': 'group-media', 'videoEnabled': true, 'mediaRevision': -1,
      }), false);
      expect(GroupCallProtocol.isValidGroupSignal({
        ...base, 'type': 'group-offer', 'sdp': '', 'sdpType': 'offer',
      }), false);
      expect(GroupCallProtocol.isValidGroupSignal({
        ...base, 'type': 'group-offer', 'sdp': 'v=0', 'sdpType': 'answer',
      }), false);
      expect(GroupCallProtocol.isValidGroupSignal({
        ...base, 'type': 'group-ice', 'candidate': {'candidate': 'candidate:1'},
      }), true);
    });

    test('room state holds participant count and immutable replacements', () {
      const room = GroupCallRoom(
        roomId: 'room',
        chatId: 'group_abc',
        membersDigest: 'digest',
        members: ['alice', 'bob', 'carol'],
        inviter: 'alice',
        video: false,
        phase: GroupCallPhase.connecting,
        joined: {'alice', 'bob'},
        connectionStates: {'bob': GroupMemberCallState.joining},
        remoteVideo: {},
        localVideo: false,
      );
      final connected = room.copyWith(
        phase: GroupCallPhase.connected,
        connectionStates: {'bob': GroupMemberCallState.connected},
        remoteVideo: {'bob': true},
      );
      expect(room.participantCount, 1);
      expect(connected.participantCount, 2);
      expect(connected.remoteVideo['bob'], true);
      expect(connected.members, room.members);
      expect(room.phase, GroupCallPhase.connecting);
    });
  });
}
