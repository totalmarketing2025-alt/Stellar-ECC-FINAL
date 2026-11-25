import 'dart:convert';
import 'dart:typed_data';

class AttachmentPayload {
  static const String _magic = 'STELLAR_ATTACH_V1:';
  static const String _ephemeralMagic = 'STELLAR_ATTACH_V2:';
  static const int maxBytes = 8 * 1024 * 1024;

  static Uint8List encode({
    required String mimeType,
    required Uint8List bytes,
    String viewMode = 'normal',
    int viewSeconds = 0,
  }) {
    if (bytes.length > maxBytes) {
      throw StateError(
        'Attachment is too large. Maximum size is 8 MB.',
      );
    }

    if (viewMode != 'normal' &&
        !mimeType.toLowerCase().startsWith('image/') &&
        !mimeType.toLowerCase().startsWith('video/')) {
      throw ArgumentError('View-once media must be an image or video');
    }
    if (viewMode == 'timed' && !const {10, 30, 60}.contains(viewSeconds)) {
      throw ArgumentError('Unsupported attachment view duration');
    }
    if (viewMode == 'view_once') viewSeconds = 0;
    if (viewMode != 'normal' && viewMode != 'timed' && viewMode != 'view_once') {
      throw ArgumentError('Unsupported attachment view mode');
    }

    final mimeBytes = Uint8List.fromList(utf8.encode(mimeType));

    if (mimeBytes.length > 0xFFFF) {
      throw ArgumentError('MIME type is too long');
    }

    final builder = BytesBuilder();
    builder.add(Uint8List.fromList(
      utf8.encode(viewMode == 'normal' ? _magic : _ephemeralMagic),
    ));
    builder.add(_u16(mimeBytes.length));
    builder.add(mimeBytes);
    if (viewMode != 'normal') {
      builder.add(Uint8List.fromList([
        viewMode == 'view_once' ? 1 : 2,
        viewSeconds,
      ]));
    }
    builder.add(_u32(bytes.length));
    builder.add(bytes);

    return builder.toBytes();
  }

  static AttachmentPayloadData? decode(Uint8List bytes) {
    final v1Magic = Uint8List.fromList(utf8.encode(_magic));
    final v2Magic = Uint8List.fromList(utf8.encode(_ephemeralMagic));
    final isV2 = _startsWith(bytes, v2Magic);
    final magic = isV2 ? v2Magic : v1Magic;

    if (bytes.length < magic.length || !_startsWith(bytes, magic)) {
      return null;
    }

    var offset = magic.length;

    final mimeLength = _readU16(bytes, offset);
    offset += 2;

    if (offset + mimeLength > bytes.length) {
      throw FormatException('Invalid attachment MIME length');
    }

    final mimeType = utf8.decode(
      bytes.sublist(offset, offset + mimeLength),
    );
    offset += mimeLength;

    var viewMode = 'normal';
    var viewSeconds = 0;
    if (isV2) {
      if (offset + 2 > bytes.length) {
        throw FormatException('Truncated attachment view policy');
      }
      final mode = bytes[offset++];
      viewSeconds = bytes[offset++];
      viewMode = switch (mode) {
        1 => 'view_once',
        2 => 'timed',
        _ => throw FormatException('Invalid attachment view mode'),
      };
      if (viewMode == 'view_once' && viewSeconds != 0 ||
          viewMode == 'timed' && !const {10, 30, 60}.contains(viewSeconds)) {
        throw FormatException('Invalid attachment view duration');
      }
      if (!mimeType.toLowerCase().startsWith('image/') &&
          !mimeType.toLowerCase().startsWith('video/')) {
        throw FormatException('View-once mode requires image or video');
      }
    }

    final dataLength = _readU32(bytes, offset);
    offset += 4;

    if (dataLength > maxBytes) {
      throw FormatException('Attachment exceeds 8 MB limit');
    }

    if (offset + dataLength != bytes.length) {
      throw FormatException('Invalid attachment payload length');
    }

    return AttachmentPayloadData(
      mimeType: mimeType,
      bytes: Uint8List.fromList(
        bytes.sublist(offset, offset + dataLength),
      ),
      viewMode: viewMode,
      viewSeconds: viewSeconds,
    );
  }

  static bool _startsWith(Uint8List data, Uint8List prefix) {
    if (data.length < prefix.length) return false;

    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }

    return true;
  }

  static Uint8List _u16(int value) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.big);

  static Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

  static int _readU16(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 2 > bytes.length) {
      throw FormatException('Truncated attachment u16');
    }

    return ByteData.sublistView(
      bytes,
      offset,
      offset + 2,
    ).getUint16(0, Endian.big);
  }

  static int _readU32(Uint8List bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) {
      throw FormatException('Truncated attachment u32');
    }

    return ByteData.sublistView(
      bytes,
      offset,
      offset + 4,
    ).getUint32(0, Endian.big);
  }
}

class AttachmentPayloadData {
  const AttachmentPayloadData({
    required this.mimeType,
    required this.bytes,
    this.viewMode = 'normal',
    this.viewSeconds = 0,
  });

  final String mimeType;
  final Uint8List bytes;
  final String viewMode;
  final int viewSeconds;
}
