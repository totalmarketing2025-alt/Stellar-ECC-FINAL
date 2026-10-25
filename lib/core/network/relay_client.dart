import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'directory_client.dart';
import 'envelope.dart';
import '../crypto/signal_stores.dart';

class RelayDelivery {
  const RelayDelivery({
    required this.bytes,
    required this.deliveryId,
    required this.senderNickname,
  });

  final Uint8List bytes;

  /// Non-null only for a queued relay delivery.
  final int? deliveryId;

  /// Authenticated sender identity supplied by the relay.
  ///
  /// This is routing metadata only. The encrypted envelope remains
  /// responsible for cryptographic authentication.
  final String? senderNickname;
}

class _PendingRelayDelivery {
  _PendingRelayDelivery({
    this.deliveryId,
    this.senderNickname,
  });

  final int? deliveryId;
  String? senderNickname;

  String? chunkTransferId;
  int? chunkCount;
  int nextChunkIndex = 0;
  final List<Uint8List> chunks = <Uint8List>[];

  bool get isChunked =>
      chunkTransferId != null &&
      chunkCount != null &&
      chunkCount! > 0;

  bool get isComplete =>
      isChunked &&
      nextChunkIndex == chunkCount &&
      chunks.length == chunkCount;
}

/// WebSocket client for the Stellar relay.
///
/// The relay only transports opaque bytes. Signal encryption/decryption
/// happens before/after transport and is never performed by this client.
class RelayClient {
  RelayClient({
    required this.relayUrl,
    required this.identityStore,
  });

  final String relayUrl;
  final StellarIdentityKeyStore identityStore;

  WebSocketChannel? _channel;
  StreamController<Uint8List>? _incomingController;
  StreamController<RelayDelivery>? _incomingDeliveryController;

  // Broadcast streams drop events when there are no listeners.
  // Keep a small bounded delivery buffer during startup so a valid
  // relay delivery cannot be lost before RelayListener subscribes.
  static const _maxBufferedIncomingDeliveries = 64;
  final List<RelayDelivery> _bufferedIncomingDeliveries =
      <RelayDelivery>[];

  final List<_PendingRelayDelivery> _pendingDeliveries =
      <_PendingRelayDelivery>[];

  _PendingRelayDelivery? _expectedChunkBinary;

  bool _manuallyDisconnected = false;
  int _backoffMs = 500;

  static const _maxBackoffMs = 30000;

  static const _challengePrefix =
      'STELLAR_RELAY_AUTH_CHALLENGE_V1:';

  static const _responsePrefix =
      'STELLAR_RELAY_AUTH_RESPONSE_V1:';

  static const _authOk =
      'STELLAR_RELAY_AUTH_OK_V1';

  static const _deliveryPrefix =
      'STELLAR_RELAY_DELIVERY_V1:';

  static const _senderPrefix =
      'STELLAR_RELAY_SENDER_V1:';

  static const _chunkPrefix =
      'STELLAR_RELAY_CHUNK_V1:';

  static const _ackPrefix =
      'STELLAR_RELAY_ACK_V1:';

  static const _ackOkPrefix =
      'STELLAR_RELAY_ACK_OK_V1:';

  // Transport-level confirmation for an outgoing envelope.
  static const _sendReceiptPrefix =
      'STELLAR_RELAY_SEND_V1:';

  static const _sendReceiptOkPrefix =
      'STELLAR_RELAY_SEND_OK_V1:';

  static const _uploadStartPrefix =
      'STELLAR_UPLOAD_START_V1:';

  static const _uploadFrameMagic = 'STUP1';

  static const _uploadAckPrefix =
      'STELLAR_UPLOAD_ACK_V1:';

  static const _uploadDonePrefix =
      'STELLAR_UPLOAD_DONE_V1:';

  static const _uploadErrorPrefix =
      'STELLAR_UPLOAD_ERROR_V1:';

  static const _uploadChunkSize = 128 * 1024;
  static const _uploadMaxBytes = 9 * 1024 * 1024;
  static const _directEnvelopeMaxBytes = 512 * 1024;

  String? _lastPeer;

