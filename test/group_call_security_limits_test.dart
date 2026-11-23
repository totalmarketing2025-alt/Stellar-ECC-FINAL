import 'package:flutter_test/flutter_test.dart';
import '../lib/core/calls/group_call_protocol.dart';

void main() {
  final room = List.filled(32, 'a').join();
  final digest = List.filled(64, 'b').join();
  Map<String, dynamic> signal(String type) => {
    'type': type,
    'roomId': room,
    'callId': room,
    'membersDigest': digest,
  };

  test('rejects mismatched call and room identifiers', () {
    final payload = signal('group-join');
    expect(GroupCallProtocol.isValidGroupSignal(payload), isTrue);
    payload['callId'] = 'other';
    expect(GroupCallProtocol.isValidGroupSignal(payload), isFalse);
  });

  test('SDP size and type are enforced', () {
    final payload = signal('group-offer')
      ..['sdpType'] = 'offer'
      ..['sdp'] = List.filled(65536, 'x').join();
    expect(GroupCallProtocol.isValidGroupSignal(payload), isTrue);
    payload['sdp'] = List.filled(65537, 'x').join();
    expect(GroupCallProtocol.isValidGroupSignal(payload), isFalse);
    payload['sdp'] = 'v=0';
    payload['sdpType'] = 'answer';
    expect(GroupCallProtocol.isValidGroupSignal(payload), isFalse);
  });

  test('ICE candidate and media identifier limits are enforced', () {
    final candidate = <String, dynamic>{
      'candidate': List.filled(4096, 'x').join(),
      'sdpMid': List.filled(256, 'x').join(),
      'sdpMLineIndex': 0,
    };
    final payload = signal('group-ice')..['candidate'] = candidate;
    expect(GroupCallProtocol.isValidGroupSignal(payload), isTrue);
    candidate['candidate'] = List.filled(4097, 'x').join();
    expect(GroupCallProtocol.isValidGroupSignal(payload), isFalse);
    candidate['candidate'] = 'candidate:test';
    candidate['sdpMid'] = List.filled(257, 'x').join();
    expect(GroupCallProtocol.isValidGroupSignal(payload), isFalse);
  });

  test('invalid media revisions and unknown signal types are rejected', () {
    final payload = signal('group-media')
      ..['videoEnabled'] = true
      ..['mediaRevision'] = 0;
    expect(GroupCallProtocol.isValidGroupSignal(payload), isFalse);
    payload['mediaRevision'] = 1;
    expect(GroupCallProtocol.isValidGroupSignal(payload), isTrue);
    expect(GroupCallProtocol.isValidGroupSignal(signal('unknown')), isFalse);
  });
}
