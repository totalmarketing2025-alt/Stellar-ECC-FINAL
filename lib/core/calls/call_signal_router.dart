import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/models/call_session.dart';

class CallSignalRouter {
  final StreamController<CallSignal> _controller =
      StreamController<CallSignal>.broadcast();

  Stream<CallSignal> get incoming => _controller.stream;

  void dispatch({
    required CallSession session,
    required String type,
    required Map<String, dynamic> payload,
  }) {
    if (_controller.isClosed) {
      return;
    }

    _controller.add(CallSignal(session: session, type: type, payload: payload));
  }

  void dispatchPlaintext({
    required CallSession session,
    required Uint8List plaintextBytes,
  }) {
    final text = utf8.decode(plaintextBytes, allowMalformed: false);

    const prefix = 'STELLAR_CALL_V1:';
    if (!text.startsWith(prefix)) {
      throw StateError('Invalid Stellar call signal prefix');
    }

    final decoded = jsonDecode(text.substring(prefix.length));
    if (decoded is! Map) {
      throw StateError('Invalid Stellar call signal payload');
    }

    final type = decoded['type'];
    if (type is! String || type.isEmpty) {
      throw StateError('Missing Stellar call signal type');
    }

    final payload = <String, dynamic>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };

    dispatch(session: session, type: type, payload: payload);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

class CallSignal {
  const CallSignal({
    required this.session,
    required this.type,
    required this.payload,
  });

  final CallSession session;
  final String type;
  final Map<String, dynamic> payload;
}
