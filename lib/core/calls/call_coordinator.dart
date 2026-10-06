import 'dart:async';
import 'dart:math';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../domain/models/call_session.dart';
import 'call_platform_bridge.dart';
import 'call_service.dart';
import 'call_signal_router.dart';

class CallCoordinator {
  CallCoordinator({
    required CallSignalRouter signalRouter,
    required CallService callService,
    required CallPlatformBridge platformBridge,
  })  : _signalRouter = signalRouter,
        _callService = callService,
        _platformBridge = platformBridge;

  final CallSignalRouter _signalRouter;
  final CallService _callService;
  final CallPlatformBridge _platformBridge;

  StreamSubscription<CallSignal>? _subscription;
  StreamSubscription<CallPlatformAction>? _platformSubscription;
  Timer? _ringTimeout;

  CallSession? _activeSession;
  CallSignal? _lastSignal;
  CallPlatformAction? _pendingPlatformAction;
  final List<CallSignal> _pendingIncomingIceSignals = [];

  final StreamController<CallSession?> _sessionController =
      StreamController<CallSession?>.broadcast();

  Stream<CallSession?> get sessionStream => _sessionController.stream;

  CallSession? get activeSession => _activeSession;
  CallSignal? get lastSignal => _lastSignal;

  void attachRenderers({
    RTCVideoRenderer? local,
    RTCVideoRenderer? remote,
  }) {
    _callService.attachRenderers(
      local: local,
      remote: remote,
    );
    _callService.onConnectionStateChanged = _handleConnectionState;
  }

