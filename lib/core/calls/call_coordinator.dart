import 'dart:async';

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

  final StreamController<CallSession?> _sessionController =
      StreamController<CallSession?>.broadcast();

  Stream<CallSession?> get sessionStream => _sessionController.stream;

  CallSession? get activeSession => _activeSession;
  CallSignal? get lastSignal => _lastSignal;

  void start() {
    _subscription ??= _signalRouter.incoming.listen(_handleSignal);
    _platformSubscription ??=
        _platformBridge.actions.listen(_handlePlatformAction);
  }

  void _handleSignal(CallSignal signal) {
    final session = signal.session;

    if (signal.type == 'offer') {
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
        if (_activeSession?.callId == session.callId) {
          _activeSession = _activeSession?.copyWith(
            state: CallState.ended,
          );

          _sessionController.add(_activeSession);

          _activeSession = null;
          _lastSignal = null;
          _sessionController.add(null);
        }
      });

      return;
    }

    if (_activeSession?.callId != session.callId) {
      return;
    }

    _lastSignal = signal;

    switch (signal.type) {
      case 'answer':
      case 'ice-candidate':
        _activeSession = _activeSession?.copyWith(
          state: CallState.connecting,
        );
        _sessionController.add(_activeSession);
        break;

      case 'reject':
      case 'end':
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

  CallSignal? accept() {
    final signal = _lastSignal;

    if (_activeSession == null || signal == null) {
      return null;
    }

    _ringTimeout?.cancel();

    _activeSession = _activeSession?.copyWith(
      state: CallState.connecting,
    );
    _sessionController.add(_activeSession);

    return signal;
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
    unawaited(_callService.end());

    _activeSession = null;
    _lastSignal = null;
    _sessionController.add(null);
  }

  Future<void> dispose() async {
    _ringTimeout?.cancel();

    await _subscription?.cancel();
    await _platformSubscription?.cancel();
    await _sessionController.close();

    _subscription = null;
    _platformSubscription = null;
    _ringTimeout = null;
  }
}
