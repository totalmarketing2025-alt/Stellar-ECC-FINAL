import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../core/calls/call_coordinator.dart';
import '../../../domain/models/call_session.dart';
import '../../state/app_providers.dart';
import '../../widgets/call_control_dock.dart';

class VideoCallScreen extends ConsumerStatefulWidget {
  const VideoCallScreen({
    super.key,
    required this.chatId,
    this.incoming = false,
  });
  final String chatId;
  final bool incoming;

  @override
  ConsumerState<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends ConsumerState<VideoCallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  CallCoordinator? _callCoordinator;
  bool _muted = false;
  bool _speakerOn = true;
  bool _cameraOff = false;
  bool _frontCamera = true;
  Offset _pipOffset = const Offset(16, 60);
  CallSession? _session;
  Timer? _elapsedTimer;
  StreamSubscription<CallSession?>? _sessionSubscription;

  @override
  void initState() {
    super.initState();
    _initCall();
  }

  Future<void> _initCall() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    final coordinator = ref.read(callCoordinatorProvider);
    _callCoordinator = coordinator;

    _session = coordinator.activeSession;
    _sessionSubscription = coordinator.sessionStream.listen((session) {
      if (!mounted) return;
      setState(() {
        _session = session;
      });
    });

    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _session?.state == CallState.connected) {
        setState(() {});
      }
    });

    coordinator.attachRenderers(
      local: _localRenderer,
      remote: _remoteRenderer,
    );

    if (widget.incoming) {
      return;
    }

    final remoteNickname = widget.chatId.startsWith('direct_')
        ? widget.chatId.substring('direct_'.length)
        : widget.chatId;

    try {
      await coordinator.startOutgoing(
        remoteNickname: remoteNickname,
        chatId: widget.chatId,
        video: true,
      );

      if (mounted) setState(() {});
    } catch (error) {
      print('VIDEO_CALL_START_FAILED: $error');
    }
  }

  @override
  void dispose() {
    _sessionSubscription?.cancel();
    _elapsedTimer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  String get _identity {
    final nickname = _session?.remoteNickname;
    if (nickname != null && nickname.isNotEmpty) {
      return nickname;
    }

    if (widget.chatId.startsWith('direct_')) {
      return widget.chatId.substring('direct_'.length);
    }

    return widget.chatId;
  }

  String _stateLabel(CallState? state) {
    switch (state) {
      case CallState.ringing:
        return 'Ringing…';
      case CallState.connecting:
        return 'Connecting…';
      case CallState.connected:
        return 'Encrypted video call';
      case CallState.ended:
        return 'Call ended';
      case CallState.failed:
        return 'Call failed';
      case null:
        return 'Connecting…';
    }
  }

  String _formatElapsed() {
    final connectedAt = _session?.connectedAt;
    if (connectedAt == null) {
      return '00:00';
    }

    final elapsed = DateTime.now().difference(connectedAt);
    final totalSeconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: SafeArea(
              child: Row(
                children: [
                  const Icon(
                    Icons.lock,
                    size: 14,
                    color: StellarColors.success,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _identity,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _stateLabel(_session?.state),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  if (_session?.state == CallState.connected) ...[
                    const SizedBox(width: 8),
                    Text(
                      _formatElapsed(),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Positioned(
            left: _pipOffset.dx,
            top: _pipOffset.dy,
            child: GestureDetector(
              onPanUpdate: (details) => setState(() => _pipOffset += details.delta),
              child: Container(
                width: 100,
                height: 140,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                clipBehavior: Clip.antiAlias,
                child: RTCVideoView(_localRenderer, mirror: _frontCamera),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: SafeArea(
              child: Column(
                children: [
                  CallControlDock(
                    muted: _muted,
                    speakerOn: _speakerOn,
                    cameraOff: _cameraOff,
                    showCameraControls: true,
                    onToggleMute: () {
                      setState(() => _muted = !_muted);
                      _callCoordinator?.toggleMute(_muted);
                    },
                    onToggleSpeaker: () {
                      final next = !_speakerOn;
                      setState(() => _speakerOn = next);
                      _callCoordinator?.setSpeakerphone(next);
                    },
                    onToggleCamera: () {
                      setState(() => _cameraOff = !_cameraOff);
                      _callCoordinator?.toggleCamera(_cameraOff);
                    },
                    onFlipCamera: () {
                      setState(() => _frontCamera = !_frontCamera);
                      _callCoordinator?.switchCamera();
                    },
                    onEndCall: () {
                      _callCoordinator?.endActiveCall();
                      context.pop();
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
