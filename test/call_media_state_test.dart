import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/calls/call_media_state.dart';
import 'package:stellar_ecc/domain/models/call_session.dart';

void main() {
  group('authenticated in-call media state', () {
    test('newer revision toggles video without changing call identity', () {
      const original = CallSession(
        callId: 'one-call-id',
        chatId: 'direct_alice',
        kind: CallKind.voice,
        state: CallState.connected,
        remoteNickname: 'alice',
      );

      final upgraded = original.copyWith(
        localVideoEnabled: true,
        remoteVideoEnabled: true,
      );
      final downgraded = upgraded.copyWith(
        localVideoEnabled: false,
      );
      expect(upgraded.kind, CallKind.voice);
      expect(downgraded.kind, CallKind.voice);
      expect(downgraded.callId, original.callId);
      expect(downgraded.state, CallState.connected);
      expect(downgraded.remoteVideoEnabled, true);
    });

    test('rejects stale, duplicate, invalid or future-sized revisions', () {
      expect(CallMediaState.parse({'videoEnabled': true, 'mediaRevision': 1}, 0)?.enabled, true);
      expect(CallMediaState.parse({'videoEnabled': false, 'mediaRevision': 2}, 1)?.enabled, false);
      for (final payload in <Map<String, dynamic>>[
        {'videoEnabled': true, 'mediaRevision': 1},
        {'videoEnabled': false, 'mediaRevision': 0},
        {'videoEnabled': 'false', 'mediaRevision': 3},
        {'videoEnabled': true, 'mediaRevision': -1},
        {'videoEnabled': true, 'mediaRevision': 2147483648},
        {'videoEnabled': true, 'mediaRevision': 3.5},
      ]) {
        expect(CallMediaState.parse(payload, 1), isNull);
      }
    });
  });
}