  Stream<Uint8List> get incoming =>
      (_incomingController ??=
              StreamController<Uint8List>.broadcast())
          .stream;

  Stream<RelayDelivery> get incomingDelivery =>
      (_incomingDeliveryController ??=
              StreamController<RelayDelivery>.broadcast(
                onListen: _flushBufferedIncomingDeliveries,
              ))
          .stream;

  void _emitIncomingDelivery(RelayDelivery delivery) {
    final controller = _incomingDeliveryController ??=
        StreamController<RelayDelivery>.broadcast(
          onListen: _flushBufferedIncomingDeliveries,
        );

    if (!controller.hasListener) {
      if (_bufferedIncomingDeliveries.length >=
          _maxBufferedIncomingDeliveries) {
        _bufferedIncomingDeliveries.removeAt(0);
      }

      _bufferedIncomingDeliveries.add(delivery);
      return;
    }

    controller.add(delivery);
  }

  void _flushBufferedIncomingDeliveries() {
    final controller = _incomingDeliveryController;

    if (controller == null ||
        !controller.hasListener ||
        _bufferedIncomingDeliveries.isEmpty) {
      return;
    }

    final buffered =
        List<RelayDelivery>.from(_bufferedIncomingDeliveries);
    _bufferedIncomingDeliveries.clear();

    for (final delivery in buffered) {
      controller.add(delivery);
    }
  }

  bool get isConnected => _channel != null && _ready == true;
  bool? _ready;
  Timer? _reconnectTimer;
  Future<void>? _connectFuture;
  Completer<void>? _authCompleter;
  final Map<int, Completer<void>> _ackWaiters =
      <int, Completer<void>>{};

  final Map<String, Completer<void>> _sendReceiptWaiters =
      <String, Completer<void>>{};

  final Map<String, Completer<Map<String, dynamic>>>
      _uploadAckWaiters =
      <String, Completer<Map<String, dynamic>>>{};

  Future<void> connect({
    required String peer,
  }) async {
    if (_manuallyDisconnected) {
      _manuallyDisconnected = false;
    }

    _lastPeer = peer;

    final existing = _connectFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = _connectInternal(peer);
    _connectFuture = future;

    try {
      await future;
    } finally {
      if (identical(_connectFuture, future)) {
        _connectFuture = null;
      }
    }
  }

  Future<void> _connectInternal(String peer) async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    if (_channel != null && _ready == true) {
      return;
    }

