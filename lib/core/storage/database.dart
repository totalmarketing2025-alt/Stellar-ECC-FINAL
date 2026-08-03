import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../security/platform_key_store.dart';

/// Opens the ephemeral, SQLCipher-encrypted local message database and
/// exposes small DAO-style wrapper classes over hand-written SQL — no
/// code-generation step required to build this project.
class StellarDatabase {
  StellarDatabase._(this._db);

  final Database _db;

  late final TrustedIdentityDao trustedIdentityDao = TrustedIdentityDao(_db);
  late final PreKeyDao preKeyDao = PreKeyDao(_db);
  late final SignedPreKeyDao signedPreKeyDao = SignedPreKeyDao(_db);
  late final SessionDao sessionDao = SessionDao(_db);
  late final SenderKeyDao senderKeyDao = SenderKeyDao(_db);
  late final ChatDao chatDao = ChatDao(_db);
  late final MessageDao messageDao = MessageDao(_db);
  late final ReactionDao reactionDao = ReactionDao(_db);
  late final MediaBlobDao mediaBlobDao = MediaBlobDao(_db);

  static Future<StellarDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'stellar_ephemeral.sqlite');

    final keyStore = PlatformKeyStore();
    final rawKey = await keyStore.getOrCreateDatabaseKey();
    final hexKey = _bytesToHex(rawKey);

    final db = sqlite3.open(dbPath);
    // SQLCipher key pragma must be the first statement executed on the
    // connection, before any schema access.
    db.execute("PRAGMA key = \"x'$hexKey'\";");
    db.execute('PRAGMA cipher_page_size = 4096;');
    db.execute('PRAGMA kdf_iter = 256000;');
    db.execute('PRAGMA secure_delete = ON;'); // overwrite freed pages, see Phase 2
    db.execute('PRAGMA foreign_keys = ON;');

    _runMigrations(db);

    return StellarDatabase._(db);
  }

  static void _runMigrations(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS chat (
        chat_id         TEXT PRIMARY KEY,
        chat_type       TEXT NOT NULL,
        display_name    TEXT NOT NULL,
        default_ttl_sec INTEGER NOT NULL DEFAULT 3600,
        created_at      INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS message (
        message_id          TEXT PRIMARY KEY,
        chat_id              TEXT NOT NULL REFERENCES chat(chat_id) ON DELETE CASCADE,
        sender_id             TEXT NOT NULL,
        body_plaintext         TEXT,
        sent_at                 INTEGER NOT NULL,
        delivered_at             INTEGER,
        read_at                   INTEGER,
        expires_at                 INTEGER NOT NULL,
        reply_to_id                 TEXT REFERENCES message(message_id),
        status                       TEXT NOT NULL
      );
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_message_expiry ON message(expires_at);');
    db.execute('CREATE INDEX IF NOT EXISTS idx_message_chat ON message(chat_id);');

    db.execute('''
      CREATE TABLE IF NOT EXISTS reaction (
        message_id TEXT NOT NULL REFERENCES message(message_id) ON DELETE CASCADE,
        sender_id  TEXT NOT NULL,
        emoji      TEXT NOT NULL,
        PRIMARY KEY (message_id, sender_id)
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS media_blob (
        blob_id    TEXT PRIMARY KEY,
        message_id TEXT NOT NULL REFERENCES message(message_id) ON DELETE CASCADE,
        mime_type  TEXT NOT NULL,
        file_path  TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      );
    ''');

    // Signal protocol state — long-lived, no TTL, separate from the
    // ephemeral message tables above (Phase 2 §2A vs §2B distinction).
    db.execute('''
      CREATE TABLE IF NOT EXISTS trusted_identity (
        name      TEXT NOT NULL,
        device_id INTEGER NOT NULL,
        key_bytes BLOB NOT NULL,
        PRIMARY KEY (name, device_id)
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS pre_key (
        id     INTEGER PRIMARY KEY,
        record BLOB NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS signed_pre_key (
        id     INTEGER PRIMARY KEY,
        record BLOB NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS session (
        name      TEXT NOT NULL,
        device_id INTEGER NOT NULL,
        record    BLOB NOT NULL,
        PRIMARY KEY (name, device_id)
      );
    ''');

    // Sender Keys group state (Phase 3 §4) — persisted so group chats
    // survive an app restart, replacing the earlier in-memory-only store.
    db.execute('''
      CREATE TABLE IF NOT EXISTS sender_key (
        group_id  TEXT NOT NULL,
        sender    TEXT NOT NULL,
        device_id INTEGER NOT NULL,
        record    BLOB NOT NULL,
        PRIMARY KEY (group_id, sender, device_id)
      );
    ''');
  }

  static String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void close() => _db.dispose();
}

