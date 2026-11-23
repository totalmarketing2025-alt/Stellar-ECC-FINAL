import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/core/calls/group_call_coordinator.dart').readAsStringSync();
  test('ICE validation does not duplicate coordinator implementation', () {
    expect(RegExp(r'Future<void> _send\(').allMatches(source).length, 1);
    expect(source, contains('Invalid ICE server URL'));
  });
  test('incoming signals and replay cache are bounded', () {
    expect(source, contains('_maxQueuedSignals = 256'));
    expect(source, contains('_maxSeenGroupSignals = 8192'));
    expect(source, contains('_queuedSignals--'));
  });
  test('deferred native actions are bounded and expire', () {
    expect(source, contains('_deferredNativeActions.length < 4'));
    expect(source, contains('deferred.value.isAfter(DateTime.now())'));
  });
  test('answers are correlated with negotiation', () {
    expect(source, contains("payload['negotiationId'] != peer.negotiation"));
  });
}
