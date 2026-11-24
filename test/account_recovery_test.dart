import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/security/account_recovery.dart';

void main() {
  test('account recovery file encrypts identity data and restores its Story key', () async {
    const passphrase = 'bright river quartz meadow silver lantern';
    final identityBytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final backup = await AccountRecoveryService.createBackup(
      nickname: 'Alice_01',
      identityKeyPair: identityBytes,
      registrationId: 12345,
      passphrase: passphrase,
    );
    final document = jsonDecode(utf8.decode(backup.fileBytes)) as Map<String, dynamic>;
    expect(utf8.decode(backup.fileBytes), isNot(contains('Alice_01')));
    expect(utf8.decode(backup.fileBytes), isNot(contains(passphrase)));

    final restored = await AccountRecoveryService.openBackup(
      backup: backup.fileBytes,
      passphrase: passphrase,
    );
    expect(restored.nickname, 'alice_01');
    expect(restored.identityKeyPair, identityBytes);
    expect(restored.registrationId, 12345);
    expect(restored.recoveryKey, backup.recoveryKey);
    expect(document['format'], accountRecoveryFormat);

    final storyKey = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
    final envelope = await AccountRecoveryService.wrapStoryKey(
      owner: restored.nickname,
      storyId: 'story-id',
      storyKey: storyKey,
      recoveryKey: restored.recoveryKey,
    );
    expect(
      await AccountRecoveryService.unwrapStoryKey(
        owner: restored.nickname,
        storyId: 'story-id',
        envelope: envelope,
        recoveryKey: restored.recoveryKey,
      ),
      storyKey,
    );
    await expectLater(
      AccountRecoveryService.unwrapStoryKey(
        owner: restored.nickname,
        storyId: 'different-story',
        envelope: envelope,
        recoveryKey: restored.recoveryKey,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('recovery file rejects a wrong passphrase', () async {
    final backup = await AccountRecoveryService.createBackup(
      nickname: 'alice',
      identityKeyPair: Uint8List.fromList(List<int>.filled(64, 7)),
      registrationId: 2,
      passphrase: 'correct and lengthy recovery phrase',
    );

    await expectLater(
      AccountRecoveryService.openBackup(
        backup: backup.fileBytes,
        passphrase: 'incorrect but still lengthy phrase',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
