import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/guard/guard_case_service.dart';
import 'package:stellar_ecc/core/guard/guard_protocol.dart';
import 'package:stellar_ecc/core/network/directory_client.dart';
import 'package:stellar_ecc/core/security/platform_key_store.dart';

const caseId = 'c8c642a8-8324-41f5-a5cb-cef69f2f7100';

class MemoryGuardKeyStore extends PlatformKeyStore {
  final Map<String, Uint8List> values = {};

  @override
  Future<Uint8List?> readSecret(String key) async => values[key];

  @override
  Future<void> writeSecret(String key, Uint8List value) async {
    values[key] = Uint8List.fromList(value);
  }

  @override
  Future<void> deleteSecret(String key) async {
    values.remove(key);
  }
}

class FakeGuardDirectory extends DirectoryClient {
  FakeGuardDirectory() : super(baseUrl: 'https://directory.test');

  int submitCount = 0;
  bool failFirstSubmit = false;
  bool rejectSubmit = false;
  final idempotencyKeys = <String>[];
  final signedMessages = <String>[];
  String status = 'pending_review';
  final createdAt = DateTime.now().millisecondsSinceEpoch;

  @override
  Future<String> getGuardIdentityChallenge({
    required String nickname,
    required int deviceId,
    required int registrationId,
  }) async => 'identitychallenge0123456789';

  @override
  Future<String> getOwnGuardCode({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
    required String signature,
  }) async {
    signedMessages.add(utf8.decode(base64Decode(signature)));
    return '000000017';
  }

  @override
  Future<String> getGuardCaseChallenge({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String purpose,
  }) async => 'casechallenge0123456789';

  @override
  Future<Map<String, dynamic>> submitGuardCase(Map<String, dynamic> proof) async {
    submitCount++;
    idempotencyKeys.add(proof['idempotencyKey'] as String);
    signedMessages.add(utf8.decode(base64Decode(proof['signature'] as String)));
    if (failFirstSubmit && submitCount == 1) {
      throw const DirectoryException('Network disconnected', 503);
    }
    if (rejectSubmit) {
      throw const DirectoryException('Cannot report your own account', 400);
    }
    return _receipt();
  }

  @override
  Future<Map<String, dynamic>> getGuardCaseStatus({
    required String caseId,
    required Map<String, dynamic> proof,
  }) async {
    signedMessages.add(utf8.decode(base64Decode(proof['signature'] as String)));
    return _receipt();
  }

  @override
  Future<Map<String, dynamic>> cancelGuardCase({
    required String caseId,
    required Map<String, dynamic> proof,
  }) async {
    signedMessages.add(utf8.decode(base64Decode(proof['signature'] as String)));
    status = 'cancelled';
    return _receipt();
  }

  Map<String, dynamic> _receipt() => {
    'caseId': caseId,
    'status': status,
    'createdAt': createdAt,
    'updatedAt': DateTime.now().millisecondsSinceEpoch,
  };
}

GuardCaseService service(FakeGuardDirectory directory, MemoryGuardKeyStore keyStore) =>
    GuardCaseService(
      directoryClient: directory,
      keyStore: keyStore,
      identityResolver: () async => GuardSigningIdentity(
        registrationId: 101,
        sign: (message) async => base64Encode(utf8.encode(message)),
      ),
    );

void main() {
  test('own code uses the exact registered Signal identity message', () async {
    final directory = FakeGuardDirectory();
    addTearDown(directory.dispose);
    final guard = service(directory, MemoryGuardKeyStore());

    expect(await guard.getMyCode('ALICE'), '000000017');
    expect(directory.signedMessages.single,
        GuardProtocol.identityMessage(
          nickname: 'alice', deviceId: 1, registrationId: 101,
          challenge: 'identitychallenge0123456789',
        ));
  });

  test('network retry preserves the same idempotency key and exact payload', () async {
    final directory = FakeGuardDirectory()..failFirstSubmit = true;
    addTearDown(directory.dispose);
    final keyStore = MemoryGuardKeyStore();
    final guard = service(directory, keyStore);

    Future<GuardCaseReceipt> submit(String details) => guard.submit(
      account: 'alice', targetCode: '000000017',
      reason: 'harassment', details: details,
    );

    await expectLater(submit('Repeated unwanted contact.'),
        throwsA(isA<DirectoryException>()));
    final pending = await guard.loadPending('alice');
    expect(pending, isNotNull);
    expect(GuardProtocol.validCaseId(pending!.idempotencyKey), isTrue);

    await expectLater(submit('Edited and different details.'),
        throwsA(isA<GuardPendingSubmissionConflict>()));
    expect(directory.submitCount, 1);

    final receipt = await submit('Repeated unwanted contact.');
    expect(receipt.caseId, caseId);
    expect(receipt.targetCode, '000000017');
    expect(await guard.loadPending('alice'), isNull);
    expect(directory.submitCount, 2);
    expect(directory.idempotencyKeys[0], directory.idempotencyKeys[1]);
    expect(directory.signedMessages.last,
        GuardProtocol.caseMessage(
          action: 'submit', nickname: 'alice', deviceId: 1,
          registrationId: 101, challenge: 'casechallenge0123456789',
          targetCode: '000000017', reason: 'harassment',
          details: 'Repeated unwanted contact.',
          idempotencyKey: pending.idempotencyKey,
        ));

    // Recreating the service simulates a restart; reports survive encrypted.
    final restored = service(directory, keyStore);
    expect((await restored.loadLocalCases('alice')).single.caseId, caseId);
    expect(await restored.loadLocalCases('bob'), isEmpty);
  });

  test('refresh and cancel sign separate operations and keep local history', () async {
    final directory = FakeGuardDirectory();
    addTearDown(directory.dispose);
    final guard = service(directory, MemoryGuardKeyStore());
    await guard.submit(account: 'alice', targetCode: '000000017',
        reason: 'scam', details: 'A detailed report of suspicious behavior.');

    final checked = await guard.refresh(account: 'alice', caseId: caseId);
    expect(checked.status, 'pending_review');
    expect(directory.signedMessages.last, GuardProtocol.caseMessage(
      action: 'status', nickname: 'alice', deviceId: 1,
      registrationId: 101, challenge: 'casechallenge0123456789', caseId: caseId,
    ));

    final cancelled = await guard.cancel(account: 'alice', caseId: caseId);
    expect(cancelled.status, 'cancelled');
    expect(directory.signedMessages.last, GuardProtocol.caseMessage(
      action: 'cancel', nickname: 'alice', deviceId: 1,
      registrationId: 101, challenge: 'casechallenge0123456789', caseId: caseId,
    ));
    expect((await guard.loadLocalCases('alice')).single.status, 'cancelled');
  });

  test('definitive validation rejection unlocks the saved draft for editing', () async {
    final directory = FakeGuardDirectory()..rejectSubmit = true;
    addTearDown(directory.dispose);
    final guard = service(directory, MemoryGuardKeyStore());

    await expectLater(guard.submit(
      account: 'alice', targetCode: '000000017', reason: 'other',
      details: 'I am attempting to report my own account.',
    ), throwsA(isA<DirectoryException>()));
    expect(await guard.loadPending('alice'), isNull);

    directory.rejectSubmit = false;
    final result = await guard.submit(
      account: 'alice', targetCode: '000000018', reason: 'other',
      details: 'I have corrected the target account code.',
    );
    expect(result.targetCode, '000000018');
    expect(directory.idempotencyKeys[0], isNot(directory.idempotencyKeys[1]));
  });
}
