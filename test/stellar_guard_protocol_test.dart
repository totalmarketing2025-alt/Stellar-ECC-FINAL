import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/guard/guard_protocol.dart';

void main() {
  test('Guard code is exactly nine ASCII digits, including leading zeros', () {
    expect(GuardProtocol.validCode('000000017'), isTrue);
    expect(GuardProtocol.validCode('12345678'), isFalse);
    expect(GuardProtocol.validCode('1234567890'), isFalse);
    expect(GuardProtocol.validCode('12345678x'), isFalse);
    expect(GuardProtocol.validCode('１２３４５６７８９'), isFalse);
  });

  test('theft is a valid signed Guard reason and a restorable draft', () {
    expect(GuardProtocol.reasons['theft'], 'Theft / Кражба');
    const caseUuid = 'c8c642a8-8324-41f5-a5cb-cef69f2f7100';
    final draft = GuardPendingSubmission.fromJson({
      'targetCode': '000000017',
      'reason': 'theft',
      'details': 'Reported theft requiring independent verification.',
      'idempotencyKey': caseUuid,
    });
    expect(draft.reason, 'theft');
    final message = GuardProtocol.caseMessage(
      action: 'submit', nickname: 'alice', deviceId: 1,
      registrationId: 101, challenge: 'nonce',
      targetCode: draft.targetCode, reason: draft.reason,
      details: draft.details, idempotencyKey: draft.idempotencyKey,
    );
    expect((jsonDecode(message) as List<dynamic>)[8], 'theft');
  });

  test('own-code proof matches server domain-separated identity JSON', () {
    expect(
      GuardProtocol.identityMessage(
        nickname: 'Alice', deviceId: 1, registrationId: 101,
        challenge: 'nonce',
      ),
      '["stellar-guard-identity-v1","alice",1,101,"nonce"]',
    );
  });

  test('submit signature binds action, nine-digit code, reason and UUID', () {
    const caseUuid = 'c8c642a8-8324-41f5-a5cb-cef69f2f7100';
    final message = GuardProtocol.caseMessage(
      action: 'submit', nickname: 'ALICE', deviceId: 1,
      registrationId: 101, challenge: 'xyz',
      targetCode: '000000017', reason: 'harassment',
      details: 'Repeated unwanted contact.', idempotencyKey: caseUuid,
    );
    expect(message, '["stellar-guard-case-v1","submit","alice",1,101,'
        '"xyz","","000000017","harassment",'
        '"Repeated unwanted contact.","$caseUuid"]');
    expect(jsonDecode(message), isA<List<dynamic>>());
  });

  test('status and cancel signatures cannot be repurposed for submission', () {
    const caseUuid = 'c8c642a8-8324-41f5-a5cb-cef69f2f7100';
    final status = GuardProtocol.caseMessage(
      action: 'status', nickname: 'alice', deviceId: 1,
      registrationId: 101, challenge: 'xyz', caseId: caseUuid,
      targetCode: '000000017', reason: 'scam',
    );
    final cancel = GuardProtocol.caseMessage(
      action: 'cancel', nickname: 'alice', deviceId: 1,
      registrationId: 101, challenge: 'xyz', caseId: caseUuid,
    );
    expect(status, isNot(cancel));
    expect(jsonDecode(status), [
      'stellar-guard-case-v1', 'status', 'alice', 1, 101, 'xyz',
      caseUuid, '', '', '', '',
    ]);
    expect(jsonDecode(cancel)[1], 'cancel');
    expect(() => GuardProtocol.caseMessage(
      action: 'approve', nickname: 'alice', deviceId: 1,
      registrationId: 101, challenge: 'xyz',
    ), throwsArgumentError);
  });

  test('case receipts and pending drafts reject malformed responses', () {
    const caseUuid = 'c8c642a8-8324-41f5-a5cb-cef69f2f7100';
    final receipt = GuardCaseReceipt.fromJson({
      'caseId': caseUuid,
      'status': 'pending_review',
      'createdAt': 100,
      'updatedAt': 101,
    });
    expect(receipt.withTargetCode('000000017').toJson()['targetCode'],
        '000000017');
    expect(() => GuardCaseReceipt.fromJson({
      'caseId': 'not-a-uuid', 'status': 'pending_review',
      'createdAt': 100, 'updatedAt': 101,
    }), throwsFormatException);
    expect(() => GuardCaseReceipt.fromJson({
      'caseId': caseUuid, 'status': 'pending_review',
      'createdAt': 101, 'updatedAt': 100,
    }), throwsFormatException);

    final pending = GuardPendingSubmission.fromJson({
      'targetCode': '000000017',
      'reason': 'harassment',
      'details': 'Repeated unwanted contact.',
      'idempotencyKey': caseUuid,
    });
    expect(pending.matches('000000017', 'harassment',
        'Repeated unwanted contact.'), isTrue);
    expect(pending.matches('000000017', 'scam',
        'Repeated unwanted contact.'), isFalse);
  });
}
