import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

/// Client for the stateless relay described in Phase 4/9 — persistent
/// WebSocket, binary framing (protobuf-encoded Envelope, see
/// core/network/envelope.dart), exponential-backoff reconnect.
class RelayClient {
  RelayClient({required this.relayUrl});

  final String relayUrl;

  WebSocketChannel? _channel;
  StreamController<Uint8List>? _incomingController;
  bool _manuallyDisconnected = false;
  int _backoffMs = 500;
  static const _maxBackoffMs = 30000;
  String? _lastBearerToken;

  Stream<Uint8List> get incoming =>
      (_incomingController ??= StreamController<Uint8List>.broadcast()).stream;

  bool get isConnected => _channel != null;

  Future<void> connect(String bearerToken) async {
    _manuallyDisconnected = false;
    _lastBearerToken = bearerToken;
    final uri = Uri.parse('$relayUrl?token=$bearerToken');

    try {
      _channel = WebSocketChannel.connect(uri);
      _backoffMs = 500; // reset backoff on successful connect

      _channel!.stream.listen(
        (data) {
          if (data is List<int>) {
            (_incomingController ??= StreamController<Uint8List>.broadcast())
                .add(Uint8List.fromList(data));
          }
        },
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _handleDisconnect() {
    _channel = null;
    if (!_manuallyDisconnected) {
      // Bug fix: this previously left a comment explaining reconnect logic
      // without actually invoking it — no automatic reconnect ever
      // happened after a dropped connection. Now it does, using the last
      // bearer token supplied to connect().
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    final token = _lastBearerToken;
    if (token == null) return; // never connected yet — nothing to retry with
    Timer(Duration(milliseconds: _backoffMs), () {
      if (_manuallyDisconnected) return;
      _backoffMs = (_backoffMs * 2).clamp(500, _maxBackoffMs);
      connect(token);
    });
  }

  Future<void> send(Uint8List envelopeBytes) async {
    final channel = _channel;
    if (channel == null) {
      throw StateError('Not connected — caller should queue locally and retry on reconnect');
    }
    channel.sink.add(envelopeBytes);
  }

  Future<void> disconnect() async {
    _manuallyDisconnected = true;
    await _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
  }
}
