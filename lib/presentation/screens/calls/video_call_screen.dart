import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../core/calls/call_service.dart';
import '../../state/app_providers.dart';
import '../../widgets/call_control_dock.dart';

class VideoCallScreen extends ConsumerStatefulWidget {
  const VideoCallScreen({super.key, required this.chatId});
  final String chatId;

  @override
  ConsumerState<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends ConsumerState<VideoCallScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  CallService? _callService;
  bool _muted = false;
  bool _cameraOff = false;
  bool _frontCamera = true;
  Offset _pipOffset = const Offset(16, 60);

  @override
  void initState() {
    super.initState();
    _initCall();
  }

  Future<void> _initCall() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    final service = CallService(
      relayClient: ref.read(relayClientProvider),
      sessionManager: ref.read(sessionManagerProvider),
      localRenderer: _localRenderer,
      remoteRenderer: _remoteRenderer,
    );
    _callService = service;

    final remoteNickname = widget.chatId.startsWith('direct_')
        ? widget.chatId.substring('direct_'.length)
        : widget.chatId;

    await service.start(remoteNickname: remoteNickname, direction: CallDirection.outgoing, video: true);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _callService?.end();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
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
            child: SafeArea(
              child: Row(
                children: const [
                  Icon(Icons.lock, size: 14, color: StellarColors.success),
                  SizedBox(width: 6),
                  Text('Encrypted', style: TextStyle(color: Colors.white, fontSize: 12)),
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
                    speakerOn: true,
                    cameraOff: _cameraOff,
                    showCameraControls: true,
                    onToggleMute: () {
                      setState(() => _muted = !_muted);
                      _callService?.toggleMute(_muted);
                    },
                    onToggleSpeaker: () {},
                    onToggleCamera: () {
                      setState(() => _cameraOff = !_cameraOff);
                      _callService?.toggleCamera(_cameraOff);
                    },
                    onFlipCamera: () {
                      setState(() => _frontCamera = !_frontCamera);
                      _callService?.switchCamera();
                    },
                    onEndCall: () {
                      _callService?.end();
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