class TrustedIdentityDao {
  TrustedIdentityDao(this._db);
  final Database _db;

  Future<Uint8List?> get(String name, int deviceId) async {
    final rows = _db.select(
      'SELECT key_bytes FROM trusted_identity WHERE name = ? AND device_id = ?',
      [name, deviceId],
    );
    if (rows.isEmpty) return null;
    return rows.first['key_bytes'] as Uint8List;
  }

  Future<void> upsert(String name, int deviceId, Uint8List keyBytes) async {
    _db.execute(
      'INSERT INTO trusted_identity (name, device_id, key_bytes) VALUES (?, ?, ?) '
      'ON CONFLICT(name, device_id) DO UPDATE SET key_bytes = excluded.key_bytes',
      [name, deviceId, keyBytes],
    );
  }
}

class PreKeyDao {
  PreKeyDao(this._db);
  final Database _db;

  Future<Uint8List?> get(int id) async {
    final rows = _db.select('SELECT record FROM pre_key WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.first['record'] as Uint8List;
  }

  Future<void> put(int id, Uint8List record) async {
    _db.execute(
      'INSERT INTO pre_key (id, record) VALUES (?, ?) '
      'ON CONFLICT(id) DO UPDATE SET record = excluded.record',
      [id, record],
    );
  }

  Future<bool> contains(int id) async {
    final rows = _db.select('SELECT 1 FROM pre_key WHERE id = ?', [id]);
    return rows.isNotEmpty;
  }

  Future<void> remove(int id) async {
    _db.execute('DELETE FROM pre_key WHERE id = ?', [id]);
  }
}

class SignedPreKeyDao {
  SignedPreKeyDao(this._db);
  final Database _db;

  Future<Uint8List?> get(int id) async {
    final rows = _db.select('SELECT record FROM signed_pre_key WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.first['record'] as Uint8List;
  }

  Future<List<Uint8List>> getAll() async {
    final rows = _db.select('SELECT record FROM signed_pre_key');
    return rows.map((r) => r['record'] as Uint8List).toList();
  }

  Future<void> put(int id, Uint8List record) async {
    _db.execute(
      'INSERT INTO signed_pre_key (id, record) VALUES (?, ?) '
      'ON CONFLICT(id) DO UPDATE SET record = excluded.record',
      [id, record],
    );
  }

  Future<bool> contains(int id) async {
    final rows = _db.select('SELECT 1 FROM signed_pre_key WHERE id = ?', [id]);
    return rows.isNotEmpty;
  }

  Future<void> remove(int id) async {
    _db.execute('DELETE FROM signed_pre_key WHERE id = ?', [id]);
  }
}

class SessionDao {
  SessionDao(this._db);
  final Database _db;

  Future<Uint8List?> get(String name, int deviceId) async {
    final rows = _db.select(
      'SELECT record FROM session WHERE name = ? AND device_id = ?',
      [name, deviceId],
    );
    return rows.isEmpty ? null : rows.first['record'] as Uint8List;
  }

  Future<List<int>> deviceIdsFor(String name) async {
    final rows = _db.select('SELECT device_id FROM session WHERE name = ?', [name]);
    return rows.map((r) => r['device_id'] as int).toList();
  }

  Future<void> put(String name, int deviceId, Uint8List record) async {
    _db.execute(
      'INSERT INTO session (name, device_id, record) VALUES (?, ?, ?) '
      'ON CONFLICT(name, device_id) DO UPDATE SET record = excluded.record',
      [name, deviceId, record],
    );
  }

  Future<bool> contains(String name, int deviceId) async {
    final rows = _db.select(
      'SELECT 1 FROM session WHERE name = ? AND device_id = ?',
      [name, deviceId],
    );
    return rows.isNotEmpty;
  }

  Future<void> remove(String name, int deviceId) async {
    _db.execute('DELETE FROM session WHERE name = ? AND device_id = ?', [name, deviceId]);
  }

  Future<void> removeAllFor(String name) async {
    _db.execute('DELETE FROM session WHERE name = ?', [name]);
  }
}

class SenderKeyDao {
  SenderKeyDao(this._db);
  final Database _db;

  Future<Uint8List?> get(String groupId, String sender, int deviceId) async {
    final rows = _db.select(
      'SELECT record FROM sender_key WHERE group_id = ? AND sender = ? AND device_id = ?',
      [groupId, sender, deviceId],
    );
    return rows.isEmpty ? null : rows.first['record'] as Uint8List;
  }

  Future<void> put(String groupId, String sender, int deviceId, Uint8List record) async {
    _db.execute(
      'INSERT INTO sender_key (group_id, sender, device_id, record) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(group_id, sender, device_id) DO UPDATE SET record = excluded.record',
      [groupId, sender, deviceId, record],
    );
  }

