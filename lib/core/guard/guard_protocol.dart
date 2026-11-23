import 'dart:convert';

/// Canonical wire format agreed with the Directory Worker. Never replace
/// JSON arrays with maps: the Signal signature binds their exact order.
class GuardProtocol {
  GuardProtocol._();

  static const reasons = <String, String>{
    'harassment': 'Harassment',
    'threats': 'Threats',
    'scam': 'Scam / fraud',
    'theft': 'Theft / Кражба',
    'impersonation': 'Impersonation',
    'other': 'Other',
  };

  static final RegExp _code = RegExp(r'^[0-9]{9}$');
  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static bool validCode(String value) => _code.hasMatch(value);
  static bool validCaseId(String value) => _uuid.hasMatch(value);
  static bool validDetails(String value) =>
      value == value.trim() && value.length >= 10 && value.length <= 2000;

  static String identityMessage({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
  }) => jsonEncode([
    'stellar-guard-identity-v1',
    nickname.trim().toLowerCase(),
    deviceId,
    registrationId,
    challenge,
  ]);

  static String accountMessage({
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
  }) => jsonEncode([
    'stellar-guard-account-v1',
    nickname.trim().toLowerCase(),
    deviceId,
    registrationId,
    challenge,
  ]);

  static String caseMessage({
    required String action,
    required String nickname,
    required int deviceId,
    required int registrationId,
    required String challenge,
    String caseId = '',
    String targetCode = '',
    String reason = '',
    String details = '',
    String idempotencyKey = '',
  }) {
    if (!const {'submit', 'status', 'cancel'}.contains(action)) {
      throw ArgumentError.value(action, 'action', 'Unsupported Guard action');
    }
    return jsonEncode([
      'stellar-guard-case-v1',
      action,
      nickname.trim().toLowerCase(),
      deviceId,
      registrationId,
      challenge,
      caseId,
      action == 'submit' ? targetCode : '',
      action == 'submit' ? reason : '',
      action == 'submit' ? details : '',
      action == 'submit' ? idempotencyKey : '',
    ]);
  }
}

class GuardCaseReceipt {
  const GuardCaseReceipt({
    required this.caseId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.targetCode,
  });

  final String caseId;
  final String status;
  final int createdAt;
  final int updatedAt;
  // Never sent by the server; only stored locally for the owner's display.
  final String? targetCode;

  factory GuardCaseReceipt.fromJson(Map<String, dynamic> json) {
    final caseId = json['caseId'];
    final status = json['status'];
    final createdAt = json['createdAt'];
    final updatedAt = json['updatedAt'];
    final targetCode = json['targetCode'];
    if (caseId is! String || !GuardProtocol.validCaseId(caseId) ||
        status is! String || status.isEmpty || status.length > 40 ||
        createdAt is! int || updatedAt is! int ||
        createdAt <= 0 || updatedAt < createdAt ||
        (targetCode != null &&
            (targetCode is! String || !GuardProtocol.validCode(targetCode)))) {
      throw const FormatException('Invalid Guard case receipt');
    }
    return GuardCaseReceipt(
      caseId: caseId,
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt,
      targetCode: targetCode as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'caseId': caseId,
    'status': status,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (targetCode != null) 'targetCode': targetCode,
  };

  GuardCaseReceipt withTargetCode(String? code) => GuardCaseReceipt(
    caseId: caseId,
    status: status,
    createdAt: createdAt,
    updatedAt: updatedAt,
    targetCode: code ?? targetCode,
  );
}

class GuardPendingSubmission {
  const GuardPendingSubmission({
    required this.targetCode,
    required this.reason,
    required this.details,
    required this.idempotencyKey,
  });

  final String targetCode;
  final String reason;
  final String details;
  final String idempotencyKey;

  factory GuardPendingSubmission.fromJson(Map<String, dynamic> json) {
    final targetCode = json['targetCode'];
    final reason = json['reason'];
    final details = json['details'];
    final idempotencyKey = json['idempotencyKey'];
    if (targetCode is! String || !GuardProtocol.validCode(targetCode) ||
        reason is! String || !GuardProtocol.reasons.containsKey(reason) ||
        details is! String || !GuardProtocol.validDetails(details) ||
        idempotencyKey is! String || !GuardProtocol.validCaseId(idempotencyKey)) {
      throw const FormatException('Invalid pending Guard submission');
    }
    return GuardPendingSubmission(
      targetCode: targetCode,
      reason: reason,
      details: details,
      idempotencyKey: idempotencyKey,
    );
  }

  Map<String, dynamic> toJson() => {
    'targetCode': targetCode,
    'reason': reason,
    'details': details,
    'idempotencyKey': idempotencyKey,
  };

  bool matches(String code, String reportReason, String reportDetails) =>
      targetCode == code && reason == reportReason && details == reportDetails;
}