  void _handleConnectionState(RTCPeerConnectionState state) {
    final session = _activeSession;
    if (session == null) {
      return;
    }

    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _activeSession = session.copyWith(
          state: CallState.connected,
          connectedAt: session.connectedAt ?? DateTime.now(),
        );
        _sessionController.add(_activeSession);
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // WebRTC disconnected can be transient. Keep the session alive
        // so a later Connected state can recover the active call.
        if (session.state == CallState.connected) {
          _activeSession = session.copyWith(
            state: CallState.connecting,
          );
          _sessionController.add(_activeSession);
        }
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _activeSession = session.copyWith(
          state: CallState.failed,
        );
        _sessionController.add(_activeSession);

        final remoteNickname = session.remoteNickname;
        if (remoteNickname != null && remoteNickname.isNotEmpty) {
          unawaited(_callService.endForRemote(remoteNickname));
        } else {
          unawaited(_callService.end());
        }

        _activeSession = null;
        _lastSignal = null;
        _pendingPlatformAction = null;
        _pendingIncomingIceSignals.clear();
        _sessionController.add(null);
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        // The peer connection is already closed here. Do not call
        // CallService.end() again because that would duplicate cleanup.
        if (session.state != CallState.failed &&
            session.state != CallState.ended) {
          _activeSession = session.copyWith(
            state: CallState.ended,
          );
          _sessionController.add(_activeSession);
        }

        _activeSession = null;
        _lastSignal = null;
        _pendingPlatformAction = null;
        _pendingIncomingIceSignals.clear();
        _sessionController.add(null);
        break;

      default:
        break;
    }
  }

  Future<void> startOutgoing({
    required String remoteNickname,
    required String chatId,
    required bool video,
  }) async {
    _ringTimeout?.cancel();

    if (_activeSession != null) {
      throw StateError('Another call is already active');
    }

    final callId = _generateCallId();

    _activeSession = CallSession(
      callId: callId,
      chatId: chatId,
      kind: video ? CallKind.video : CallKind.voice,
      state: CallState.ringing,
      remoteNickname: remoteNickname,
    );

    _lastSignal = null;
    _sessionController.add(_activeSession);

    try {
      await _callService.start(
        remoteNickname: remoteNickname,
        direction: CallDirection.outgoing,
        video: video,
        callId: callId,
        chatId: chatId,
      );
    } catch (_) {
      await _callService.end();
      _activeSession = null;
      _lastSignal = null;
      _sessionController.add(null);
      rethrow;
    }
  }

  String _generateCallId() {
    final random = Random.secure();

    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> endActiveCall() async {
    _ringTimeout?.cancel();

    final session = _activeSession;
    if (session != null) {
      _activeSession = session.copyWith(
        state: CallState.ended,
      );
      _sessionController.add(_activeSession);
    }

    final remoteNickname = session?.remoteNickname;

    if (remoteNickname != null && remoteNickname.isNotEmpty) {
      await _callService.endForRemote(remoteNickname);
    } else {
      await _callService.end();
    }

    _activeSession = null;
    _lastSignal = null;
    _pendingPlatformAction = null;
    _sessionController.add(null);
  }

  Future<void> toggleMute(bool muted) {
    return _callService.toggleMute(muted);
  }

  Future<void> toggleCamera(bool cameraOff) {
    return _callService.toggleCamera(cameraOff);
  }

  Future<void> switchCamera() {
    return _callService.switchCamera();
  }

  Future<void> setSpeakerphone(bool enabled) {
    return _callService.setSpeakerphone(enabled);
  }

  void start() {
    _subscription ??= _signalRouter.incoming.listen(_handleSignal);
    _platformSubscription ??=
        _platformBridge.actions.listen(_handlePlatformAction);
  }

  void _handleSignal(CallSignal signal) {
    final session = signal.session;

    if (signal.type == 'offer') {
      final activeSession = _activeSession;

      // Never let a new offer overwrite an already active call.
      // A valid incoming offer is accepted only when there is no
      // active session yet.
      if (activeSession != null) {
        return;
      }

      _pendingIncomingIceSignals.clear();
      _ringTimeout?.cancel();

      _activeSession = session.copyWith(
        state: CallState.ringing,
      );
      _lastSignal = signal;

      _sessionController.add(_activeSession);

      final pendingAction = _pendingPlatformAction;
      if (pendingAction != null &&
          pendingAction.callId == session.callId) {
        _pendingPlatformAction = null;
        unawaited(_handlePlatformAction(pendingAction));
      }

      _ringTimeout = Timer(const Duration(seconds: 45), () {
        if (_activeSession?.callId != session.callId) {
          return;
        }

        final remoteNickname = _activeSession?.remoteNickname;

        if (remoteNickname != null && remoteNickname.isNotEmpty) {
          unawaited(
            _callService.reject(
              remoteNickname,
              callId: session.callId,
              chatId: session.chatId,
              kind: session.kind,
            ),
          );
        } else {
          unawaited(_callService.end());
        }

        _activeSession = _activeSession?.copyWith(
          state: CallState.ended,
        );

        _sessionController.add(_activeSession);

        _activeSession = null;
        _lastSignal = null;
        _pendingPlatformAction = null;
        _sessionController.add(null);
      });

      return;
    }

    if (_activeSession?.callId != session.callId) {
      return;
    }

    _lastSignal = signal;

    // ICE candidates can arrive before the user answers an incoming call.
    // CallService has no peer connection until start(incoming) is called,
    // so keep these signals at coordinator level until the call is answered.
    if (signal.type == 'ice-candidate' &&
        _activeSession?.state == CallState.ringing) {
      _pendingIncomingIceSignals.add(signal);
      return;
    }

    switch (signal.type) {
      case 'answer':
        _activeSession = _activeSession?.copyWith(
          state: CallState.connecting,
        );
        _sessionController.add(_activeSession);
        break;

      case 'ice-candidate':
        // Keep outgoing UI in Ringing until the remote peer answers.
        break;

      case 'reject':
      case 'end':
        _pendingIncomingIceSignals.clear();
        _ringTimeout?.cancel();

        _activeSession = _activeSession?.copyWith(
          state: CallState.ended,
        );
        _sessionController.add(_activeSession);

        unawaited(_callService.end());

        _activeSession = null;
        _lastSignal = null;
        _sessionController.add(null);
        break;
    }

    _handleServiceSignal(signal);
  }

  Future<void> _handleServiceSignal(CallSignal signal) async {
    final session = _activeSession;
    if (session == null || session.callId != signal.session.callId) {
      return;
    }

    final remoteNickname = session.remoteNickname;
    if (remoteNickname == null || remoteNickname.isEmpty) {
      return;
    }

    try {
      await _callService.handleSignal(
        remoteNickname: remoteNickname,
        signal: signal.payload,
      );
    } catch (error) {
      _activeSession = _activeSession?.copyWith(
        state: CallState.failed,
      );
      _sessionController.add(_activeSession);

      await _callService.end();

      _activeSession = null;
      _lastSignal = null;
      _sessionController.add(null);

      print('CALL_SIGNAL_HANDLE_FAILED: $error');
    }
  }

  Future<void> _handlePlatformAction(CallPlatformAction action) async {
    final session = _activeSession;

    if (session == null) {
      _pendingPlatformAction = action;
      return;
    }

    if (session.callId != action.callId) {
      return;
    }

    final remoteNickname = session.remoteNickname ?? action.remoteNickname;
    if (remoteNickname.isEmpty) {
      return;
    }

    final chatId = session.chatId;

    switch (action.action) {
      case 'answer':
        final signal = _lastSignal;
        if (signal == null || signal.type != 'offer') {
          return;
        }

        _ringTimeout?.cancel();

        try {
          await _callService.start(
            remoteNickname: remoteNickname,
            direction: CallDirection.incoming,
            video: action.kind == 'video',
            callId: session.callId,
            chatId: chatId,
          );

          _activeSession = _activeSession?.copyWith(
            state: CallState.connecting,
          );
          _sessionController.add(_activeSession);

          await _callService.handleSignal(
            remoteNickname: remoteNickname,
            signal: signal.payload,
          );

          final pendingIceSignals =
              List<CallSignal>.from(_pendingIncomingIceSignals);
          _pendingIncomingIceSignals.clear();

          for (final pendingSignal in pendingIceSignals) {
            await _callService.handleSignal(
              remoteNickname: remoteNickname,
              signal: pendingSignal.payload,
            );
          }
        } catch (error) {
          _activeSession = _activeSession?.copyWith(
            state: CallState.failed,
          );
          _sessionController.add(_activeSession);

          await _callService.end();

          _activeSession = null;
          _lastSignal = null;
          _sessionController.add(null);

          print('CALL_ANSWER_FAILED: $error');
        }
        break;

      case 'reject':
        try {
          await _callService.reject(
            remoteNickname,
            callId: action.callId,
            chatId: session.chatId,
            kind: action.kind == 'video'
                ? CallKind.video
                : CallKind.voice,
          );
        } catch (error) {
          print('CALL_REJECT_FAILED: $error');
          await _callService.end();
        }

        _ringTimeout?.cancel();

        _activeSession = _activeSession?.copyWith(
          state: CallState.ended,
        );
        _sessionController.add(_activeSession);

        _activeSession = null;
        _lastSignal = null;
        _sessionController.add(null);
        break;

      case 'end':
        _ringTimeout?.cancel();
        unawaited(_callService.end());

        _activeSession = _activeSession?.copyWith(
          state: CallState.ended,
        );
        _sessionController.add(_activeSession);

        _activeSession = null;
        _lastSignal = null;
        _pendingPlatformAction = null;
        _sessionController.add(null);
        break;
    }
  }

  void rejectLocally() {
    _ringTimeout?.cancel();

    final session = _activeSession;
    final remoteNickname = session?.remoteNickname;

    if (remoteNickname != null && remoteNickname.isNotEmpty) {
      unawaited(_callService.reject(remoteNickname));
    } else {
      unawaited(_callService.end());
    }

    if (_activeSession != null) {
      _activeSession = _activeSession?.copyWith(
        state: CallState.ended,
      );
      _sessionController.add(_activeSession);
    }

    _activeSession = null;
    _lastSignal = null;
    _pendingPlatformAction = null;
    _sessionController.add(null);
  }

  void clear() {
    _ringTimeout?.cancel();

    final remoteNickname = _activeSession?.remoteNickname;
    if (remoteNickname != null && remoteNickname.isNotEmpty) {
      unawaited(_callService.endForRemote(remoteNickname));
    } else {
      unawaited(_callService.end());
    }

    _activeSession = null;
    _lastSignal = null;
    _pendingPlatformAction = null;
    _sessionController.add(null);
  }

  Future<void> dispose() async {
    _ringTimeout?.cancel();
    _callService.onConnectionStateChanged = null;

    await _subscription?.cancel();
    await _platformSubscription?.cancel();
    await _sessionController.close();

    _subscription = null;
    _platformSubscription = null;
    _ringTimeout = null;
  }
}
