import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/calls/group_call_coordinator.dart';
import '../../../core/calls/group_call_protocol.dart';
import '../../../core/theme/stellar_theme.dart';
import '../../../domain/models/group_call_room.dart';
import '../../state/app_providers.dart';
import '../../widgets/call_control_dock.dart';
import '../../widgets/stellar_avatar.dart';

class GroupCallScreen extends ConsumerStatefulWidget {
  const GroupCallScreen({
    super.key,
    required this.chatId,
    this.incoming = false,
    this.video = false,
  });
  final String chatId;
  final bool incoming;
  final bool video;

  @override
  ConsumerState<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends ConsumerState<GroupCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  GroupCallCoordinator? _coordinator;
  StreamSubscription<GroupCallRoom?>? _subscription;
  GroupCallRoom? _room;
  bool _startedCall = false;
  bool _ending = false;
  bool _busyCamera = false;
  bool _muted = false;
  bool _speakerOn = true;
  bool _frontCamera = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    if (!mounted) {
      await _localRenderer.dispose();
      return;
    }
    final coordinator = ref.read(groupCallCoordinatorProvider);
    _coordinator = coordinator;
    coordinator.attachLocalRenderer(_localRenderer);
    _subscription = coordinator.roomStream.listen((room) {
      if (!mounted) return;
      if (room == null) {
        if (_startedCall) _close();
        return;
      }
      if (room.chatId != widget.chatId) return;
      setState(() {
        _room = room;
        _startedCall = true;
      });
    });

