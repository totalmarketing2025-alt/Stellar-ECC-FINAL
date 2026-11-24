import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:stellar_ecc/core/calls/call_signal_authenticator.dart';

void main() {
  group('authenticated call signal routing', () {
    test('validates and preserves the signature for group replay checks', () {
      final identity = generateIdentityKeyPair();
      final sentAt = DateTime.now().millisecondsSinceEpoch;
      final payload = <String, dynamic>{
        'type': 'group-invite',
        'roomId': '1234567890abcdef1234567890abcdef',
        'callId': '1234567890abcdef1234567890abcdef',
        'membersDigest': List.filled(64, 'a').join(),
        'chatId': 'group_family',
        'kind': 'video',
        'sentAt': sentAt,
        'recipient': 'bob',
      };
      final signature = CallSignalAuthenticator.sign(
        identityKeyPair: identity,
        recipient: 'bob',
        payload: payload,
      );
      final routed = CallSignalAuthenticator.verifyAndPreserveSignature(
        identityKey: identity.getPublicKey(),
        recipient: 'bob',
        payload: payload,
        signature: signature,
        now: DateTime.fromMillisecondsSinceEpoch(sentAt),
      );

      expect(routed, isNotNull);
      expect(routed!['signature'], base64Encode(signature));
      expect(routed['roomId'], payload['roomId']);
      expect(routed['chatId'], payload['chatId']);
    });

    test('rejects tampered, expired, wrong-recipient and wrong-key signals', () {
      final identity = generateIdentityKeyPair();
      final otherIdentity = generateIdentityKeyPair();
      final sentAt = DateTime.now().millisecondsSinceEpoch;
      final payload = <String, dynamic>{
        'type': 'group-invite',
        'roomId': '1234567890abcdef1234567890abcdef',
        'callId': '1234567890abcdef1234567890abcdef',
        'membersDigest': List.filled(64, 'a').join(),
        'chatId': 'group_family',
        'kind': 'voice',
        'sentAt': sentAt,
        'recipient': 'bob',
      };
      final signature = CallSignalAuthenticator.sign(
        identityKeyPair: identity,
        recipient: 'bob',
        payload: payload,
      );
      Map<String, dynamic>? route(
        Map<String, dynamic> body, {
        IdentityKey? key,
        String recipient = 'bob',
        DateTime? now,
      }) => CallSignalAuthenticator.verifyAndPreserveSignature(
        identityKey: key ?? identity.getPublicKey(),
        recipient: recipient,
        payload: body,
        signature: signature,
        now: now ?? DateTime.fromMillisecondsSinceEpoch(sentAt),
      );

      expect(route({...payload, 'chatId': 'group_other'}), isNull);
      expect(route(payload, recipient: 'mallory'), isNull);
      expect(route(payload, key: otherIdentity.getPublicKey()), isNull);
      expect(
        route(payload, now: DateTime.fromMillisecondsSinceEpoch(
          sentAt + CallSignalAuthenticator.maxAge.inMilliseconds + 1000,
        )),
        isNull,
      );
      expect(
        CallSignalAuthenticator.verifyAndPreserveSignature(
          identityKey: identity.getPublicKey(),
          recipient: 'bob',
          payload: payload,
          signature: Uint8List(63),
        ),
        isNull,
      );
    });
  });
}
