import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../core/calls/call_coordinator.dart';
import '../../../domain/models/call_session.dart';
import '../../state/app_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/call_control_dock.dart';

class VoiceCallScreen extends ConsumerStatefulWidget {
  const VoiceCallScreen({
    super.key,
    required this.chatId,
    this.incoming = false,
  });
  final String chatId;
  final bool incoming;

  @override
  ConsumerState<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends ConsumerState<VoiceCallScreen> {
  final _localRenderer = RTCVideoRenderer(); // unused visually for voice, but CallService's
  final _remoteRenderer = RTCVideoRenderer(); // API is shared between voice/video calls.
  CallCoordinator? _callCoordinator;
  bool _muted = false;
  bool _speakerOn = false;
  CallSession? _session;
  StreamSubscription<CallSession?>? _sessionSubscription;
  Timer? _elapsedTicker;

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

    void handleSession(CallSession? session) {
      if (!mounted) {
        return;
      }
      if (session == null) {
        setState(() {
          _session = null;
        });
        return;
      }

      if (session.chatId != widget.chatId) {
        return;
      }

      setState(() {
        _session = session;
      });
    }

    _sessionSubscription = coordinator.sessionStream.listen(handleSession);

    final active = coordinator.activeSession;
    if (active != null && active.chatId == widget.chatId) {
      handleSession(active);
    }

    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _session?.state != CallState.connected) {
        return;
      }
      setState(() {});
    });

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
        video: false,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _session = CallSession(
            callId: _session?.callId ?? '',
            chatId: widget.chatId,
            kind: CallKind.voice,
            state: CallState.failed,
            remoteNickname: remoteNickname,
          );
        });
      }
      print('VOICE_CALL_START_FAILED: $error');
    }
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    _sessionSubscription?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final identity = session?.remoteNickname?.isNotEmpty == true
        ? session!.remoteNickname!
        : widget.chatId;
    final stateLabel = _stateLabel(session);

    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            StellarAvatar(seed: identity, label: identity, size: 120),
            const SizedBox(height: 24),
            Text(identity, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock, size: 14, color: StellarColors.success),
                const SizedBox(width: 6),
                Text(stateLabel, style: const TextStyle(color: StellarColors.textSecondary)),
              ],
            ),
            const SizedBox(height: 8),
            if (session?.state == CallState.connected)
              Text(
                _formatElapsed(session!.elapsed),
                style: const TextStyle(
                  color: StellarColors.textSecondary,
                  fontSize: 14,
                ),
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

  String _stateLabel(CallSession? session) {
    switch (session?.state) {
      case CallState.ringing:
        return 'Ringing…';
      case CallState.connecting:
        return 'Connecting…';
      case CallState.connected:
        return 'Encrypted call in progress';
      case CallState.ended:
        return 'Call ended';
      case CallState.failed:
        return 'Call failed';
      case null:
        return 'Connecting…';
    }
  }

  String _formatElapsed(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');

    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
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
