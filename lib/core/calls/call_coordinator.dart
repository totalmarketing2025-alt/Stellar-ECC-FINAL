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
        _callService = callService;

  final CallSignalRouter _signalRouter;
  final CallService _callService;

  StreamSubscription<CallSignal>? _subscription;
  Timer? _ringTimeout;

  CallSession? _activeSession;
  CallSignal? _lastSignal;
  CallPlatformAction? _pendingPlatformAction;
  final Set<String> _answeringCallIds = <String>{};
  final List<CallSignal> _pendingIncomingIceSignals = [];
  final Map<String, List<CallSignal>> _pendingPreOfferIceSignals = {};

  static const int _maxPendingPreOfferIceSignals = 128;

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
      // A failed older start must not tear down a newer call.
      if (_activeSession?.callId == callId) {
        try {
          await _callService.end();
        } catch (cleanupError) {
          print('CALL_OUTGOING_CLEANUP_FAILED: $cleanupError');
        }

        if (_activeSession?.callId == callId) {
          _activeSession = null;
          _lastSignal = null;
          _pendingPlatformAction = null;
          _pendingIncomingIceSignals.clear();
          _pendingPreOfferIceSignals.remove(callId);
          _sessionController.add(null);
        }
      }
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

    // Do not clear a replacement session created during cleanup.
    if (session == null) {
      if (_activeSession != null) return;
    } else if (_activeSession?.callId != session.callId) {
      return;
    }

    _activeSession = null;
    _lastSignal = null;
    _pendingPlatformAction = null;
    _pendingIncomingIceSignals.clear();
    if (session != null) {
      _pendingPreOfferIceSignals.remove(session.callId);
      _answeringCallIds.remove(session.callId);
    }
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

      _ringTimeout?.cancel();

      final preOfferIceSignals =
          _pendingPreOfferIceSignals.remove(session.callId) ?? const [];

      _pendingIncomingIceSignals
        ..clear()
        ..addAll(preOfferIceSignals);

      _activeSession = session.copyWith(
        state: CallState.ringing,
      );
      _lastSignal = signal;

      _sessionController.add(_activeSession);

      _ringTimeout = Timer(const Duration(seconds: 45), () {
        final currentSession = _activeSession;
        if (currentSession?.callId != session.callId ||
            currentSession?.state != CallState.ringing) {
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
        _pendingPreOfferIceSignals.remove(session.callId);
        _sessionController.add(null);
      });

      final pendingAction = _pendingPlatformAction;
      if (pendingAction != null &&
          pendingAction.callId == session.callId) {
        _pendingPlatformAction = null;
        unawaited(_handlePlatformAction(pendingAction));
      }

      return;
    }

    if (_activeSession?.callId != session.callId) {
      if (signal.type == 'ice-candidate') {
        final pending =
            _pendingPreOfferIceSignals.putIfAbsent(
          session.callId,
          () => <CallSignal>[],
        );

        if (pending.length < _maxPendingPreOfferIceSignals) {
          pending.add(signal);
        }

        return;
      }

      return;
    }

    // ICE candidates can arrive before the user answers an incoming call.
    // CallService has no peer connection until start(incoming) is called,
    // so keep these signals at coordinator level until the call is answered.
    // Do not overwrite _lastSignal here: it must remain the original offer
    // so the platform Answer action can still consume it.
    if (signal.type == 'ice-candidate' &&
        _activeSession?.state == CallState.ringing) {
      _pendingIncomingIceSignals.add(signal);
      return;
    }

    _lastSignal = signal;

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
        _pendingPreOfferIceSignals.remove(session.callId);
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
      // An old signal failure must not change a replacement call.
      if (_activeSession?.callId != session.callId) {
        print('CALL_SIGNAL_HANDLE_FAILED (stale call): $error');
        return;
      }

      _activeSession = _activeSession?.copyWith(
        state: CallState.failed,
      );
      _sessionController.add(_activeSession);

      try {
        await _callService.end();
      } catch (cleanupError) {
        print('CALL_SIGNAL_CLEANUP_FAILED: $cleanupError');
      }

      if (_activeSession?.callId == session.callId) {
        _activeSession = null;
        _lastSignal = null;
        _pendingPlatformAction = null;
        _pendingIncomingIceSignals.clear();
        _pendingPreOfferIceSignals.remove(session.callId);
        _sessionController.add(null);
      }

      print('CALL_SIGNAL_HANDLE_FAILED: $error');
    }
  }

  Future<void> handlePlatformAction(CallPlatformAction action) {
    return _handlePlatformAction(action);
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

    final expectedKind =
        session.kind == CallKind.video ? 'video' : 'voice';
    if (action.kind != expectedKind) {
      return;
    }

    final sessionRemoteNickname = session.remoteNickname;
    if (sessionRemoteNickname != null &&
        sessionRemoteNickname.isNotEmpty &&
        action.remoteNickname != sessionRemoteNickname) {
      return;
    }

    if (action.chatId != null &&
        action.chatId!.isNotEmpty &&
        action.chatId != session.chatId) {
      return;
    }

    final remoteNickname = sessionRemoteNickname ?? action.remoteNickname;
    if (remoteNickname.isEmpty) {
      return;
    }

    final chatId = session.chatId;

    switch (action.action) {
      case 'answer':
        // Only a ringing call may transition into the answer flow.
        // This also blocks duplicate Answer actions after connecting.
        if (session.state != CallState.ringing) {
          return;
        }

        final signal = _lastSignal;
        if (signal == null || signal.type != 'offer') {
          return;
        }

        // Native actions can be delivered more than once. Never start
        // the same incoming call concurrently.
        if (!_answeringCallIds.add(session.callId)) {
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
          // Do not clear a different call if the active session changed
          // while the asynchronous answer operation was running.
          if (_activeSession?.callId == session.callId) {
            _activeSession = _activeSession?.copyWith(
              state: CallState.failed,
            );
            _sessionController.add(_activeSession);

            try {
              await _callService.end();
            } catch (cleanupError) {
              print('CALL_ANSWER_CLEANUP_FAILED: $cleanupError');
            }

            if (_activeSession?.callId == session.callId) {
              _activeSession = null;
              _lastSignal = null;
              _pendingIncomingIceSignals.clear();
              _pendingPreOfferIceSignals.remove(session.callId);
              _pendingPlatformAction = null;
              _sessionController.add(null);
            }
          }

          print('CALL_ANSWER_FAILED: $error');
        } finally {
          _answeringCallIds.remove(session.callId);
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

          // Only clean up if the rejected call is still the active call.
          if (_activeSession?.callId == session.callId) {
            try {
              await _callService.end();
            } catch (cleanupError) {
              print('CALL_REJECT_CLEANUP_FAILED: $cleanupError');
            }
          }
        }

        if (_activeSession?.callId != session.callId) {
          break;
        }

        _ringTimeout?.cancel();

        _activeSession = _activeSession?.copyWith(
          state: CallState.ended,
        );
        _sessionController.add(_activeSession);

        if (_activeSession?.callId == session.callId) {
          _activeSession = null;
          _lastSignal = null;
          _pendingPlatformAction = null;
          _pendingIncomingIceSignals.clear();
          _pendingPreOfferIceSignals.remove(session.callId);
          _sessionController.add(null);
        }
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
    await _sessionController.close();

    _subscription = null;
    _ringTimeout = null;
  }
}
