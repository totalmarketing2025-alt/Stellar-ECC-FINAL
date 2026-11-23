import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';

import '../crypto/signal_stores.dart';
import '../network/directory_client.dart';
import '../security/platform_key_store.dart';
import 'guard_protocol.dart';

typedef GuardIdentityResolver = Future<GuardSigningIdentity> Function();

class GuardSigningIdentity {
  const GuardSigningIdentity({
    required this.registrationId,
    required this.sign,
  });

  final int registrationId;
  final Future<String> Function(String message) sign;
}

class GuardPendingSubmissionConflict implements Exception {
  const GuardPendingSubmissionConflict();

  @override
  String toString() =>
      'An earlier Guard submission has an uncertain result. '
      'Retry that same report before making changes.';
}

/// Keeps the private signing key on-device and persists case IDs only in the
/// platform-backed encrypted secret store. Nothing here can approve or delete
/// an account: Guard submissions always remain pending moderator review.
class GuardCaseService {
  GuardCaseService({
    required this.directoryClient,
    required this.keyStore,
    StellarIdentityKeyStore? identityStore,
    GuardIdentityResolver? identityResolver,
  }) : _resolveIdentity = identityResolver ?? (() async {
          if (identityStore == null) {
            throw StateError('Guard identity store is required');
          }
          final identity = await identityStore.getIdentityKeyPair();
          final registrationId = await identityStore.getLocalRegistrationId();
          return GuardSigningIdentity(
            registrationId: registrationId,
            sign: (message) async => base64Encode(Curve.calculateSignature(
              identity.getPrivateKey(),
              Uint8List.fromList(utf8.encode(message)),
            )),
          );
        });

  final DirectoryClient directoryClient;
  final PlatformKeyStore keyStore;
  final GuardIdentityResolver _resolveIdentity;

  static const _maxLocalCases = 50;
  static const _deviceId = 1;

