import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/core/calls/group_call_coordinator.dart')
      .readAsStringSync();

  test('room teardown detaches peers before asynchronous disposal', () {
    final close = source.substring(source.indexOf('Future<void> _closeRoom('));
    expect(close.indexOf('_peers.clear()'), greaterThanOrEqualTo(0));
    expect(close.indexOf('_peers.clear()'),
        lessThan(close.indexOf('await Future.wait(peers.map(_disposePeer))')));
  });

  test('presence work and connection updates are deduplicated', () {
    expect(source, contains('_presenceInFlightGeneration == generation'));
    expect(source, contains('peer.connectionState == state'));
  });

  test('four-member rooms request reduced capture resolution and FPS', () {
    expect(source, contains('memberCount >= 4 ? 480 : 640'));
    expect(source, contains('memberCount >= 4 ? 360 : 480'));
    expect(source, contains('memberCount >= 4 ? 15 : 24'));
  });

  test('early ICE queue is bounded and deduplicated', () {
    expect(source, contains('!duplicate && queue.length < 128'));
  });

  // Device validation: compare 2- and 4-member audio/video calls,
  // measure CPU, memory, battery, actual FPS and network throughput,
  // and repeat join/leave and camera toggles. These source contracts
  // do not measure runtime performance.
}
