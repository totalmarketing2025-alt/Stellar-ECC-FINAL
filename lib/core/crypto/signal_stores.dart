import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../storage/database.dart';
import '../security/platform_key_store.dart';

/// Persists the local identity key pair and the registration id, and
/// evaluates trust for remote identity keys ("safety number" changes).
/// Backed by [PlatformKeyStore] (Keystore/Secure Enclave) for the private
/// key material, and the encrypted local database for the trusted-identity
/// table (public keys only — safe to keep alongside session state).
class StellarIdentityKeyStore implements IdentityKeyStore {
  StellarIdentityKeyStore(this._db, this._keyStore);

  final StellarDatabase _db;
  final PlatformKeyStore _keyStore;

  static const _identityKeyAlias = 'stellar_ecc.identity_keypair';
  static const _registrationIdAlias = 'stellar_ecc.registration_id';

  IdentityKeyPair? _cachedIdentity;

  Future<void> initializeIfAbsent() async {
    final existing = await _keyStore.readSecret(_identityKeyAlias);
    if (existing != null) return;

    final generated = generateIdentityKeyPair();
    await _keyStore.writeSecret(_identityKeyAlias, generated.serialize());

    final regId = generateRegistrationId(false);
    await _keyStore.writeSecret(
      _registrationIdAlias,
      Uint8List.fromList(_intTo4Bytes(regId)),
    );
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    if (_cachedIdentity != null) return _cachedIdentity!;
    final raw = await _keyStore.readSecret(_identityKeyAlias);
    if (raw == null) {
      throw StateError('Identity key pair not initialized — call initializeIfAbsent() first');
    }
    _cachedIdentity = IdentityKeyPair.fromSerialized(raw);
    return _cachedIdentity!;
  }

  @override
  Future<int> getLocalRegistrationId() async {
    final raw = await _keyStore.readSecret(_registrationIdAlias);
    if (raw == null) {
      throw StateError('Registration id not initialized — call initializeIfAbsent() first');
    }
    return _bytesToInt(raw);
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;
    final existing = await _db.trustedIdentityDao.get(address.getName(), address.getDeviceId());
    final changed = existing != null && existing != identityKey.serialize();
    await _db.trustedIdentityDao.upsert(
      address.getName(),
      address.getDeviceId(),
      identityKey.serialize(),
    );
    // `changed == true` is exactly the "safety number changed" event the UI
    // (Phase 5 profile screen) surfaces as a non-blocking warning banner.
    return changed;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    final existing = await _db.trustedIdentityDao.get(address.getName(), address.getDeviceId());
    // Trust-on-first-use: no prior record means we accept and pin it now.
    // Any *change* thereafter is flagged (via saveIdentity's return value)
    // but not auto-blocked — matches Signal's default UX, verification is
    // opt-in via the safety-number compare flow.
    if (existing == null) return true;
    return _bytesEqual(existing, identityKey.serialize());
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final raw = await _db.trustedIdentityDao.get(address.getName(), address.getDeviceId());
    return raw == null ? null : IdentityKey.fromBytes(raw, 0);
  }

  List<int> _intTo4Bytes(int value) => [
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  int _bytesToInt(Uint8List bytes) =>
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// One-time prekeys — consumed (deleted) on use, matching the server-side
/// atomic-delete behavior in the relay's directory service.
class StellarPreKeyStore implements PreKeyStore {
  StellarPreKeyStore(this._db);
  final StellarDatabase _db;

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final raw = await _db.preKeyDao.get(preKeyId);
    if (raw == null) throw InvalidKeyIdException('No such prekey: $preKeyId');
    return PreKeyRecord.fromBuffer(raw);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) =>
      _db.preKeyDao.put(preKeyId, record.serialize());

  @override
  Future<bool> containsPreKey(int preKeyId) => _db.preKeyDao.contains(preKeyId);

  @override
  Future<void> removePreKey(int preKeyId) => _db.preKeyDao.remove(preKeyId);
}

class StellarSignedPreKeyStore implements SignedPreKeyStore {
  StellarSignedPreKeyStore(this._db);
  final StellarDatabase _db;

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final raw = await _db.signedPreKeyDao.get(signedPreKeyId);
    if (raw == null) {
      throw InvalidKeyIdException('No such signed prekey: $signedPreKeyId');
    }
    return SignedPreKeyRecord.fromSerialized(raw);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final all = await _db.signedPreKeyDao.getAll();
    return all.map((raw) => SignedPreKeyRecord.fromSerialized(raw)).toList();
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) =>
      _db.signedPreKeyDao.put(signedPreKeyId, record.serialize());

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) =>
      _db.signedPreKeyDao.contains(signedPreKeyId);

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) =>
      _db.signedPreKeyDao.remove(signedPreKeyId);
}

/// Double Ratchet session state, per (contact, device) — encrypted at rest
/// via the DB's SQLCipher key (Phase 2 storage design).
class StellarSessionStore implements SessionStore {
  StellarSessionStore(this._db);
  final StellarDatabase _db;

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final raw = await _db.sessionDao.get(address.getName(), address.getDeviceId());
    return raw == null ? SessionRecord() : SessionRecord.fromSerialized(raw);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) =>
      _db.sessionDao.deviceIdsFor(name);

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) =>
      _db.sessionDao.put(address.getName(), address.getDeviceId(), record.serialize());

  @override
  Future<bool> containsSession(SignalProtocolAddress address) =>
      _db.sessionDao.contains(address.getName(), address.getDeviceId());

  @override
  Future<void> deleteSession(SignalProtocolAddress address) =>
      _db.sessionDao.remove(address.getName(), address.getDeviceId());

  @override
  Future<void> deleteAllSessions(String name) => _db.sessionDao.removeAllFor(name);
}

/// Persistent Sender Keys group state (Phase 3 §4), backed by the same
/// encrypted DB as the pairwise session store — replaces libsignal's
/// InMemorySenderKeyStore so group chats survive an app restart.
class StellarSenderKeyStore implements SenderKeyStore {
  StellarSenderKeyStore(this._db);
  final StellarDatabase _db;

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    final raw = await _db.senderKeyDao.get(
      senderKeyName.groupId,
      senderKeyName.sender.getName(),
      senderKeyName.sender.getDeviceId(),
    );
    return raw == null ? SenderKeyRecord() : SenderKeyRecord.fromSerialized(raw);
  }

  @override
  Future<void> storeSenderKey(SenderKeyName senderKeyName, SenderKeyRecord record) {
    return _db.senderKeyDao.put(
      senderKeyName.groupId,
      senderKeyName.sender.getName(),
      senderKeyName.sender.getDeviceId(),
      record.serialize(),
    );
  }
}
