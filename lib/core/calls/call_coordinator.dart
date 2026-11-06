import 'dart:async';
import 'dart:math';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../domain/models/call_session.dart';
import '../../domain/models/call_event.dart';
import 'call_platform_bridge.dart';
import 'call_service.dart';
import 'call_signal_router.dart';

class CallCoordinator {
  CallCoordinator({
    required CallSignalRouter signalRouter,
    required CallService callService,
    required CallPlatformBridge platformBridge,
    this.onCallHistoryEvent,
  })  : _signalRouter = signalRouter,
        _callService = callService;

  final CallSignalRouter _signalRouter;
  final CallService _callService;

  final Future<void> Function(CallEventPayload event)? onCallHistoryEvent;
  final Set<String> _historyStartedCallIds = <String>{};
  final Set<String> _historyTerminalCallIds = <String>{};
  final Set<String> _historyInFlightKeys = <String>{};
  final Map<String, Timer> _historyRetryTimers = <String, Timer>{};
  final Map<String, int> _historyRetryAttempts = <String, int>{};
  bool _disposed = false;

  StreamSubscription<CallSignal>? _subscription;
  Timer? _ringTimeout;
  Timer? _disconnectGraceTimeout;
  Timer? _outgoingRingTimeout;

  CallSession? _activeSession;
  CallSignal? _lastSignal;
  CallPlatformAction? _pendingPlatformAction;
  final Set<String> _answeringCallIds = <String>{};
  final List<CallSignal> _pendingIncomingIceSignals = [];
  final Map<String, List<CallSignal>> _pendingPreOfferIceSignals = {};

  static const int _maxPendingPreOfferIceSignals = 128;
  static const Duration _disconnectGraceDuration = Duration(seconds: 15);
  static const Duration _callStartTimeout = Duration(seconds: 30);
  static const Duration _outgoingRingDuration = Duration(seconds: 45);

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
        // Ignore late connection events after this call has ended or failed.
        if (session.state == CallState.failed ||
            session.state == CallState.ended) {
          break;
        }
        _disconnectGraceTimeout?.cancel();
        _disconnectGraceTimeout = null;
        _outgoingRingTimeout?.cancel();
        _outgoingRingTimeout = null;
        _activeSession = session.copyWith(
          state: CallState.connected,
          connectedAt: session.connectedAt ?? DateTime.now(),
        );
        _sessionController.add(_activeSession);
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Allow transient network interruptions to recover for 15 seconds.
        if (session.state == CallState.connected ||
            session.state == CallState.connecting) {
          if (session.state == CallState.connected) {
            _activeSession = session.copyWith(state: CallState.connecting);
            _sessionController.add(_activeSession);
          }

          // Start the grace period only once. Repeated disconnected
          // events must not keep extending the timeout indefinitely.
          if (_disconnectGraceTimeout == null) {
            final disconnectedCallId = session.callId;
            _disconnectGraceTimeout = Timer(_disconnectGraceDuration, () {
              unawaited(_expireDisconnectedCall(disconnectedCallId));
            });
          }
        }
        break;

      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _disconnectGraceTimeout?.cancel();
        _disconnectGraceTimeout = null;
        _publishHistory(session, phase: 'ended', outcome: 'failed');
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
        _disconnectGraceTimeout?.cancel();
        _disconnectGraceTimeout = null;
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

  Future<void> _expireDisconnectedCall(String callId) async {
    final session = _activeSession;

    if (session == null ||
        session.callId != callId ||
        session.state != CallState.connecting) {
      return;
    }

    _disconnectGraceTimeout = null;
    print('CALL_DISCONNECTED_TIMEOUT: callId=$callId');

    _publishHistory(session, phase: 'ended', outcome: 'failed');
    _activeSession = session.copyWith(state: CallState.failed);
    _sessionController.add(_activeSession);

    try {
      final remote = session.remoteNickname;
      if (remote != null && remote.isNotEmpty) {
        await _callService.endForRemote(remote);
      } else {
        await _callService.end();
      }
    } catch (error) {
      print('CALL_DISCONNECTED_CLEANUP_FAILED: $error');
    }

    // A delayed cleanup must never clear a replacement call.
    if (_activeSession?.callId != callId) return;

    _activeSession = null;
    _lastSignal = null;
    _pendingPlatformAction = null;
    _pendingIncomingIceSignals.clear();
    _pendingPreOfferIceSignals.remove(callId);
    _sessionController.add(null);
  }

