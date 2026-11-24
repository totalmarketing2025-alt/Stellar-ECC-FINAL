import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/calls/call_signal_router.dart';
import 'package:stellar_ecc/domain/models/call_session.dart';

void main() {
  const prefix = 'STELLAR_CALL_V1:';
  const roomId = '1234567890abcdef1234567890abcdef';

  const session = CallSession(
    callId: roomId,
    chatId: 'group_family',
    kind: CallKind.video,
    state: CallState.ringing,
    remoteNickname: 'alice',
  );

  Map<String, dynamic> groupInvite() => <String, dynamic>{
    'type': 'group-invite',
    'roomId': roomId,
    'callId': roomId,
    'membersDigest': List.filled(64, 'a').join(),
    'chatId': 'group_family',
    'kind': 'video',
    'sentAt': DateTime.now().millisecondsSinceEpoch,
    'recipient': 'bob',
    'signature': 'verified-signature',
  };

  Uint8List frame(Map<String, dynamic> payload) => Uint8List.fromList(
    utf8.encode('$prefix${jsonEncode(payload)}'),
  );

  test('routes valid group invitations with signature intact', () async {
    final router = CallSignalRouter();
    addTearDown(router.dispose);
    final received = router.incoming.first;
    router.dispatchPlaintext(session: session, plaintextBytes: frame(groupInvite()));
    final signal = await received;
    expect(signal.type, 'group-invite');
    expect(signal.payload['signature'], 'verified-signature');
    expect(signal.payload['roomId'], roomId);
  });

  test('rejects malformed group envelopes and unsupported prefixes', () async {
    final router = CallSignalRouter();
    addTearDown(router.dispose);
    final malformed = groupInvite()..['membersDigest'] = 'invalid';
    expect(
      () => router.dispatchPlaintext(session: session, plaintextBytes: frame(malformed)),
      throwsStateError,
    );
    expect(
      () => router.dispatchPlaintext(
        session: session,
        plaintextBytes: Uint8List.fromList(utf8.encode('OTHER:${jsonEncode(groupInvite())}')),
      ),
      throwsStateError,
    );
  });
}