  Future<void> removeAllForGroup(String groupId) async {
    _db.execute('DELETE FROM sender_key WHERE group_id = ?', [groupId]);
  }
}

class ChatDao {
  ChatDao(this._db);
  final Database _db;

  Future<void> insert({
    required String chatId,
    required String chatType,
    required String displayName,
    required int defaultTtlSec,
  }) async {
    _db.execute(
      'INSERT INTO chat (chat_id, chat_type, display_name, default_ttl_sec, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [chatId, chatType, displayName, defaultTtlSec, DateTime.now().millisecondsSinceEpoch ~/ 1000],
    );
  }

  Future<List<Map<String, Object?>>> all() async {
    return _db.select('SELECT * FROM chat ORDER BY created_at DESC');
  }

  Future<void> updateDefaultTtl(String chatId, int ttlSec) async {
    _db.execute('UPDATE chat SET default_ttl_sec = ? WHERE chat_id = ?', [ttlSec, chatId]);
  }

  Future<void> delete(String chatId) async {
    // ON DELETE CASCADE removes messages/reactions/media rows too.
    _db.execute('DELETE FROM chat WHERE chat_id = ?', [chatId]);
  }
}

class MessageDao {
  MessageDao(this._db);
  final Database _db;

  Future<void> insert({
    required String messageId,
    required String chatId,
    required String senderId,
    required String plaintext,
    required int ttlSeconds,
    String? replyToId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _db.execute(
      'INSERT INTO message '
      '(message_id, chat_id, sender_id, body_plaintext, sent_at, expires_at, reply_to_id, status) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [messageId, chatId, senderId, plaintext, now, now + ttlSeconds, replyToId, 'sending'],
    );
  }

  Future<List<Map<String, Object?>>> forChat(String chatId) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _db.select(
      'SELECT * FROM message WHERE chat_id = ? AND expires_at > ? ORDER BY sent_at ASC',
      [chatId, now],
    );
  }

  Future<List<Map<String, Object?>>> expired() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _db.select('SELECT message_id FROM message WHERE expires_at <= ?', [now]);
  }

  /// Secure erase: overwrite the plaintext column with random garbage before
  /// the row delete, so freed SQLite pages don't retain recoverable content
  /// (belt-and-suspenders alongside PRAGMA secure_delete).
  Future<void> secureDelete(String messageId) async {
    final garbage = _randomGarbage(128);
    _db.execute('UPDATE message SET body_plaintext = ? WHERE message_id = ?', [garbage, messageId]);
    _db.execute('DELETE FROM message WHERE message_id = ?', [messageId]);
  }

  Future<void> updateStatus(String messageId, String status) async {
    _db.execute('UPDATE message SET status = ? WHERE message_id = ?', [status, messageId]);
  }

  Future<void> markDelivered(String messageId) async {
    _db.execute(
      'UPDATE message SET status = ?, delivered_at = ? WHERE message_id = ?',
      ['delivered', DateTime.now().millisecondsSinceEpoch ~/ 1000, messageId],
    );
  }

  Future<void> markRead(String messageId) async {
    _db.execute(
      'UPDATE message SET status = ?, read_at = ? WHERE message_id = ?',
      ['read', DateTime.now().millisecondsSinceEpoch ~/ 1000, messageId],
    );
  }

  String _randomGarbage(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final buf = StringBuffer();
    final rand = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < length; i++) {
      buf.write(chars[(rand + i * 31) % chars.length]);
    }
    return buf.toString();
  }
}

class ReactionDao {
  ReactionDao(this._db);
  final Database _db;

  Future<void> add(String messageId, String senderId, String emoji) async {
    _db.execute(
      'INSERT INTO reaction (message_id, sender_id, emoji) VALUES (?, ?, ?) '
      'ON CONFLICT(message_id, sender_id) DO UPDATE SET emoji = excluded.emoji',
      [messageId, senderId, emoji],
    );
  }

  Future<List<Map<String, Object?>>> forMessage(String messageId) async {
    return _db.select('SELECT * FROM reaction WHERE message_id = ?', [messageId]);
  }
}

class MediaBlobDao {
  MediaBlobDao(this._db);
  final Database _db;

  Future<void> insert({
    required String blobId,
    required String messageId,
    required String mimeType,
    required String filePath,
    required int expiresAt,
  }) async {
    _db.execute(
      'INSERT INTO media_blob (blob_id, message_id, mime_type, file_path, expires_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [blobId, messageId, mimeType, filePath, expiresAt],
    );
  }

  Future<List<Map<String, Object?>>> expired() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _db.select('SELECT * FROM media_blob WHERE expires_at <= ?', [now]);
  }

  Future<void> delete(String blobId) async {
    _db.execute('DELETE FROM media_blob WHERE blob_id = ?', [blobId]);
  }
}
