import 'dart:convert';
import 'dart:typed_data';

/// Wire envelope sent to/from the relay (Phase 4 §2). Hand-encoded as a
/// compact length-prefixed binary layout rather than generated protobuf
/// (avoids depending on the `protoc` toolchain being available to verify
/// codegen in this environment) — same field set and same metadata-
/// minimization property: the relay only ever sees a rotating delivery
/// token, an opaque recipient route, and ciphertext bytes.
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
    final token = bytes.sublist(offset, offset + tokenLen);
    offset += tokenLen;

    final routeLen = _readU16(bytes, offset);
    offset += 2;
    final route = utf8.decode(bytes.sublist(offset, offset + routeLen));
    offset += routeLen;

    final ctLen = _readU32(bytes, offset);
    offset += 4;
    final ciphertext = bytes.sublist(offset, offset + ctLen);

    return Envelope(
      deliveryToken: token,
      recipientRoute: route,
      ciphertext: ciphertext,
      envelopeVersion: version,
      relayTtlSeconds: ttl,
    );
  }

  static Uint8List _u16(int value) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.big);

  static Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

  static int _readU16(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.big);

  static int _readU32(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
}