    final existing = coordinator.activeRoom;
    if (existing != null) {
      if (existing.chatId != widget.chatId) {
        _showError('Another group call is already in progress');
        return;
      }
      setState(() {
        _room = existing;
        _startedCall = true;
      });
      return;
    }
    if (widget.incoming) {
      _showError('Group invitation has expired');
      return;
    }
    try {
      await coordinator.startOutgoing(
        chatId: widget.chatId,
        video: widget.video,
      );
    } catch (error) {
      _showError('Could not start group call: $error');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _close() {
    if (_ending || !mounted) return;
    _ending = true;
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

  Future<void> _endCall() async {
    await _coordinator?.leaveRoom();
    if (mounted) _close();
  }

  Future<void> _toggleVideo() async {
    final room = _room;
    if (room == null || _busyCamera || room.isIncoming) return;
    setState(() => _busyCamera = true);
    try {
      await _coordinator?.setVideoEnabled(!room.localVideo);
    } catch (error) {
      _showError('Camera switch failed: $error');
    } finally {
      if (mounted) setState(() => _busyCamera = false);
    }
  }

  Future<void> _accept() async {
    try {
      await _coordinator?.acceptInvitation();
    } catch (error) {
      _showError('Could not join call: $error');
      await _endCall();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    final coordinator = _coordinator;
    coordinator?.detachLocalRenderer(_localRenderer);
    if (coordinator?.activeRoom?.chatId == widget.chatId) {
      unawaited(coordinator!.leaveRoom());
    }
    _localRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final nickname = ref.watch(localNicknameProvider) ?? 'You';
    final peers = room?.members.where((name) => name != GroupCallProtocol.normalize(nickname))
        .toList() ?? <String>[];
    final showingVideo = room == null
        ? widget.video
        : room.isIncoming
            ? room.video
            : room.localVideo || room.remoteVideo.values.any((enabled) => enabled);
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      appBar: AppBar(
        title: Text(showingVideo ? 'Group video call' : 'Group voice call'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Leave group call',
          onPressed: _endCall,
        ),
        actions: [
          if (room != null) Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(child: Text(
              '${room.participantCount}/${room.members.length} connected',
              style: const TextStyle(color: StellarColors.textSecondary),
            )),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: Image.asset(
            'assets/images/chat_background.png', fit: BoxFit.cover,
          )),
          Positioned.fill(child: ColoredBox(
            color: Colors.black.withOpacity(0.65),
          )),
          SafeArea(child: Column(
            children: [
              const SizedBox(height: 16),
              if (room?.isIncoming == true) ...[
                Text('${room!.inviter} is inviting you to a group call',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 16),
              ] else if (room == null) ...[
                Text(_error ?? 'Preparing encrypted group call…',
                    textAlign: TextAlign.center),
              ] else ...[
                Text(room.phase == GroupCallPhase.connected
                    ? 'Encrypted peer-to-peer group call'
                    : 'Waiting for members to join…',
                    style: const TextStyle(color: StellarColors.textSecondary)),
              ],
              const SizedBox(height: 12),
              Expanded(child: GridView.count(
                crossAxisCount: 2,
                padding: const EdgeInsets.all(12),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.85,
                children: [
                  _callTile(
                    label: '$nickname (You)',
                    videoEnabled: room?.localVideo == true,
                    renderer: _localRenderer,
                    mirror: _frontCamera,
                    state: room?.isIncoming == true ? 'Invited' : 'In call',
                  ),
                  for (final peer in peers)
                    _callTile(
                      label: peer,
                      videoEnabled: room?.remoteVideo[peer] ?? room?.video == true,
                      renderer: _coordinator?.rendererFor(peer),
                      state: _memberState(room?.connectionStates[peer]),
                    ),
                ],
              )),
              if (room?.isIncoming == true) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      FilledButton.icon(
                        onPressed: _accept,
                        icon: const Icon(Icons.call),
                        label: const Text('Join'),
                      ),
                      FilledButton.icon(
                        onPressed: () async {
                          await _coordinator?.declineInvitation();
                          if (mounted) _close();
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: StellarColors.danger,
                        ),
                        icon: const Icon(Icons.call_end),
                        label: const Text('Decline'),
                      ),
                    ],
                  ),
                ),
              ] else if (room != null) ...[
                CallControlDock(
                  muted: _muted,
                  speakerOn: _speakerOn,
                  cameraOff: !room.localVideo,
                  cameraBusy: _busyCamera,
                  showCameraControls: true,
                  onToggleMute: () async {
                    final next = !_muted;
                    await _coordinator?.toggleMute(next);
                    if (mounted) setState(() => _muted = next);
                  },
                  onToggleSpeaker: () async {
                    final next = !_speakerOn;
                    await _coordinator?.setSpeakerphone(next);
                    if (mounted) setState(() => _speakerOn = next);
                  },
                  onToggleCamera: _toggleVideo,
                  onFlipCamera: () async {
                    try {
                      await _coordinator?.switchCamera();
                      if (mounted) setState(() => _frontCamera = !_frontCamera);
                    } catch (error) {
                      _showError('Could not switch camera: $error');
                    }
                  },
                  onEndCall: _endCall,
                ),
              ],
              const SizedBox(height: 20),
            ],
          )),
        ],
      ),
    );
  }

  String _memberState(GroupMemberCallState? state) {
    switch (state) {
      case GroupMemberCallState.connected: return 'Connected';
      case GroupMemberCallState.joining: return 'Connecting';
      case GroupMemberCallState.left: return 'Left';
      case GroupMemberCallState.failed: return 'Connection lost';
      case GroupMemberCallState.invited:
      case null: return 'Invited';
    }
  }

  Widget _callTile({
    required String label,
    required String state,
    required bool videoEnabled,
    required RTCVideoRenderer? renderer,
    bool mirror = false,
  }) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: StellarColors.bgElevated.withOpacity(0.92),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: StellarColors.accentPurple.withOpacity(0.4)),
    ),
    child: Stack(children: [
      Positioned.fill(child: videoEnabled && renderer != null
          ? RTCVideoView(renderer, mirror: mirror,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          : Center(child: StellarAvatar(seed: label, label: label, size: 72))),
      Positioned(left: 0, right: 0, bottom: 0,
        child: Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(state, style: const TextStyle(
                  fontSize: 11, color: StellarColors.textSecondary)),
            ]),
        ),
      ),
    ]),
  );
}
