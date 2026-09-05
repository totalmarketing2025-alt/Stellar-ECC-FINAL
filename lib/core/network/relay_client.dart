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

  bool get isConnected => _channel != null;

  Future<void> connect({
    required String peer,
  }) async {
    _manuallyDisconnected = false;
    _lastPeer = peer;

    final base = Uri.parse(relayUrl);

    final uri = base.replace(
      queryParameters: {
        ...base.queryParameters,
        'peer': peer,
      },
    );

    try {
      final channel = WebSocketChannel.connect(uri);

      _channel = channel;
      _backoffMs = 500;

      channel.stream.listen(
        (data) {
          if (data is List<int>) {
            (_incomingController ??=
                    StreamController<Uint8List>.broadcast())
                .add(
              Uint8List.fromList(data),
            );
          } else if (data is String) {
            (_incomingController ??=
                    StreamController<Uint8List>.broadcast())
                .add(
              Uint8List.fromList(
                data.codeUnits,
              ),
            );
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
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    final peer = _lastPeer;

    if (peer == null) {
      return;
    }

    Timer(
      Duration(milliseconds: _backoffMs),
      () {
        if (_manuallyDisconnected) {
          return;
        }

        _backoffMs =
            (_backoffMs * 2).clamp(
          500,
          _maxBackoffMs,
        );

        connect(peer: peer);
      },
    );
  }

  Future<void> send(Uint8List envelopeBytes) async {
    final channel = _channel;

    if (channel == null) {
      throw StateError(
        'Relay is not connected',
      );
    }

    channel.sink.add(envelopeBytes);
  }

  Future<void> disconnect() async {
    _manuallyDisconnected = true;

    await _channel?.sink.close(
      ws_status.normalClosure,
    );

    _channel = null;
  }
}
