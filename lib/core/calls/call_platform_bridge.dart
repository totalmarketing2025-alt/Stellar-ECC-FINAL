import 'dart:async';

import 'package:flutter/services.dart';

class CallPlatformAction {
  const CallPlatformAction({
    required this.action,
    required this.callId,
    required this.remoteNickname,
    required this.kind,
    this.chatId,
  });

  final String action;
  final String callId;
  final String remoteNickname;
  final String kind;
  final String? chatId;

  factory CallPlatformAction.fromMap(Map<dynamic, dynamic> map) {
    return CallPlatformAction(
      action: map['action'] as String? ?? '',
      callId: map['callId'] as String? ?? '',
      remoteNickname: map['remoteNickname'] as String? ?? '',
      kind: map['kind'] as String? ?? 'voice',
      chatId: map['chatId'] as String?,
    );
  }
}

class CallPlatformBridge {
  CallPlatformBridge() {
    _channel.setMethodCallHandler(_handleMethodCall);
    _loadPendingAction();
  }

  static const MethodChannel _channel = MethodChannel('ecc.stellar.app/calls');

  final StreamController<CallPlatformAction> _controller =
      StreamController<CallPlatformAction>.broadcast();

  Stream<CallPlatformAction> get actions => _controller.stream;

  Future<void> _loadPendingAction() async {
    try {
      final result = await _channel.invokeMethod<dynamic>(
        'getPendingCallAction',
      );

      if (result is Map) {
        final action = CallPlatformAction.fromMap(result);

        if (action.action.isNotEmpty &&
            action.callId.isNotEmpty &&
            action.remoteNickname.isNotEmpty &&
            !_controller.isClosed) {
          _controller.add(action);
        }
      }
    } catch (error) {
      print('CALL_PENDING_ACTION_LOAD_FAILED: $error');
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'incomingCallAction') {
      return;
    }

    final arguments = call.arguments;

    if (arguments is! Map) {
      return;
    }

    final action = CallPlatformAction.fromMap(arguments);

    if (action.action.isEmpty ||
        action.callId.isEmpty ||
        action.remoteNickname.isEmpty) {
      return;
    }

    if (!_controller.isClosed) {
      _controller.add(action);
    }
  }

  Future<bool> setCallActive(String callId) async {
    if (callId.isEmpty) {
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>(
        'setCallActive',
        <String, dynamic>{
          'callId': callId,
        },
      );

      return result == true;
    } catch (error) {
      print('CALL_SET_ACTIVE_FAILED: $error');
      return false;
    }
  }

  Future<bool> setCallEnded(String callId) async {
    if (callId.isEmpty) {
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>(
        'setCallEnded',
        <String, dynamic>{
          'callId': callId,
        },
      );

      return result == true;
    } catch (error) {
      print('CALL_SET_ENDED_FAILED: $error');
      return false;
    }
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
