import 'dart:convert';
import 'dart:typed_data';

class AttachmentPayload {
  static const String _magic = 'STELLAR_ATTACH_V1:';
  static const int maxBytes = 8 * 1024 * 1024;

  static Uint8List encode({
    required String mimeType,
    required Uint8List bytes,
  }) {
    if (bytes.length > maxBytes) {
      throw StateError(
        'Attachment is too large. Maximum size is 8 MB.',
      );
    }

    final mimeBytes = Uint8List.fromList(utf8.encode(mimeType));

    if (mimeBytes.length > 0xFFFF) {
      throw ArgumentError('MIME type is too long');
    }

    final builder = BytesBuilder();
    builder.add(Uint8List.fromList(utf8.encode(_magic)));
    builder.add(_u16(mimeBytes.length));
    builder.add(mimeBytes);
    builder.add(_u32(bytes.length));
    builder.add(bytes);

    return builder.toBytes();
  }

  static AttachmentPayloadData? decode(Uint8List bytes) {
    final magic = Uint8List.fromList(
      utf8.encode(_magic),
    );

    if (bytes.length < magic.length ||
        !_startsWith(bytes, magic)) {
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
  });

  final String mimeType;
  final Uint8List bytes;
}
