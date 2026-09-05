class DirectoryUserBundle {
  const DirectoryUserBundle({
    required this.nickname,
    required this.registrationId,
    required this.deviceId,
    required this.identityKey,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.preKeyId,
    this.preKey,
  });

  final String nickname;

  final int registrationId;

  final int deviceId;

  /// Serialized Signal identity public key, encoded as base64.
  final String identityKey;

  final int signedPreKeyId;

  /// Serialized signed-prekey public key, encoded as base64.
  final String signedPreKey;

  /// Signature over the signed prekey, encoded as base64.
  final String signedPreKeySignature;

  /// Optional one-time prekey.
  final int? preKeyId;

  /// Serialized one-time prekey public key, encoded as base64.
  final String? preKey;

  factory DirectoryUserBundle.fromJson(Map<String, dynamic> json) {
    final bundle = json['bundle'];

    if (bundle is! Map<String, dynamic>) {
      throw const FormatException(
        'Directory response is missing bundle',
      );
    }

    final identityKey = bundle['identityKey'];
    final signedPreKey = bundle['signedPreKey'];
    final preKey = bundle['preKey'];

    if (identityKey is! String ||
        signedPreKey is! Map<String, dynamic>) {
      throw const FormatException(
        'Invalid Signal bundle',
      );
    }

    final signedPreKeyId = signedPreKey['keyId'];
    final signedPreKeyPublicKey = signedPreKey['publicKey'];
    final signedPreKeySignature = signedPreKey['signature'];

    if (signedPreKeyId is! int ||
        signedPreKeyPublicKey is! String ||
        signedPreKeySignature is! String) {
      throw const FormatException(
        'Invalid signed prekey',
      );
    }

    int? preKeyId;
    String? preKeyPublicKey;

    if (preKey != null) {
      if (preKey is! Map<String, dynamic>) {
        throw const FormatException(
          'Invalid prekey',
        );
      }

      if (preKey['keyId'] is! int ||
          preKey['publicKey'] is! String) {
        throw const FormatException(
          'Invalid one-time prekey',
        );
      }

      preKeyId = preKey['keyId'] as int;
      preKeyPublicKey = preKey['publicKey'] as String;
    }

    final registrationId = bundle['registrationId'];
    final deviceId = bundle['deviceId'];

    if (registrationId is! int ||
        deviceId is! int) {
      throw const FormatException(
        'Invalid registration/device id',
      );
    }

    final nickname = json['nickname'];

    if (nickname is! String ||
        nickname.isEmpty) {
      throw const FormatException(
        'Invalid directory nickname',
      );
    }

    return DirectoryUserBundle(
      nickname: nickname,
      registrationId: registrationId,
      deviceId: deviceId,
      identityKey: identityKey,
      signedPreKeyId: signedPreKeyId,
      signedPreKey: signedPreKeyPublicKey,
      signedPreKeySignature: signedPreKeySignature,
      preKeyId: preKeyId,
      preKey: preKeyPublicKey,
    );
  }
}
