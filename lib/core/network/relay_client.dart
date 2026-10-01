import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'directory_client.dart';
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

  final List<_PendingRelayDelivery> _pendingDeliveries =
      <_PendingRelayDelivery>[];

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

  String? _lastPeer;

  Stream<Uint8List> get incoming =>
      (_incomingController ??=
              StreamController<Uint8List>.broadcast())
          .stream;

  Stream<RelayDelivery> get incomingDelivery =>
      (_incomingDeliveryController ??=
              StreamController<RelayDelivery>.broadcast())
          .stream;

  bool get isConnected => _channel != null && _ready == true;
  bool? _ready;
  Timer? _reconnectTimer;
  Future<void>? _connectFuture;
  Completer<void>? _authCompleter;
  final Map<int, Completer<void>> _ackWaiters =
      <int, Completer<void>>{};

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

            _PendingRelayDelivery? chunkedPending;

            for (final pending in _pendingDeliveries) {
              if (pending.isChunked &&
                  pending.nextChunkIndex <
                      (pending.chunkCount ?? 0)) {
                chunkedPending = pending;
                break;
              }
            }

            if (chunkedPending != null) {
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

                (_incomingDeliveryController ??=
                        StreamController<RelayDelivery>.broadcast())
                    .add(
                  RelayDelivery(
                    bytes: reassembled,
                    deliveryId: chunkedPending.deliveryId,
                    senderNickname: chunkedPending.senderNickname,
                  ),
                );
              }

              return;
            }

            final pending =
                _pendingDeliveries.isEmpty
                    ? null
                    : _pendingDeliveries.removeAt(0);

            (_incomingController ??=
                    StreamController<Uint8List>.broadcast())
                .add(bytes);

            (_incomingDeliveryController ??=
                    StreamController<RelayDelivery>.broadcast())
                .add(
              RelayDelivery(
                bytes: bytes,
                deliveryId: pending?.deliveryId,
                senderNickname: pending?.senderNickname,
              ),
            );
          } else if (data is String) {
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

    _channel = null;
    _ready = false;

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

  Future<void> send(Uint8List envelopeBytes) async {
    final channel = _channel;

    if (channel == null || _ready != true) {
      throw StateError(
        'Relay is not connected and ready',
      );
    }

    channel.sink.add(envelopeBytes);
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

    final channel = _channel;
    _channel = null;
    _ready = false;

    await channel?.sink.close(
      ws_status.normalClosure,
    );
  }
}
