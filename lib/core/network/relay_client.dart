import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

/// WebSocket client for the Stellar relay.
///
/// The relay only transports opaque bytes. Signal encryption/decryption
/// happens before/after transport and is never performed by this client.
class RelayClient {
  RelayClient({
    required this.relayUrl,
  });

  final String relayUrl;

  WebSocketChannel? _channel;
  StreamController<Uint8List>? _incomingController;

  bool _manuallyDisconnected = false;
  int _backoffMs = 500;

  static const _maxBackoffMs = 30000;

  String? _lastPeer;

  Stream<Uint8List> get incoming =>
      (_incomingController ??=
              StreamController<Uint8List>.broadcast())
          .stream;

  bool get isConnected => _channel != null && _ready == true;
  bool? _ready;
  Timer? _reconnectTimer;
  Future<void>? _connectFuture;

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
      channel = WebSocketChannel.connect(uri);

      _channel = channel;
      _ready = false;

      print('RELAY_DEBUG: BEFORE_READY peer=$peer');
      await channel.ready;
      print('RELAY_DEBUG: AFTER_READY peer=$peer');

      if (!identical(_channel, channel) || _manuallyDisconnected) {
        await channel.sink.close(ws_status.normalClosure);
        return;
      }

      _ready = true;
      _backoffMs = 500;

      channel.stream.listen(
        (data) {
          if (!identical(_channel, channel)) {
            return;
          }

          if (data is List<int>) {
            (_incomingController ??=
                    StreamController<Uint8List>.broadcast())
                .add(Uint8List.fromList(data));
          } else if (data is String) {
            (_incomingController ??=
                    StreamController<Uint8List>.broadcast())
                .add(Uint8List.fromList(data.codeUnits));
          }
        },
        onDone: () {
          if (identical(_channel, channel)) {
            _handleDisconnect();
          }
        },
        onError: (_) {
          if (identical(_channel, channel)) {
            _handleDisconnect();
          }
        },
        cancelOnError: true,
      );
    } catch (_) {
      if (identical(_channel, channel)) {
        _channel = null;
        _ready = false;
      }
      _scheduleReconnect();
      rethrow;
    }
  }

  void _handleDisconnect() {
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

  Future<void> disconnect() async {
    _manuallyDisconnected = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final channel = _channel;
    _channel = null;
    _ready = false;

    await channel?.sink.close(
      ws_status.normalClosure,
    );
  }
}