  String _nickname(String raw) {
    final nickname = raw.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(nickname)) {
      throw ArgumentError('Registered Guard account is unavailable');
    }
    return nickname;
  }

  String _caseStorageKey(String nickname) => 'stellar_guard.cases.$nickname';
  String _pendingStorageKey(String nickname) => 'stellar_guard.pending.$nickname';

  Future<GuardSigningIdentity> _identity() async {
    final identity = await _resolveIdentity();
    if (identity.registrationId < 1 || identity.registrationId > 0x7fffffff) {
      throw StateError('Guard account has an invalid Signal registration');
    }
    return identity;
  }

  Future<String> getMyCode(String account) async {
    final nickname = _nickname(account);
    final identity = await _identity();
    final challenge = await directoryClient.getGuardIdentityChallenge(
      nickname: nickname,
      deviceId: _deviceId,
      registrationId: identity.registrationId,
    );
    final message = GuardProtocol.identityMessage(
      nickname: nickname,
      deviceId: _deviceId,
      registrationId: identity.registrationId,
      challenge: challenge,
    );
    final signature = await identity.sign(message);
    return directoryClient.getOwnGuardCode(
      nickname: nickname,
      deviceId: _deviceId,
      registrationId: identity.registrationId,
      challenge: challenge,
      signature: signature,
    );
  }

  /// A device is wiped only after its own Signal identity proves a server
  /// revocation. Network errors and unknown identities must never trigger it.
  Future<bool> isAccountRevoked(String account) async {
    final nickname = _nickname(account);
    final identity = await _identity();
    final challenge = await directoryClient.getGuardAccountChallenge(
      nickname: nickname,
      deviceId: _deviceId,
      registrationId: identity.registrationId,
    );
    final signature = await identity.sign(GuardProtocol.accountMessage(
      nickname: nickname,
      deviceId: _deviceId,
      registrationId: identity.registrationId,
      challenge: challenge,
    ));
    return directoryClient.getGuardAccountRevocation(
      nickname: nickname,
      deviceId: _deviceId,
      registrationId: identity.registrationId,
      challenge: challenge,
      signature: signature,
    );
  }

  Future<GuardPendingSubmission?> loadPending(String account) async {
    final nickname = _nickname(account);
    final bytes = await keyStore.readSecret(_pendingStorageKey(nickname));
    if (bytes == null) return null;
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid stored Guard pending report');
    }
    return GuardPendingSubmission.fromJson(data);
  }

  Future<List<GuardCaseReceipt>> loadLocalCases(String account) async {
    final nickname = _nickname(account);
    final bytes = await keyStore.readSecret(_caseStorageKey(nickname));
    if (bytes == null) return const [];
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! List) {
      throw const FormatException('Invalid stored Guard case list');
    }
    return data.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid stored Guard case');
      }
      return GuardCaseReceipt.fromJson(item);
    }).toList(growable: false);
  }

  Future<void> _saveCase(String nickname, GuardCaseReceipt receipt) async {
    final previous = await loadLocalCases(nickname);
    final existing = previous.where((item) => item.caseId == receipt.caseId);
    final targetCode = receipt.targetCode ??
        (existing.isEmpty ? null : existing.first.targetCode);
    final record = receipt.withTargetCode(targetCode);
    final updated = <GuardCaseReceipt>[
      record,
      ...previous.where((item) => item.caseId != record.caseId),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    await keyStore.writeSecret(
      _caseStorageKey(nickname),
      Uint8List.fromList(utf8.encode(jsonEncode(
        updated.take(_maxLocalCases).map((item) => item.toJson()).toList(),
      ))),
    );
  }

  Future<GuardCaseReceipt> submit({
    required String account,
    required String targetCode,
    required String reason,
    required String details,
  }) async {
    final nickname = _nickname(account);
    final normalizedDetails = details.trim();
    if (!GuardProtocol.validCode(targetCode) ||
        !GuardProtocol.reasons.containsKey(reason) ||
        !GuardProtocol.validDetails(normalizedDetails)) {
      throw ArgumentError('Enter a valid nine-digit code, reason and details');
    }

    var pending = await loadPending(nickname);
    if (pending != null &&
        !pending.matches(targetCode, reason, normalizedDetails)) {
      throw const GuardPendingSubmissionConflict();
    }

    pending ??= GuardPendingSubmission(
      targetCode: targetCode,
      reason: reason,
      details: normalizedDetails,
      idempotencyKey: const Uuid().v4(),
    );
    // Persist the exact payload and UUID *before* networking. A timeout after
    // server acceptance is retried using the same idempotency key.
    await keyStore.writeSecret(
      _pendingStorageKey(nickname),
      Uint8List.fromList(utf8.encode(jsonEncode(pending.toJson()))),
    );

    late final Map<String, dynamic> response;
    try {
      response = await _signedCaseAction(
        nickname: nickname,
        action: 'submit',
        targetCode: pending.targetCode,
        reason: pending.reason,
        details: pending.details,
        idempotencyKey: pending.idempotencyKey,
      );
    } on DirectoryException catch (error) {
      // A 400 is a definitive rejection (for example: reporting one's own
      // code). Unlock editing after that response. Network uncertainty and
      // all other statuses MUST preserve the original retry key.
      if (error.statusCode == 400) {
        await keyStore.deleteSecret(_pendingStorageKey(nickname));
      }
      rethrow;
    }
    final receipt = GuardCaseReceipt.fromJson(response)
        .withTargetCode(targetCode);
    await _saveCase(nickname, receipt);
    await keyStore.deleteSecret(_pendingStorageKey(nickname));
    return receipt;
  }

  Future<GuardCaseReceipt> refresh({
    required String account,
    required String caseId,
  }) => _caseState(account, caseId, 'status');

  Future<GuardCaseReceipt> cancel({
    required String account,
    required String caseId,
  }) => _caseState(account, caseId, 'cancel');

  Future<GuardCaseReceipt> _caseState(
    String account, String caseId, String action,
  ) async {
    final nickname = _nickname(account);
    if (!GuardProtocol.validCaseId(caseId)) {
      throw ArgumentError('Invalid Guard case ID');
    }
    final normalizedCaseId = caseId.toLowerCase();
    final response = await _signedCaseAction(
      nickname: nickname,
      action: action,
      caseId: normalizedCaseId,
    );
    final receipt = GuardCaseReceipt.fromJson(response);
    if (receipt.caseId.toLowerCase() != normalizedCaseId) {
      throw const FormatException('Guard case identity mismatch');
    }
    await _saveCase(nickname, receipt);
    return receipt;
  }

  Future<Map<String, dynamic>> _signedCaseAction({
    required String nickname,
    required String action,
    String caseId = '',
    String targetCode = '',
    String reason = '',
    String details = '',
    String idempotencyKey = '',
  }) async {
    final identity = await _identity();
    final challenge = await directoryClient.getGuardCaseChallenge(
      nickname: nickname,
      deviceId: _deviceId,
      registrationId: identity.registrationId,
      purpose: action,
    );
    final message = GuardProtocol.caseMessage(
      action: action,
      nickname: nickname,
      deviceId: _deviceId,
      registrationId: identity.registrationId,
      challenge: challenge,
      caseId: caseId,
      targetCode: targetCode,
      reason: reason,
      details: details,
      idempotencyKey: idempotencyKey,
    );
    final proof = <String, dynamic>{
      'nickname': nickname,
      'deviceId': _deviceId,
      'registrationId': identity.registrationId,
      'challenge': challenge,
      'signature': await identity.sign(message),
      if (action == 'submit') ...{
        'targetCode': targetCode,
        'reason': reason,
        'details': details,
        'idempotencyKey': idempotencyKey,
      },
    };

    switch (action) {
      case 'submit':
        return directoryClient.submitGuardCase(proof);
      case 'status':
        return directoryClient.getGuardCaseStatus(caseId: caseId, proof: proof);
      case 'cancel':
        return directoryClient.cancelGuardCase(caseId: caseId, proof: proof);
      default:
        throw StateError('Unsupported Guard case action');
    }
  }
}