  Future<void> startOutgoing({
    required String remoteNickname,
    required String chatId,
    required bool video,
  }) async {
    _ringTimeout?.cancel();
    _disconnectGraceTimeout?.cancel();
    _disconnectGraceTimeout = null;
    _outgoingRingTimeout?.cancel();
    _outgoingRingTimeout = null;

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
    _publishHistory(_activeSession!, phase: 'started');

    try {
      await _callService.start(
        remoteNickname: remoteNickname,
        direction: CallDirection.outgoing,
        video: video,
        callId: callId,
        chatId: chatId,
      ).timeout(_callStartTimeout);

      if (_activeSession?.callId == callId &&
          _activeSession?.state == CallState.ringing) {
        _outgoingRingTimeout?.cancel();
        _outgoingRingTimeout = Timer(_outgoingRingDuration, () {
          unawaited(_expireOutgoingCall(callId));
        });
      }
    } catch (_) {
      // A failed older start must not tear down a newer call.
      if (_activeSession?.callId == callId) {
        _outgoingRingTimeout?.cancel();
        _outgoingRingTimeout = null;
        _publishHistory(
          _activeSession!,
          phase: 'ended',
          outcome: 'failed',
        );
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

  Future<void> _expireOutgoingCall(String callId) async {
    final session = _activeSession;

    if (session == null ||
        session.callId != callId ||
        session.state != CallState.ringing) {
      return;
    }

    _outgoingRingTimeout = null;

    print('CALL_OUTGOING_NO_ANSWER: callId=$callId');

    _publishHistory(
      session,
      phase: 'ended',
      outcome: 'no_answer',
    );

    _activeSession = session.copyWith(state: CallState.ended);
    _sessionController.add(_activeSession);

    try {
      final remote = session.remoteNickname;
      if (remote != null && remote.isNotEmpty) {
        await _callService
            .endForRemote(remote)
            .timeout(const Duration(seconds: 3));
      } else {
        await _callService.end();
      }
    } catch (error) {
      print('CALL_OUTGOING_TIMEOUT_CLEANUP: $error');
      await _callService.end();
    }

    if (_activeSession?.callId != callId) return;

    _activeSession = null;
    _lastSignal = null;
    _pendingPlatformAction = null;
    _pendingIncomingIceSignals.clear();
    _pendingPreOfferIceSignals.remove(callId);
    _sessionController.add(null);
  }

  String _generateCallId() {
    final random = Random.secure();

    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  void _publishHistory(
    CallSession session, {
    required String phase,
    String? outcome,
  }) {
    final callback = onCallHistoryEvent;
    if (callback == null || _disposed) return;

    final terminal = phase == 'ended';
    final seen = terminal
        ? _historyTerminalCallIds
        : _historyStartedCallIds;

    final eventKey = '$phase:${session.callId}';

    if (seen.contains(session.callId) ||
        !_historyInFlightKeys.add(eventKey)) {
      return;
    }

    int? durationSeconds;
    if (terminal && session.connectedAt != null) {
      durationSeconds = DateTime.now()
          .difference(session.connectedAt!)
          .inSeconds
          .clamp(0, 604800)
          .toInt();
    }

    final event = CallEventPayload(
      callId: session.callId,
      chatId: session.chatId,
      phase: phase,
      kind: session.kind == CallKind.video ? 'video' : 'voice',
      outcome: outcome,
      durationSeconds: durationSeconds,
    );

    unawaited(
      _attemptHistoryDelivery(
        event: event,
        eventKey: eventKey,
        callId: session.callId,
        seen: seen,
        callback: callback,
      ),
    );
  }

  Future<void> _attemptHistoryDelivery({
    required CallEventPayload event,
    required String eventKey,
    required String callId,
    required Set<String> seen,
    required Future<void> Function(CallEventPayload event) callback,
  }) async {
    if (_disposed) {
      _historyInFlightKeys.remove(eventKey);
      return;
    }

    try {
      await callback(event);

      // Mark the event as handled only after local persistence succeeds.
      seen.add(callId);
      while (seen.length > 256) {
        seen.remove(seen.first);
      }

      _historyRetryTimers.remove(eventKey)?.cancel();
      _historyRetryAttempts.remove(eventKey);
      _historyInFlightKeys.remove(eventKey);

      print('CALL_HISTORY_EVENT_PERSISTED: $eventKey');
    } catch (error, stackTrace) {
      if (_disposed) {
        _historyInFlightKeys.remove(eventKey);
        return;
      }

      final attempt =
          (_historyRetryAttempts[eventKey] ?? 0) + 1;
      _historyRetryAttempts[eventKey] = attempt;

      final exponent = (attempt - 1).clamp(0, 6).toInt();
      final delaySeconds = min(300, 5 * (1 << exponent));

      print(
        'CALL_HISTORY_EVENT_RETRY: '
        'event=$eventKey attempt=$attempt '
        'retryIn=${delaySeconds}s error=$error',
      );
      print('CALL_HISTORY_EVENT_RETRY_STACK: $stackTrace');

      _historyRetryTimers[eventKey]?.cancel();
      _historyRetryTimers[eventKey] = Timer(
        Duration(seconds: delaySeconds),
        () {
          _historyRetryTimers.remove(eventKey);
          unawaited(
            _attemptHistoryDelivery(
              event: event,
              eventKey: eventKey,
              callId: callId,
              seen: seen,
              callback: callback,
            ),
          );
        },
      );
    }
  }

  Future<void> endActiveCall() async {
    _ringTimeout?.cancel();
    _disconnectGraceTimeout?.cancel();
    _disconnectGraceTimeout = null;
    _outgoingRingTimeout?.cancel();
    _outgoingRingTimeout = null;

    final session = _activeSession;
    if (session != null) {
      _publishHistory(
        session,
        phase: 'ended',
        outcome: session.connectedAt != null ? 'completed' : 'cancelled',
      );
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

  Future<void> answerIncomingCall() async {
    final session = _activeSession;
    final signal = _lastSignal;
    if (session == null ||
        session.state != CallState.ringing ||
        signal == null ||
        signal.type != 'offer') {
      return;
    }

    final remoteNickname = session.remoteNickname;
    if (remoteNickname == null || remoteNickname.isEmpty) {
      return;
    }

    await handlePlatformAction(
      CallPlatformAction(
        action: 'answer',
        callId: session.callId,
        remoteNickname: remoteNickname,
        kind: session.kind == CallKind.video ? 'video' : 'voice',
        chatId: session.chatId,
      ),
    );
  }

  Future<void> rejectIncomingCall() async {
    final session = _activeSession;
    final signal = _lastSignal;
    if (session == null ||
        session.state != CallState.ringing ||
        signal == null ||
        signal.type != 'offer') {
      return;
    }

    final remoteNickname = session.remoteNickname;
    if (remoteNickname == null || remoteNickname.isEmpty) {
      return;
    }

    await handlePlatformAction(
      CallPlatformAction(
        action: 'reject',
        callId: session.callId,
        remoteNickname: remoteNickname,
        kind: session.kind == CallKind.video ? 'video' : 'voice',
        chatId: session.chatId,
      ),
    );
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
      _disconnectGraceTimeout?.cancel();
      _disconnectGraceTimeout = null;

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

        _publishHistory(
          session,
          phase: 'ended',
          outcome: 'no_answer',
        );

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
        _outgoingRingTimeout?.cancel();
        _outgoingRingTimeout = null;
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
        _disconnectGraceTimeout?.cancel();
        _disconnectGraceTimeout = null;
        _outgoingRingTimeout?.cancel();
        _outgoingRingTimeout = null;
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

      _publishHistory(session, phase: 'ended', outcome: 'failed');
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
          ).timeout(_callStartTimeout);

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
            _publishHistory(
              session,
              phase: 'ended',
              outcome: 'failed',
            );
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
        // Close the local call UI immediately. Relay signaling continues
        // independently and cannot block navigation back to the chat.
        unawaited(
          _callService.reject(
            remoteNickname,
            callId: action.callId,
            chatId: session.chatId,
            kind: action.kind == 'video'
                ? CallKind.video
                : CallKind.voice,
          ).catchError((Object error) {
            print('CALL_REJECT_FAILED: $error');
          }),
        );

        _publishHistory(
          session,
          phase: 'ended',
          outcome: 'declined',
        );

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
        _publishHistory(
          session,
          phase: 'ended',
          outcome: session.connectedAt != null ? 'completed' : 'cancelled',
        );
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
    _disconnectGraceTimeout?.cancel();
    _disconnectGraceTimeout = null;
    _outgoingRingTimeout?.cancel();
    _outgoingRingTimeout = null;

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
    _disposed = true;
    _ringTimeout?.cancel();
    _disconnectGraceTimeout?.cancel();
    _disconnectGraceTimeout = null;
    _outgoingRingTimeout?.cancel();
    _outgoingRingTimeout = null;

    for (final timer in _historyRetryTimers.values) {
      timer.cancel();
    }
    _historyRetryTimers.clear();
    _historyRetryAttempts.clear();
    _historyInFlightKeys.clear();

    _callService.onConnectionStateChanged = null;

    await _subscription?.cancel();
    await _sessionController.close();

    _subscription = null;
    _ringTimeout = null;
  }
}