    final base = Uri.parse(relayUrl);
    final uri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        'peer': peer,
      },
    );

    WebSocketChannel? channel;

    try {
      final connectedChannel = WebSocketChannel.connect(uri);
      channel = connectedChannel;

      _channel = connectedChannel;
      _ready = false;
      _pendingDeliveries.clear();
      _expectedChunkBinary = null;

      print('RELAY_DEBUG: BEFORE_READY peer=$peer');
      await connectedChannel.ready;
      print('RELAY_DEBUG: AFTER_READY peer=$peer');

      if (!identical(_channel, channel) || _manuallyDisconnected) {
        await channel.sink.close(ws_status.normalClosure);
        return;
      }

      _ready = false;
      _backoffMs = 500;
      _authCompleter = Completer<void>();

      connectedChannel.stream.listen(
        (data) {
          if (!identical(_channel, connectedChannel)) {
            return;
          }

          if (data is List<int>) {
            final bytes = Uint8List.fromList(data);

            // Only consume a binary frame as a chunk when the immediately
            // preceding valid chunk-control frame selected this delivery.
            final chunkedPending = _expectedChunkBinary;
            _expectedChunkBinary = null;

            if (chunkedPending != null &&
                _pendingDeliveries.contains(chunkedPending) &&
                chunkedPending.isChunked &&
                chunkedPending.nextChunkIndex <
                    (chunkedPending.chunkCount ?? 0)) {
              chunkedPending.chunks.add(bytes);
              chunkedPending.nextChunkIndex++;

              if (chunkedPending.isComplete) {
                final totalLength = chunkedPending.chunks.fold<int>(
                  0,
                  (sum, chunk) => sum + chunk.length,
                );

                final reassembled = Uint8List(totalLength);
                var offset = 0;

                for (final chunk in chunkedPending.chunks) {
                  reassembled.setRange(
                    offset,
                    offset + chunk.length,
                    chunk,
                  );
                  offset += chunk.length;
                }

                _pendingDeliveries.remove(chunkedPending);

                (_incomingController ??=
                        StreamController<Uint8List>.broadcast())
                    .add(reassembled);

                _emitIncomingDelivery(
                  RelayDelivery(
                    bytes: reassembled,
                    deliveryId: chunkedPending.deliveryId,
                    senderNickname: chunkedPending.senderNickname,
                  ),
                );
              }

              return;
            }

            // A normal whole-envelope frame must not consume an unfinished
            // chunked delivery's routing metadata.
            _PendingRelayDelivery? pending;
            for (final candidate in _pendingDeliveries) {
              if (!candidate.isChunked) {
                pending = candidate;
                break;
              }
            }
            if (pending != null) {
              _pendingDeliveries.remove(pending);
            }

            (_incomingController ??=
                    StreamController<Uint8List>.broadcast())
                .add(bytes);

            _emitIncomingDelivery(
              RelayDelivery(
                bytes: bytes,
                deliveryId: pending?.deliveryId,
                senderNickname: pending?.senderNickname,
              ),
            );
          } else if (data is String) {
            _expectedChunkBinary = null;

            if (data.startsWith(_uploadAckPrefix)) {
              try {
                final value = jsonDecode(
                  data.substring(_uploadAckPrefix.length),
                );
                if (value is Map<String, dynamic>) {
                  final uploadId = value['uploadId']?.toString() ?? '';
                  final waiter = _uploadAckWaiters[uploadId];
                  if (waiter != null && !waiter.isCompleted) {
                    waiter.complete(value);
                  }
                }
              } catch (_) {
                // Ignore malformed upload control frames.
              }
              return;
            }

            if (data.startsWith(_uploadErrorPrefix)) {
              try {
                final value = jsonDecode(
                  data.substring(_uploadErrorPrefix.length),
                );
                if (value is Map<String, dynamic>) {
                  final uploadId = value['uploadId']?.toString() ?? '';
                  final code = value['code']?.toString() ??
                      'upload_failed';
                  final waiter = _uploadAckWaiters[uploadId];
                  if (waiter != null && !waiter.isCompleted) {
                    waiter.completeError(
                      StateError('Relay upload failed: $code'),
                    );
                  }
                }
              } catch (_) {
                // Ignore malformed upload control frames.
              }
              return;
            }

            if (data.startsWith(_sendReceiptOkPrefix)) {
              final receiptId =
                  data.substring(_sendReceiptOkPrefix.length).trim();

              if (receiptId.isNotEmpty) {
                final waiter = _sendReceiptWaiters.remove(receiptId);
                if (waiter != null && !waiter.isCompleted) {
                  waiter.complete();
                }
              }

              return;
            }

            if (data.startsWith(_ackOkPrefix)) {
              final deliveryId = int.tryParse(
                data.substring(_ackOkPrefix.length),
              );

              if (deliveryId != null && deliveryId > 0) {
                final waiter = _ackWaiters.remove(deliveryId);

                if (waiter != null && !waiter.isCompleted) {
                  waiter.complete();
                }
              }

              return;
            }

            if (data.startsWith(_deliveryPrefix)) {
              final deliveryId = int.tryParse(
                data.substring(_deliveryPrefix.length),
              );

              if (deliveryId != null && deliveryId > 0) {
                _pendingDeliveries.add(
                  _PendingRelayDelivery(
                    deliveryId: deliveryId,
                  ),
                );
              }

              return;
            }

            if (data.startsWith(_senderPrefix)) {
              final sender = data
                  .substring(_senderPrefix.length)
                  .trim()
                  .toLowerCase();

              if (sender.isNotEmpty) {
                _PendingRelayDelivery? target;

                for (var i = _pendingDeliveries.length - 1;
                    i >= 0;
                    i--) {
                  final candidate = _pendingDeliveries[i];

                  if (candidate.senderNickname == null) {
                    target = candidate;
                    break;
                  }
                }

                if (target != null) {
                  target.senderNickname = sender;
                } else {
                  _pendingDeliveries.add(
                    _PendingRelayDelivery(
                      senderNickname: sender,
                    ),
                  );
                }
              }

              return;
            }

            if (data.startsWith(_chunkPrefix)) {
              final raw = data.substring(_chunkPrefix.length);
              final parts = raw.split(':');

              if (parts.length != 3) {
                return;
              }

              final transferId = parts[0].trim();
              final chunkIndex = int.tryParse(parts[1]);
              final chunkCount = int.tryParse(parts[2]);

              if (transferId.isEmpty ||
                  chunkIndex == null ||
                  chunkCount == null ||
                  chunkIndex < 0 ||
                  chunkCount <= 0 ||
                  chunkIndex >= chunkCount) {
                return;
              }

              _PendingRelayDelivery? target;

              for (final candidate in _pendingDeliveries) {
                if (candidate.chunkTransferId == transferId) {
                  target = candidate;
                  break;
                }
              }

              if (target == null) {
                /*
                 * Queued deliveries already have a delivery prefix.
                 * The transfer id is the same logical delivery id.
                 */
                for (var i = _pendingDeliveries.length - 1;
                    i >= 0;
                    i--) {
                  final candidate = _pendingDeliveries[i];

                  if (candidate.chunkTransferId == null &&
                      candidate.deliveryId?.toString() ==
                          transferId) {
                    target = candidate;
                    break;
                  }
                }
              }

              if (target == null) {
                /*
                 * Chunk transfers are currently used for queued
                 * deliveries and must be correlated to their
                 * explicit delivery id.
                 *
                 * Never attach an unexpected chunk stream to an
                 * arbitrary pending delivery.
                 */
                return;
              }

              if (target.chunkTransferId == null) {
                target.chunkTransferId = transferId;
                target.chunkCount = chunkCount;
                target.nextChunkIndex = 0;
                target.chunks.clear();
              }

              if (target.chunkTransferId != transferId ||
                  target.chunkCount != chunkCount ||
                  target.nextChunkIndex != chunkIndex) {
                return;
              }

              _expectedChunkBinary = target;
              return;
            }

            if (data.startsWith(_challengePrefix)) {
              unawaited(
                _authenticateRelay(
                  connectedChannel,
                  peer,
                  data.substring(_challengePrefix.length),
                ),
              );
              return;
            }

            if (data == _authOk) {
              if (identical(_channel, channel)) {
                _ready = true;

                final completer = _authCompleter;
                if (completer != null && !completer.isCompleted) {
                  completer.complete();
                }
              }
              return;
            }

            /*
             * Relay control frames must never enter the
             * encrypted envelope decoder.
             */
            return;
          }
        },
        onDone: () {
          if (identical(_channel, connectedChannel)) {
            _handleDisconnect();
          }
        },
        onError: (_) {
          if (identical(_channel, connectedChannel)) {
            _handleDisconnect();
          }
        },
        cancelOnError: true,
      );

      final authCompleter = _authCompleter;
      if (authCompleter != null) {
        await authCompleter.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw StateError('Relay authentication timed out');
          },
        );
      }

      if (!identical(_channel, channel) ||
          _manuallyDisconnected ||
          _ready != true) {
        throw StateError('Relay authentication failed');
      }
    } catch (_) {
      if (identical(_channel, channel)) {
        _channel = null;
        _ready = false;
      }
      _scheduleReconnect();
      rethrow;
    }
  }

  Future<void> _authenticateRelay(
    WebSocketChannel channel,
    String peer,
    String challenge,
  ) async {
    if (!identical(_channel, channel) || _manuallyDisconnected) {
      return;
    }

    try {
      final nickname = peer.trim().toLowerCase();

      final identityKeyPair =
          await identityStore.getIdentityKeyPair();

      final registrationId =
          await identityStore.getLocalRegistrationId();

      const deviceId = 1;

      final message =
          DirectoryClient.buildRelayAuthMessage(
        nickname: nickname,
        deviceId: deviceId,
        registrationId: registrationId,
        challenge: challenge,
      );

      final signature = Curve.calculateSignature(
        identityKeyPair.getPrivateKey(),
        Uint8List.fromList(
          utf8.encode(message),
        ),
      );

      final payload = jsonEncode({
        'challenge': challenge,
        'deviceId': deviceId,
        'registrationId': registrationId,
        'signature': base64Encode(signature),
      });

      if (!identical(_channel, channel) ||
          _manuallyDisconnected) {
        return;
      }

      channel.sink.add(
        '$_responsePrefix$payload',
      );
    } catch (_) {
      if (identical(_channel, channel)) {
        try {
          await channel.sink.close(
            ws_status.policyViolation,
          );
        } catch (_) {}
      }
    }
  }

  void _handleDisconnect() {
    final completer = _authCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        StateError('Relay connection disconnected before authentication'),
      );
    }

    _authCompleter = null;

    for (final waiter in _ackWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          StateError(
            'Relay connection closed before ACK confirmation',
          ),
        );
      }
    }

    _ackWaiters.clear();

    for (final waiter in _uploadAckWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          StateError(
            'Relay connection closed during attachment upload',
          ),
        );
      }
    }

    _uploadAckWaiters.clear();

    for (final waiter in _sendReceiptWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          StateError(
            'Relay connection closed before send receipt confirmation',
          ),
        );
      }
    }

    _sendReceiptWaiters.clear();

    _channel = null;
    _ready = false;
    _expectedChunkBinary = null;

    if (!_manuallyDisconnected) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    final peer = _lastPeer;

    if (peer == null || _manuallyDisconnected) {
      return;
    }

    if (_reconnectTimer?.isActive == true) {
      return;
    }

    final delay = _backoffMs;

    _reconnectTimer = Timer(
      Duration(milliseconds: delay),
      () async {
        _reconnectTimer = null;

        if (_manuallyDisconnected) {
          return;
        }

        _backoffMs =
            (_backoffMs * 2).clamp(500, _maxBackoffMs);

        try {
          await connect(peer: peer);
        } catch (_) {
          // connect() already scheduled the next reconnect.
        }
      },
    );
  }

  Future<Map<String, dynamic>> _waitForUploadAck(
    String uploadId,
  ) async {
    if (_uploadAckWaiters.containsKey(uploadId)) {
      throw StateError('Upload ACK waiter already exists');
    }

    final completer = Completer<Map<String, dynamic>>();
    _uploadAckWaiters[uploadId] = completer;

    try {
      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          'Timed out waiting for relay upload ACK',
        ),
      );
    } finally {
      if (identical(_uploadAckWaiters[uploadId], completer)) {
        _uploadAckWaiters.remove(uploadId);
      }
    }
  }

  String _newUploadId() {
    const digits = '0123456789abcdef';
    final random = Random.secure();
    final hex = List<String>.generate(
      32,
      (_) => digits[random.nextInt(digits.length)],
    ).join();

    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  void _requireUploadAck(
    Map<String, dynamic> ack, {
    required String type,
    required String uploadId,
    int? index,
  }) {
    if (ack['type'] != type || ack['uploadId'] != uploadId) {
      throw StateError('Unexpected relay upload ACK');
    }

    if (index != null && ack['index'] != index) {
      throw StateError('Relay acknowledged an unexpected chunk');
    }
  }

  Future<void> _sendLargeEnvelope(Uint8List envelopeBytes) async {
    if (envelopeBytes.isEmpty ||
        envelopeBytes.length > _uploadMaxBytes) {
      throw ArgumentError(
        'Envelope size is outside the supported upload limit',
      );
    }

    final channel = _channel;
    if (channel == null || _ready != true) {
      throw StateError('Relay is not connected and ready');
    }

    final envelope = Envelope.decode(envelopeBytes);
    final recipient = envelope.recipientRoute;

    if (recipient.trim().isEmpty || recipient.length > 128) {
      throw ArgumentError('Invalid envelope recipient');
    }

    final uploadId = _newUploadId();
    final chunkCount =
        (envelopeBytes.length + _uploadChunkSize - 1) ~/
            _uploadChunkSize;

    final startFuture = _waitForUploadAck(uploadId);
    channel.sink.add(
      '$_uploadStartPrefix${jsonEncode({
        'uploadId': uploadId,
        'recipient': recipient,
        'totalBytes': envelopeBytes.length,
        'chunkCount': chunkCount,
      })}',
    );

    final startAck = await startFuture;
    _requireUploadAck(
      startAck,
      type: 'started',
      uploadId: uploadId,
    );

    for (var index = 0; index < chunkCount; index++) {
      if (!identical(_channel, channel) || _ready != true) {
        throw StateError('Relay disconnected during attachment upload');
      }

      final start = index * _uploadChunkSize;
      final end = (start + _uploadChunkSize < envelopeBytes.length)
          ? start + _uploadChunkSize
          : envelopeBytes.length;
      final chunk = envelopeBytes.sublist(start, end);

      // Wire header: STUP1 (5 bytes), UUID (36 bytes), then
      // chunk index, chunk count and total envelope size (u32 BE).
      final frame = Uint8List(53 + chunk.length);
      frame.setRange(0, 5, _uploadFrameMagic.codeUnits);
      frame.setRange(5, 41, uploadId.codeUnits);

      final header = ByteData.sublistView(frame);
      header.setUint32(41, index, Endian.big);
      header.setUint32(45, chunkCount, Endian.big);
      header.setUint32(49, envelopeBytes.length, Endian.big);
      frame.setRange(53, frame.length, chunk);

      final chunkFuture = _waitForUploadAck(uploadId);
      channel.sink.add(frame);

      final chunkAck = await chunkFuture;
      _requireUploadAck(
        chunkAck,
        type: 'chunk',
        uploadId: uploadId,
        index: index,
      );

      if (chunkAck['receivedBytes'] != end) {
        throw StateError('Relay reported an unexpected received byte count');
      }
    }

    if (!identical(_channel, channel) || _ready != true) {
      throw StateError('Relay disconnected before upload completion');
    }

    final doneFuture = _waitForUploadAck(uploadId);
    channel.sink.add(
      '$_uploadDonePrefix${jsonEncode({
        'uploadId': uploadId,
      })}',
    );

    final doneAck = await doneFuture;
    _requireUploadAck(
      doneAck,
      type: 'done',
      uploadId: uploadId,
    );

    if (doneAck['totalBytes'] != envelopeBytes.length) {
      throw StateError('Relay confirmed an unexpected envelope size');
    }
  }

  Future<void> send(Uint8List envelopeBytes) async {
    final channel = _channel;

    if (channel == null || _ready != true) {
      throw StateError(
        'Relay is not connected and ready',
      );
    }

    if (envelopeBytes.length > _directEnvelopeMaxBytes) {
      await _sendLargeEnvelope(envelopeBytes);
      return;
    }

    channel.sink.add(envelopeBytes);
  }

  /// Sends an envelope with a relay-level acceptance receipt.
  ///
  /// The relay server must implement STELLAR_RELAY_SEND_V1 and return
  /// STELLAR_RELAY_SEND_OK_V1 with the same receipt ID only after it
  /// has accepted responsibility for the envelope.
  ///
  /// This method is introduced separately; existing send() behavior
  /// remains unchanged until the server and outbox patches are applied.
  Future<void> sendWithReceipt({
    required String receiptId,
    required Uint8List envelopeBytes,
  }) async {
    final id = receiptId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(receiptId, 'receiptId', 'Must not be empty');
    }

    final channel = _channel;
    if (channel == null || _ready != true) {
      throw StateError('Relay is not connected and ready');
    }

    if (envelopeBytes.length > _directEnvelopeMaxBytes) {
      throw StateError(
        'Receipt-based send currently supports direct envelopes only',
      );
    }

    if (_sendReceiptWaiters.containsKey(id)) {
      throw StateError('A send receipt is already pending for ID: $id');
    }

    final waiter = Completer<void>();
    _sendReceiptWaiters[id] = waiter;

    try {
      channel.sink.add('$_sendReceiptPrefix$id');
      channel.sink.add(envelopeBytes);

      await waiter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw StateError('Relay send receipt timed out: $id');
        },
      );
    } finally {
      if (identical(_sendReceiptWaiters[id], waiter)) {
        _sendReceiptWaiters.remove(id);
      }
    }
  }

  Future<void> sendCallSignal({
    required String recipient,
    required Uint8List plaintext,
  }) async {
    final deliveryToken = Uint8List.fromList(
      List<int>.generate(
        16,
        (_) => Random.secure().nextInt(256),
      ),
    );

    final envelope = Envelope(
      deliveryToken: deliveryToken,
      recipientRoute: recipient,
      ciphertext: plaintext,
      relayTtlSeconds: 120,
    );

    await send(envelope.encode());
  }

  Future<void> sendCallWake({
    required String recipient,
    required String callId,
    required String kind,
    String? chatId,
  }) async {
    final payload = <String, dynamic>{
      'recipient': recipient,
      'callId': callId,
      'kind': kind,
      if (chatId != null && chatId.isNotEmpty) 'chatId': chatId,
    };

    Object? lastError;

    for (var attempt = 0; attempt < 3; attempt++) {
      WebSocketChannel? attemptedChannel;

      try {
        var channel = _channel;

        if (channel == null || _ready != true) {
          final peer = _lastPeer;

          if (peer == null || peer.isEmpty) {
            throw StateError(
              'Relay peer is not available for CALL_WAKE retry',
            );
          }

          await connect(peer: peer);

          channel = _channel;

          if (channel == null || _ready != true) {
            throw StateError(
              'Relay did not become ready for CALL_WAKE',
            );
          }
        }

        attemptedChannel = channel;

        channel.sink.add(
          'STELLAR_CALL_WAKE_V1:${jsonEncode(payload)}',
        );

        return;
      } catch (error) {
        lastError = error;

        if (attemptedChannel != null &&
            identical(_channel, attemptedChannel)) {
          _handleDisconnect();
        }

        if (attempt < 2) {
          await Future<void>.delayed(
            const Duration(milliseconds: 300),
          );
        }
      }
    }

    throw StateError(
      'Relay CALL_WAKE failed after 3 attempts: $lastError',
    );
  }

  Future<void> acknowledgeDelivery(
    int deliveryId,
  ) async {
    if (deliveryId <= 0) {
      return;
    }

    Object? lastError;

    for (var attempt = 0; attempt < 3; attempt++) {
      final channel = _channel;

      if (channel == null || _ready != true) {
        lastError = StateError(
          'Relay is not connected and ready for ACK',
        );
      } else {
        final waiter = Completer<void>();

        final previous = _ackWaiters[deliveryId];
        if (previous != null && !previous.isCompleted) {
          previous.completeError(
            StateError('Relay ACK waiter replaced'),
          );
        }

        _ackWaiters[deliveryId] = waiter;

        try {
          channel.sink.add(
            '$_ackPrefix$deliveryId',
          );

          await waiter.future.timeout(
            const Duration(seconds: 2),
          );

          return;
        } catch (error) {
          lastError = error;

          if (identical(_ackWaiters[deliveryId], waiter)) {
            _ackWaiters.remove(deliveryId);
          }
        }
      }

      if (attempt < 2) {
        await Future<void>.delayed(
          const Duration(milliseconds: 200),
        );
      }
    }

    throw StateError(
      'Relay ACK confirmation timed out: '
      '$deliveryId ($lastError)',
    );
  }

  Future<void> disconnect() async {
    _manuallyDisconnected = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final authCompleter = _authCompleter;
    if (authCompleter != null && !authCompleter.isCompleted) {
      authCompleter.completeError(
        StateError('Relay manually disconnected before authentication'),
      );
    }

    _authCompleter = null;

    for (final waiter in _ackWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          StateError(
            'Relay manually disconnected before ACK confirmation',
          ),
        );
      }
    }

    _ackWaiters.clear();

    for (final waiter in _sendReceiptWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          StateError(
            'Relay manually disconnected before send receipt confirmation',
          ),
        );
      }
    }

    _sendReceiptWaiters.clear();

    final channel = _channel;
    _channel = null;
    _ready = false;

    await channel?.sink.close(
      ws_status.normalClosure,
    );
  }
}
