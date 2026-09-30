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
  });

  final Uint8List bytes;

  /// Non-null only for a queued relay delivery.
  final int? deliveryId;
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

  final List<int> _pendingDeliveryIds = <int>[];

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
      _pendingDeliveryIds.clear();

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

            final deliveryId =
                _pendingDeliveryIds.isEmpty
                    ? null
                    : _pendingDeliveryIds.removeAt(0);

            (_incomingController ??=
                    StreamController<Uint8List>.broadcast())
                .add(bytes);

            (_incomingDeliveryController ??=
                    StreamController<RelayDelivery>.broadcast())
                .add(
              RelayDelivery(
                bytes: bytes,
                deliveryId: deliveryId,
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
                _pendingDeliveryIds.add(deliveryId);
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
