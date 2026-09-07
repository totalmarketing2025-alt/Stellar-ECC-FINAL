import 'dart:convert';
import 'dart:typed_data';

/// Wire envelope sent to/from the relay.
///
/// Binary layout:
///   u16 envelopeVersion
///   u32 relayTtlSeconds
///   u16 deliveryTokenLength
///   bytes deliveryToken
///   u16 recipientRouteLength
///   UTF-8 recipientRoute
///   u32 ciphertextLength
///   bytes ciphertext
class Envelope {
  Envelope({
    required this.deliveryToken,
    required this.recipientRoute,
    required this.ciphertext,
    this.envelopeVersion = 1,
    this.relayTtlSeconds = 72 * 60 * 60,
  });

  final Uint8List deliveryToken;
  final String recipientRoute;
  final Uint8List ciphertext;
  final int envelopeVersion;
  final int relayTtlSeconds;

  Uint8List encode() {
    final recipientBytes = utf8.encode(recipientRoute);

    if (deliveryToken.length > 0xFFFF) {
      throw ArgumentError.value(
        deliveryToken.length,
        'deliveryToken',
        'must fit in a u16 length field',
      );
    }

    if (recipientBytes.length > 0xFFFF) {
      throw ArgumentError.value(
        recipientBytes.length,
        'recipientRoute',
        'UTF-8 representation must fit in a u16 length field',
      );
    }

    if (envelopeVersion < 0 || envelopeVersion > 0xFFFF) {
      throw ArgumentError.value(
        envelopeVersion,
        'envelopeVersion',
        'must fit in a u16 field',
      );
    }

    if (relayTtlSeconds < 0 || relayTtlSeconds > 0xFFFFFFFF) {
      throw ArgumentError.value(
        relayTtlSeconds,
        'relayTtlSeconds',
        'must fit in a u32 field',
      );
    }

    if (ciphertext.length > 0xFFFFFFFF) {
      throw ArgumentError.value(
        ciphertext.length,
        'ciphertext',
        'must fit in a u32 length field',
      );
    }

    final builder = BytesBuilder();
    builder.add(_u16(envelopeVersion));
    builder.add(_u32(relayTtlSeconds));

    builder.add(_u16(deliveryToken.length));
    builder.add(deliveryToken);

    builder.add(_u16(recipientBytes.length));
    builder.add(recipientBytes);

    builder.add(_u32(ciphertext.length));
    builder.add(ciphertext);

    return builder.toBytes();
  }

  static Envelope decode(Uint8List bytes) {
    var offset = 0;

    final version = _readU16(bytes, offset);
    offset += 2;

    final ttl = _readU32(bytes, offset);
    offset += 4;

    final tokenLen = _readU16(bytes, offset);
    offset += 2;
    _requireAvailable(bytes, offset, tokenLen, 'delivery token');
    final token = bytes.sublist(offset, offset + tokenLen);
    offset += tokenLen;

    final routeLen = _readU16(bytes, offset);
    offset += 2;
    _requireAvailable(bytes, offset, routeLen, 'recipient route');
    final routeBytes = bytes.sublist(offset, offset + routeLen);
    offset += routeLen;

    final ctLen = _readU32(bytes, offset);
    offset += 4;
    _requireAvailable(bytes, offset, ctLen, 'ciphertext');
    final ciphertext = bytes.sublist(offset, offset + ctLen);
    offset += ctLen;

    if (offset != bytes.length) {
      throw FormatException(
        'Envelope contains ${bytes.length - offset} trailing bytes',
      );
    }

    final route = utf8.decode(routeBytes);

    return Envelope(
      deliveryToken: token,
      recipientRoute: route,
      ciphertext: ciphertext,
      envelopeVersion: version,
      relayTtlSeconds: ttl,
    );
  }

  static void _requireAvailable(
    Uint8List bytes,
    int offset,
    int length,
    String field,
  ) {
    if (length < 0 || offset < 0 || offset > bytes.length - length) {
      throw FormatException(
        'Truncated or invalid $field: need $length bytes at offset $offset, '
        'but envelope contains ${bytes.length} bytes',
      );
    }
  }

  static Uint8List _u16(int value) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.big);

  static Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

  static int _readU16(Uint8List bytes, int offset) {
    _requireAvailable(bytes, offset, 2, 'u16 field');
    return ByteData.sublistView(bytes, offset, offset + 2)
        .getUint16(0, Endian.big);
  }

  static int _readU32(Uint8List bytes, int offset) {
    _requireAvailable(bytes, offset, 4, 'u32 field');
    return ByteData.sublistView(bytes, offset, offset + 4)
        .getUint32(0, Endian.big);
  }
}
