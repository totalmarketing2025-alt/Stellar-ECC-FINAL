import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../core/calls/call_coordinator.dart';
import '../../state/app_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/call_control_dock.dart';

class VoiceCallScreen extends ConsumerStatefulWidget {
  const VoiceCallScreen({super.key, required this.chatId});
  final String chatId;

  @override
  ConsumerState<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends ConsumerState<VoiceCallScreen> {
  final _localRenderer = RTCVideoRenderer(); // unused visually for voice, but CallService's
  final _remoteRenderer = RTCVideoRenderer(); // API is shared between voice/video calls.
  CallCoordinator? _callCoordinator;
  bool _muted = false;
  bool _speakerOn = false;
  String _stateLabel = 'Connecting…';

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

    coordinator.attachRenderers(
      local: _localRenderer,
      remote: _remoteRenderer,
    );

    final remoteNickname = widget.chatId.startsWith('direct_')
        ? widget.chatId.substring('direct_'.length)
        : widget.chatId;

    try {
      await coordinator.startOutgoing(
        remoteNickname: remoteNickname,
        chatId: widget.chatId,
        video: false,
      );

      if (mounted) {
        setState(() => _stateLabel = 'Encrypted call in progress');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _stateLabel = 'Call failed');
      }
      print('VOICE_CALL_START_FAILED: $error');
    }
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            StellarAvatar(seed: widget.chatId, label: widget.chatId, size: 120),
            const SizedBox(height: 24),
            Text(widget.chatId, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock, size: 14, color: StellarColors.success),
                const SizedBox(width: 6),
                Text(_stateLabel, style: const TextStyle(color: StellarColors.textSecondary)),
              ],
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _showSafetyNumberCompare(context),
              icon: const Icon(Icons.verified_user_outlined, size: 16, color: StellarColors.accentBlue),
              label: const Text('Verify safety number', style: TextStyle(color: StellarColors.accentBlue)),
            ),
            const SizedBox(height: 24),
            CallControlDock(
              muted: _muted,
              speakerOn: _speakerOn,
              onToggleMute: () {
                setState(() => _muted = !_muted);
                _callCoordinator?.toggleMute(_muted);
              },
              onToggleSpeaker: () => setState(() => _speakerOn = !_speakerOn),
              onEndCall: () {
                _callCoordinator?.endActiveCall();
                context.pop();
              },
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  void _showSafetyNumberCompare(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: StellarColors.bgElevated,
        title: const Text('Safety Number'),
        content: const Text(
          'Compare this number with your contact in person or over a separate '
          'trusted channel to confirm no one is intercepting your conversation.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
        ],
      ),
    );
  }
}
