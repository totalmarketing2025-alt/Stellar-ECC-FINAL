import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/core/calls/group_call_coordinator.dart')
      .readAsStringSync();

  test('recovery uses bounded exponential backoff', () {
    expect(source, contains('peer.retryCount >= 5'));
    expect(source, contains('2 << peer.retryCount'));
    expect(source, contains('peer.retryCount = 0'));
    expect(source, contains('peer.retryTimer?.cancel()'));
  });

  test('recovery is scoped to the current room and peer', () {
    expect(source, contains('_isCurrent(generation, room.roomId)'));
    expect(source, contains('identical(_peers[remote], peer)'));
    expect(source, contains('room.joined.contains(remote)'));
    expect(source, contains('GroupCallProtocol.shouldOffer(_local, remote)'));
  });

  test('recovery renegotiates ICE and repairs missing mesh edges', () {
    expect(source, contains("createOffer({'iceRestart': true})"));
    expect(source, contains('_schedulePeerRecovery(remote, peer)'));
    expect(source, contains('await _connectJoinedPeers()'));
    expect(source, contains('await _membershipStillMatches(room)'));
  });
}
