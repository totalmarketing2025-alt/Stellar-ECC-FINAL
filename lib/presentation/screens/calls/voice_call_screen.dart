import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/calls/call_coordinator.dart';
import '../../../domain/models/call_session.dart';
import '../../state/app_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/call_control_dock.dart';
import 'add_participant_to_call_dialog.dart';

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
  bool _cameraSwitching = false;
  bool _frontCamera = true;
  CallSession? _session;
  bool _closingCallScreen = false;
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

    if (!mounted) {
      await _localRenderer.dispose();
      await _remoteRenderer.dispose();
      return;
    }

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
        if (_session != null) {
          _closeCallScreen();
        }
        return;
      }

      if (session.chatId != widget.chatId ||
          session.kind != CallKind.voice) {
        return;
      }

      setState(() {
        _session = session;
      });

      if (session.state == CallState.ended ||
          session.state == CallState.failed) {
        _closeCallScreen();
      }
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

    if (!mounted) {
      return;
    }

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

  void _closeCallScreen() {
    if (_closingCallScreen || !mounted) return;

    _closingCallScreen = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (!ref.read(isUnlockedProvider)) {
        context.go('/unlock');
      } else if (context.canPop()) {
        context.pop();
      } else {
        context.go('/chat/${Uri.encodeComponent(widget.chatId)}');
      }
    });
  }

  Future<void> _toggleVideo() async {
    final coordinator = _callCoordinator;
    final session = _session;
    if (coordinator == null || session?.state != CallState.connected ||
        _cameraSwitching) return;
    setState(() => _cameraSwitching = true);
    try {
      await coordinator.setVideoEnabled(!session!.localVideoEnabled);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update camera: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _cameraSwitching = false);
    }
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    _sessionSubscription?.cancel();

    final coordinator = _callCoordinator;
    final session = coordinator?.activeSession;

    final upgradingToGroup =
        ref.read(groupCallCoordinatorProvider).isDirectUpgradeInProgress;
    if (coordinator != null &&
        session != null &&
        !upgradingToGroup &&
        session.chatId == widget.chatId &&
        session.kind == CallKind.voice) {
      unawaited(coordinator.endActiveCall());
    }

    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = _session;
    final identity = session?.remoteNickname?.isNotEmpty == true
        ? session!.remoteNickname!
        : widget.chatId;
    final stateLabel = _stateLabel(session, l10n);

    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/chat_background.png',
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withOpacity(0.42),
            ),
          ),
          if (session?.state == CallState.connected &&
              session?.remoteVideoEnabled == true)
            Positioned.fill(
              child: RTCVideoView(
                _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
          if (session?.state == CallState.connected &&
              session?.localVideoEnabled == true)
            Positioned(
              top: 60,
              right: 16,
              child: Container(
                width: 100,
                height: 140,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: RTCVideoView(_localRenderer, mirror: _frontCamera),
              ),
            ),
          SafeArea(
            child: Column(
          children: [
            const SizedBox(height: 48),
            if (session?.remoteVideoEnabled != true)
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
            if (ref.watch(isUnlockedProvider))
              TextButton.icon(
              onPressed: () => _showSafetyNumberCompare(context),
              icon: const Icon(Icons.verified_user_outlined, size: 16, color: StellarColors.accentBlue),
              label: Text(l10n.verifySafetyNumber, style: const TextStyle(color: StellarColors.accentBlue)),
            ),
            const SizedBox(height: 24),
            if (widget.incoming &&
                (_session == null || _session?.state == CallState.ringing))
              _buildIncomingControls()
            else
              CallControlDock(
              muted: _muted,
              speakerOn: _speakerOn,
              cameraOff: session?.localVideoEnabled != true,
              cameraBusy: _cameraSwitching,
              showCameraControls: session?.state == CallState.connected,
              onToggleCamera: _toggleVideo,
              onFlipCamera: () async {
                try {
                  await _callCoordinator?.switchCamera();
                  if (mounted) setState(() => _frontCamera = !_frontCamera);
                } catch (error) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not switch camera: $error')),
                    );
                  }
                }
              },
              onToggleMute: () {
                setState(() => _muted = !_muted);
                _callCoordinator?.toggleMute(_muted);
              },
              onToggleSpeaker: () {
                final next = !_speakerOn;
                setState(() => _speakerOn = next);
                _callCoordinator?.setSpeakerphone(next);
              },
              onAddParticipant: session?.state == CallState.connected
                  ? () => unawaited(addParticipantToActiveCall(
                        context: context,
                        ref: ref,
                        session: session!,
                      ))
                  : null,
              onEndCall: () async {
                await _callCoordinator?.endActiveCall();
                if (mounted) _closeCallScreen();
              },
            ),
            const SizedBox(height: 32),
            ],
          ),
        ),
        ],
      ),
    );
  }

  Widget _buildIncomingControls() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: StellarColors.success,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
            ),
            onPressed: () async {
              await _callCoordinator?.answerIncomingCall();
            },
            icon: const Icon(Icons.call),
            label: Text(l10n.answer),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: StellarColors.danger,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
            ),
            onPressed: () async {
              await _callCoordinator?.rejectIncomingCall();
              if (mounted) _closeCallScreen();
            },
            icon: const Icon(Icons.call_end),
            label: Text(l10n.decline),
          ),
        ],
      ),
    );
  }

  String _stateLabel(CallSession? session, AppLocalizations l10n) {
    switch (session?.state) {
      case CallState.ringing:
        return l10n.ringing;
      case CallState.answering:
        return l10n.answering;
      case CallState.connecting:
        return l10n.connecting;
      case CallState.connected:
        return l10n.encryptedCallInProgress;
      case CallState.ended:
        return l10n.callEnded;
      case CallState.failed:
        return l10n.callFailed;
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
