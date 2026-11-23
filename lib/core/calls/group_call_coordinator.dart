import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../domain/models/group_call_room.dart';
import '../crypto/session_manager.dart';
import '../network/directory_client.dart';
import '../network/relay_client.dart';
import '../storage/database.dart';
import 'call_media_state.dart';
import 'call_signal_authenticator.dart';
import 'call_signal_router.dart';
import 'group_call_protocol.dart';

/// Maximum four participants, direct DTLS-SRTP media between each pair.
/// This first release handles in-app invitations; native background group
/// ringing is deliberately separate from the existing 1:1 call service.
class GroupCallCoordinator {
  GroupCallCoordinator({
    required this.db,
    required this.relay,
    required this.directory,
    required this.sessionManager,
    required this.signalRouter,
    required this.localNickname,
    required this.hasDirectCall,
  });

  final StellarDatabase db;
  final RelayClient relay;
  final DirectoryClient directory;
  final SessionManager sessionManager;
  final CallSignalRouter signalRouter;
  final String localNickname;
  final bool Function() hasDirectCall;

  final _roomController = StreamController<GroupCallRoom?>.broadcast();
  Stream<GroupCallRoom?> get roomStream => _roomController.stream;
  GroupCallRoom? get activeRoom => _room;

  static const _nativeGroupCalls = MethodChannel('ecc.stellar.app/group_calls');

  Future<void> _nativeInvitation(String method, String roomId) async {
    try {
      await _nativeGroupCalls.invokeMethod<bool>(method, {'roomId': roomId});
    } on MissingPluginException {
      // Foreground Flutter calls remain available on other platforms.
    } on PlatformException {
      // Native registry is advisory; signed Flutter state is authoritative.
    }
  }

  Future<void> _groupForeground(String method, String roomId,
      {bool video = false}) async {
    try {
      await _nativeGroupCalls.invokeMethod<bool>(method, {
        'roomId': roomId,
        'video': video,
      });
    } on MissingPluginException {
      // Native foreground service is Android-only.
    } on PlatformException catch (error) {
      print('GROUP_FOREGROUND_FAILED: ${error.code}');
    }
  }

  GroupCallRoom? _room;
  final Map<String, _MeshPeer> _peers = {};
  final Map<String, Future<_MeshPeer>> _creatingPeers = {};
  final Map<String, List<RTCIceCandidate>> _earlyIce = {};
  final Map<String, int> _remoteMediaRevisions = {};
  MediaStream? _localStream;
  MediaStream? _cameraCaptureStream;
  RTCVideoRenderer? _localRenderer;
  Map<String, dynamic>? _iceConfiguration;
  StreamSubscription<CallSignal>? _subscription;
  Future<void> _incomingQueue = Future<void>.value();
  int _queuedSignals = 0;
  static const _maxQueuedSignals = 256;
  Timer? _invitationTimeout;
  Timer? _presenceTimer;
  bool _changingVideo = false;
  bool _disposed = false;
  int _generation = 0;
  int _mediaRevision = 0;

  String get _local => GroupCallProtocol.normalize(localNickname);
  bool get isActive => _room != null &&
      _room!.phase != GroupCallPhase.ringing &&
      _room!.phase != GroupCallPhase.ended &&
      _room!.phase != GroupCallPhase.failed;

  bool _drainingNativeActions = false;
  bool _nativeDrainRequested = false;

  Future<void> _drainNativeActions() async {
    _nativeDrainRequested = true;
    if (_drainingNativeActions || _disposed) return;
    _drainingNativeActions = true;
    try {
      while (_nativeDrainRequested && !_disposed) {
        _nativeDrainRequested = false;
        final actions = await _nativeGroupCalls.invokeListMethod<dynamic>(
          'takeGroupActions',
        );
        for (final action in actions ?? const []) {
          if (_disposed || action is! Map) continue;
          final room = _room;
          if (room == null || room.phase != GroupCallPhase.ringing ||
              action['roomId'] != room.roomId) continue;
          if (action['action'] == 'join') {
            await acceptInvitation();
          } else if (action['action'] == 'decline') {
            await declineInvitation();
          }
        }
      }
    } on MissingPluginException {
      // Native actions are Android-only.
    } on PlatformException {
      // In-app controls remain available.
    } finally {
      _drainingNativeActions = false;
    }
  }

  void start() {
    _nativeGroupCalls.setMethodCallHandler((call) async {
      if (call.method == 'groupActionsAvailable') {
        await _drainNativeActions();
      }
    });
    unawaited(_drainNativeActions());
    _subscription ??= signalRouter.incoming.listen((signal) {
      if (_disposed || !signal.type.startsWith('group-') ||
          _queuedSignals >= _maxQueuedSignals) return;
      _queuedSignals++;
      _incomingQueue = _incomingQueue
          .then((_) => _handleSignal(signal))
          .catchError((Object error) {
        print('GROUP_CALL_SIGNAL_FAILED');
      }).whenComplete(() { _queuedSignals--; });
    });
  }

  void attachLocalRenderer(RTCVideoRenderer renderer) {
    _localRenderer = renderer;
    renderer.srcObject = _room?.localVideo == true
        ? (_cameraCaptureStream ?? _localStream)
        : null;
  }

  void detachLocalRenderer(RTCVideoRenderer renderer) {
    if (identical(_localRenderer, renderer)) _localRenderer = null;
  }

  RTCVideoRenderer? rendererFor(String nickname) =>
      _peers[GroupCallProtocol.normalize(nickname)]?.renderer;

  void _emit() {
    if (!_disposed && !_roomController.isClosed) _roomController.add(_room);
  }

  bool _isCurrent(int generation, String roomId) =>
      !_disposed && _generation == generation && _room?.roomId == roomId;

  Future<List<String>> _membersFor(String chatId) async {
    final chat = await db.chatDao.byId(chatId);
    if (chat == null || chat['chat_type'] != 'group') {
      throw StateError('Group does not exist on this device');
    }
    final rows = await db.chatDao.groupMembers(chatId);
    final names = GroupCallProtocol.members(
      rows.map((row) => row['nickname']?.toString() ?? ''),
    );
    if (!GroupCallProtocol.validMembers(names, _local)) {
      throw StateError('Group calls require 2–4 verified group members');
    }
    return names;
  }

  Future<bool> _membershipStillMatches(GroupCallRoom room) async {
    try {
      final members = await _membersFor(room.chatId);
      return GroupCallProtocol.membershipDigest(members) == room.membersDigest;
    } catch (_) {
      return false;
    }
  }

  static String _newRoomId() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> startOutgoing({
    required String chatId,
    required bool video,
  }) async {
    if (_room != null || hasDirectCall()) {
      throw StateError('Another call is already active');
    }
    final members = await _membersFor(chatId);
    if (_room != null || hasDirectCall()) {
      throw StateError('Another call started while opening group');
    }

    final roomId = _newRoomId();
    final digest = GroupCallProtocol.membershipDigest(members);
    final room = GroupCallRoom(
      roomId: roomId,
      chatId: chatId,
      membersDigest: digest,
      members: members,
      inviter: _local,
      video: video,
      phase: GroupCallPhase.connecting,
      joined: {_local},
      connectionStates: {
        for (final member in members)
          if (member != _local) member: GroupMemberCallState.invited,
      },
      remoteVideo: {},
      localVideo: video,
      joinedAt: DateTime.now(),
    );
    _room = room;
    final generation = ++_generation;
    _emit();
    try {
      await _prepareMedia(video);
      if (!_isCurrent(generation, roomId)) return;
      await _groupForeground('startGroupForeground', roomId, video: video);
      if (!_isCurrent(generation, roomId)) {
        await _groupForeground('stopGroupForeground', roomId);
        return;
      }
      _startPresence(roomId);
      for (final member in members) {
        if (member == _local) continue;
        try {
          await _send(member, 'group-invite');
          if (!_isCurrent(generation, roomId)) return;
          // Push is a wake hint only; the signed relay invitation remains
          // the authority for membership and accepting the call.
          await relay.sendCallWake(
            recipient: member,
            callId: roomId,
            kind: video ? 'video' : 'voice',
            group: true,
          );
        } catch (_) {
          print('GROUP_CALL_INVITE_FAILED');
        }
      }
      _invitationTimeout = Timer(const Duration(seconds: 60), () {
        if (_isCurrent(generation, roomId) &&
            _room!.connectedPeers == 0) {
          unawaited(leaveRoom());
        }
      });
    } catch (_) {
      await _closeRoom(roomId);
      rethrow;
    }
  }

  int? _decliningGeneration;

  Future<void> acceptInvitation() async {
    final room = _room;
    if (room == null || room.phase != GroupCallPhase.ringing) return;
    final generation = _generation;
    if (_decliningGeneration == generation) return;
    final membershipValid = await _membershipStillMatches(room);
    if (!_isCurrent(generation, room.roomId) ||
        _room?.phase != GroupCallPhase.ringing ||
        _decliningGeneration == generation) return;
    if (hasDirectCall() || !membershipValid) {
      await declineInvitation();
      return;
    }
    unawaited(_nativeInvitation('consumeInvitation', room.roomId));
    _invitationTimeout?.cancel();
    _invitationTimeout = null;
    _room = _room!.copyWith(
      phase: GroupCallPhase.connecting,
      joined: {..._room!.joined, _local},
      joinedAt: DateTime.now(),
    );
    _emit();
    try {
      await _prepareMedia(room.video);
      if (!_isCurrent(generation, room.roomId)) return;
      await _groupForeground('startGroupForeground', room.roomId,
          video: room.video);
      if (!_isCurrent(generation, room.roomId)) {
        await _groupForeground('stopGroupForeground', room.roomId);
        return;
      }
      _startPresence(room.roomId);
      await _announceJoin();
      await _connectJoinedPeers();
    } catch (_) {
      await _closeRoom(room.roomId);
      rethrow;
    }
  }

  Future<void> declineInvitation() async {
    final room = _room;
    if (room == null || room.phase != GroupCallPhase.ringing) return;
    final generation = _generation;
    if (_decliningGeneration == generation) return;
    _decliningGeneration = generation;
    try {
      await _send(room.inviter, 'group-reject')
          .timeout(const Duration(seconds: 3));
    } catch (_) { /* Always dismiss locally. */ }
    if (_isCurrent(generation, room.roomId)) await _closeRoom(room.roomId);
    if (_decliningGeneration == generation) _decliningGeneration = null;
  }

  Future<void> _announceJoin() async {
    final room = _room;
    if (room == null || !isActive) return;
    final generation = _generation;
    for (final member in room.members) {
      if (!_isCurrent(generation, room.roomId) || !isActive) return;
      if (member == _local) continue;
      try {
        await _send(member, 'group-join');
      } catch (_) {
        print('GROUP_JOIN_ANNOUNCE_FAILED');
      }
    }
  }

  int? _presenceInFlightGeneration;

  void _startPresence(String roomId) {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (_room?.roomId != roomId || !isActive) return;
      final generation = _generation;
      if (_presenceInFlightGeneration == generation) return;
      _presenceInFlightGeneration = generation;
      unawaited(_refreshPresence(roomId).catchError((Object _) {
        // A transient signaling failure is retried on the next tick.
      }).whenComplete(() {
        if (_presenceInFlightGeneration == generation) {
          _presenceInFlightGeneration = null;
        }
      }));
    });
  }

  Future<void> _refreshPresence(String roomId) async {
    final room = _room;
    if (room == null || room.roomId != roomId) return;
    final generation = _generation;
    final matches = await _membershipStillMatches(room);
    if (!_isCurrent(generation, roomId) || !isActive) return;
    if (!matches) {
      await leaveRoom(); // Membership changes revoke the old room snapshot.
      return;
    }
    await _announceJoin(); // Also heals out-of-order or dropped join signals.
    if (!_isCurrent(generation, roomId) || !isActive) return;
    for (final remote in _room!.joined.toList()) {
      if (remote == _local || !_isCurrent(generation, roomId)) continue;
      final peer = _peers[remote];
      if (peer == null) {
        try {
          await _connectJoinedPeers();
        } catch (_) {
          // Presence will retry missing mesh edges on the next tick.
        }
        break;
      }
      if (peer.connectionState ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          peer.connectionState ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _schedulePeerRecovery(remote, peer);
      }
    }
    if (!_isCurrent(generation, roomId)) return;
    if (_room?.inviter == _local) {
      for (final peer in room.members) {
        if (!_isCurrent(generation, roomId)) return;
        if (peer == _local ||
            _room?.connectionStates[peer] != GroupMemberCallState.invited) {
          continue;
        }
        try {
          await _send(peer, 'group-invite');
        } catch (_) { /* Retry on next presence tick. */ }
      }
    }
  }

  Future<void> _handleSignal(CallSignal signal) async {
    if (_disposed || !GroupCallProtocol.isValidGroupSignal(signal.payload)) return;
    final remote = GroupCallProtocol.normalize(
      signal.session.remoteNickname ?? '',
    );
    if (remote.isEmpty || remote == _local) return;
    final roomId = signal.payload['roomId'] as String;

    if (signal.type == 'group-invite') {
      if (_room != null || hasDirectCall()) return;
      final invitationGeneration = _generation;
      final members = await _membersFor(signal.session.chatId).catchError(
        (Object _) => <String>[],
      );
      if (_disposed || _generation != invitationGeneration ||
          _room != null || hasDirectCall()) return;
      if (!members.contains(remote) ||
          GroupCallProtocol.membershipDigest(members) !=
              signal.payload['membersDigest']) return;

      final room = GroupCallRoom(
        roomId: roomId,
        chatId: signal.session.chatId,
        membersDigest: signal.payload['membersDigest'] as String,
        members: members,
        inviter: remote,
        video: signal.payload['kind'] == 'video',
        phase: GroupCallPhase.ringing,
        joined: {remote},
        connectionStates: {
          for (final member in members)
            if (member != _local) member: GroupMemberCallState.invited,
        },
        remoteVideo: {},
        localVideo: false,
      );
      _room = room;
      final generation = ++_generation;
      _emit();
      unawaited(_nativeInvitation('registerVerifiedInvitation', roomId));
      _invitationTimeout = Timer(const Duration(seconds: 45), () {
        if (_isCurrent(generation, roomId) &&
            _room?.phase == GroupCallPhase.ringing) {
          unawaited(declineInvitation());
        }
      });
      return;
    }

    final room = _room;
    if (room == null || room.roomId != roomId ||
        room.chatId != signal.session.chatId ||
        room.video != (signal.payload['kind'] == 'video') ||
        room.membersDigest != signal.payload['membersDigest'] ||
        !room.members.contains(remote)) return;
    final generation = _generation;
    final matches = await _membershipStillMatches(room);
    if (!_isCurrent(generation, roomId)) return;
    if (!matches) {
      await leaveRoom();
      return;
    }

    switch (signal.type) {
      case 'group-join':
        final isNewParticipant = !_room!.joined.contains(remote);
        _setJoined(remote);
        if (isActive) {
          await _connectJoinedPeers();
          if (isNewParticipant) {
            // A late joiner knows only the inviter. Announce ourselves
            // immediately so the remaining mesh edges form without waiting
            // for the next periodic presence tick.
            if (!_isCurrent(generation, roomId)) return;
            await _send(remote, 'group-join');
            if (!_isCurrent(generation, roomId)) return;
            // A camera toggle may predate this participant's arrival.
            await _send(remote, 'group-media', {
              'videoEnabled': _room!.localVideo,
              'mediaRevision': ++_mediaRevision,
            });
          }
        }
        break;
      case 'group-reject':
      case 'group-leave':
        final joined = {..._room!.joined}..remove(remote);
        final states = {..._room!.connectionStates};
        states[remote] = GroupMemberCallState.left;
        _room = _room!.copyWith(joined: joined, connectionStates: states);
        _emit();
        await _removePeer(remote);
        break;
      case 'group-offer':
        if (!isActive || !_room!.joined.contains(remote)) return;
        await _receiveOffer(remote, signal.payload);
        break;
      case 'group-answer':
        if (!isActive || !_room!.joined.contains(remote)) return;
        await _receiveAnswer(remote, signal.payload);
        break;
      case 'group-ice':
        if (!isActive || !_room!.joined.contains(remote)) return;
        await _receiveIce(remote, signal.payload);
        break;
      case 'group-media':
        if (!isActive || !_room!.joined.contains(remote)) return;
        final parsed = CallMediaState.parse(
          signal.payload, _remoteMediaRevisions[remote] ?? 0,
        );
        if (parsed == null) return;
        _remoteMediaRevisions[remote] = parsed.revision;
        _room = _room!.copyWith(remoteVideo: {
          ..._room!.remoteVideo,
          remote: parsed.enabled,
        });
        _emit();
        break;
    }
  }

  void _setJoined(String remote) {
    final room = _room;
    if (room == null || room.joined.contains(remote)) return;
    final joined = {...room.joined, remote};
    final states = {...room.connectionStates};
    states[remote] = GroupMemberCallState.joining;
    _room = room.copyWith(joined: joined, connectionStates: states);
    _emit();
  }

  Future<void> _connectJoinedPeers() async {
    final room = _room;
    if (room == null || !isActive) return;
    final generation = _generation;
    for (final peer in room.joined) {
      if (!_isCurrent(generation, room.roomId)) return;
      if (peer == _local || !_room!.joined.contains(peer)) continue;
      final connection = await _ensurePeer(peer);
      if (!_isCurrent(generation, room.roomId) ||
          !identical(_peers[peer], connection)) return;
      if (GroupCallProtocol.shouldOffer(_local, peer) &&
          !connection.offered && !connection.remoteDescriptionSet) {
        connection.offered = true;
        try {
          final offer = await connection.pc.createOffer();
          if (!_isCurrent(generation, room.roomId) ||
              !identical(_peers[peer], connection)) return;
          final negotiation = ++connection.negotiation;
          await connection.pc.setLocalDescription(offer);
          if (!_isCurrent(generation, room.roomId) ||
              !identical(_peers[peer], connection)) return;
          await _send(peer, 'group-offer', {
            'sdp': offer.sdp,
            'sdpType': offer.type,
            'negotiationId': negotiation,
          });
        } catch (_) {
          connection.offered = false;
          rethrow;
        }
      }
    }
  }

  void _schedulePeerRecovery(String remote, _MeshPeer peer) {
    final room = _room;
    final generation = _generation;
    if (room == null || !isActive || !room.joined.contains(remote) ||
        !identical(_peers[remote], peer) || peer.retryTimer != null ||
        peer.retryCount >= 5 ||
        !GroupCallProtocol.shouldOffer(_local, remote)) return;
    final delay = Duration(seconds: 2 << peer.retryCount);
    peer.retryTimer = Timer(delay, () async {
      peer.retryTimer = null;
      if (!_isCurrent(generation, room.roomId) ||
          !identical(_peers[remote], peer) ||
          !_room!.joined.contains(remote) ||
          peer.connectionState ==
              RTCPeerConnectionState.RTCPeerConnectionStateConnected) return;
      peer.retryCount++;
      await _restartPeerIce(remote, peer);
      if (_isCurrent(generation, room.roomId) &&
          peer.connectionState !=
              RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _schedulePeerRecovery(remote, peer);
      }
    });
  }

  Future<void> _restartPeerIce(String remote, _MeshPeer peer) async {
    final room = _room;
    final generation = _generation;
    if (room == null || !isActive || !room.joined.contains(remote) ||
        !identical(_peers[remote], peer) || peer.restarting ||
        !peer.offered ||
        !GroupCallProtocol.shouldOffer(_local, remote)) return;
    peer.restarting = true;
    try {
      final offer = await peer.pc.createOffer({'iceRestart': true});
      if (!_isCurrent(generation, room.roomId) ||
          !identical(_peers[remote], peer)) return;
      final negotiation = ++peer.negotiation;
      await peer.pc.setLocalDescription(offer);
      if (!_isCurrent(generation, room.roomId) ||
          !identical(_peers[remote], peer)) return;
      peer.remoteDescriptionSet = false;
      await _send(remote, 'group-offer', {
        'sdp': offer.sdp,
        'sdpType': offer.type,
        'negotiationId': negotiation,
      });
    } catch (_) {
      print('GROUP_ICE_RESTART_FAILED');
    } finally {
      peer.restarting = false;
    }
  }

  Future<void> _receiveOffer(String remote, Map<String, dynamic> payload) async {
    // The lexical higher side is always the answerer. Never allow glare.
    if (GroupCallProtocol.shouldOffer(_local, remote)) return;
    final room = _room;
    if (room == null) return;
    final generation = _generation;
    final peer = await _ensurePeer(remote);
    bool current() => _isCurrent(generation, room.roomId) && identical(_peers[remote], peer);
    if (!current()) return;
    final negotiation = payload['negotiationId'];
    if (negotiation is! int || negotiation <= peer.remoteNegotiation) return;
    await peer.pc.setRemoteDescription(
      RTCSessionDescription(payload['sdp'] as String, 'offer'),
    );
    if (!current()) return;
    peer.remoteDescriptionSet = true;
    await _flushEarlyIce(remote, peer);
    if (!current()) return;
    final answer = await peer.pc.createAnswer();
    if (!current()) return;
    await peer.pc.setLocalDescription(answer);
    if (!current()) return;
    await _send(remote, 'group-answer', {
      'sdp': answer.sdp,
      'sdpType': answer.type,
      'negotiationId': negotiation,
    });
    if (current()) peer.remoteNegotiation = negotiation;
  }

  Future<void> _receiveAnswer(String remote, Map<String, dynamic> payload) async {
    if (!GroupCallProtocol.shouldOffer(_local, remote)) return;
    final room = _room;
    if (room == null) return;
    final generation = _generation;
    final peer = _peers[remote] ?? await _creatingPeers[remote];
    if (!_isCurrent(generation, room.roomId) || !identical(_peers[remote], peer)) return;
    if (peer == null || peer.remoteDescriptionSet || !peer.offered ||
        payload['negotiationId'] != peer.negotiation) return;
    await peer.pc.setRemoteDescription(
      RTCSessionDescription(payload['sdp'] as String, 'answer'),
    );
    if (!_isCurrent(generation, room.roomId) || !identical(_peers[remote], peer)) return;
    peer.remoteDescriptionSet = true;
    await _flushEarlyIce(remote, peer);
  }

  Future<void> _receiveIce(String remote, Map<String, dynamic> payload) async {
    final raw = payload['candidate'] as Map;
    final candidate = RTCIceCandidate(
      raw['candidate'] as String,
      raw['sdpMid'] as String?,
      raw['sdpMLineIndex'] as int?,
    );
    final peer = _peers[remote];
    if (peer == null || !peer.remoteDescriptionSet) {
      final queue = _earlyIce.putIfAbsent(remote, () => []);
      final duplicate = queue.any((item) =>
          item.candidate == candidate.candidate &&
          item.sdpMid == candidate.sdpMid &&
          item.sdpMLineIndex == candidate.sdpMLineIndex);
      if (!duplicate && queue.length < 128) queue.add(candidate);
      return;
    }
    await peer.pc.addCandidate(candidate);
  }

  Future<void> _flushEarlyIce(String remote, _MeshPeer peer) async {
    final queue = _earlyIce.remove(remote) ?? <RTCIceCandidate>[];
    for (final candidate in queue) {
      if (!identical(_peers[remote], peer)) return;
      try {
        await peer.pc.addCandidate(candidate);
      } catch (_) {
        // A stale candidate must not block the remaining candidates.
      }
    }
  }

  Future<_MeshPeer> _ensurePeer(String nickname) {
    final existing = _peers[nickname];
    if (existing != null) return Future.value(existing);
    final generation = _generation;
    return _creatingPeers.putIfAbsent(nickname, () async {
      try {
        return await _createPeer(nickname);
      } finally {
        if (_generation == generation) _creatingPeers.remove(nickname);
      }
    });
  }

  Future<_MeshPeer> _createPeer(String nickname) async {
    final room = _room!;
    final generation = _generation;
    final config = _iceConfiguration;
    final audioStream = _localStream;
    if (config == null || audioStream == null || !isActive) {
      throw StateError('Group media is not initialized');
    }
    final pc = await createPeerConnection(config);
    final renderer = RTCVideoRenderer();
    try {
      await renderer.initialize();
      if (!_isCurrent(generation, room.roomId)) {
        throw StateError('Expired group room');
      }

      for (final track in audioStream.getAudioTracks()) {
        await pc.addTrack(track, audioStream);
      }
      final cameraTrack = (_cameraCaptureStream ?? audioStream)
          .getVideoTracks().firstOrNull;
      RTCRtpSender sender;
      if (cameraTrack != null) {
        sender = await pc.addTrack(cameraTrack, _cameraCaptureStream ?? audioStream);
      } else {
        final transceiver = await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
        );
        sender = transceiver.sender;
      }
      if (!_isCurrent(generation, room.roomId)) {
        throw StateError('Expired group room');
      }
      final peer = _MeshPeer(pc: pc, renderer: renderer, videoSender: sender);
      _peers[nickname] = peer;

      pc.onTrack = (event) {
        if (!_isCurrent(generation, room.roomId) ||
            !identical(_peers[nickname], peer) ||
            event.track.kind != 'video') return;
        if (event.streams.isNotEmpty) {
          renderer.srcObject = event.streams.first;
        } else {
          unawaited(_attachStreamlessVideo(peer, event.track, generation, room.roomId));
        }
      };
      pc.onIceCandidate = (candidate) {
        if (!_isCurrent(generation, room.roomId) ||
            !identical(_peers[nickname], peer)) return;
        unawaited(_send(nickname, 'group-ice', {
          'candidate': candidate.toMap(),
        }).catchError((Object error) {
          print('GROUP_ICE_SEND_FAILED');
        }));
      };
      pc.onConnectionState = (state) {
        if (!_isCurrent(generation, room.roomId) ||
            !identical(_peers[nickname], peer) ||
            !_room!.joined.contains(nickname)) return;
        if (peer.connectionState == state) return;
        peer.connectionState = state;
        final states = {..._room!.connectionStates};
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            peer.retryTimer?.cancel();
            peer.retryTimer = null;
            peer.retryCount = 0;
            states[nickname] = GroupMemberCallState.connected;
            _invitationTimeout?.cancel();
            _invitationTimeout = null;
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
            states[nickname] = GroupMemberCallState.joining;
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            states[nickname] = GroupMemberCallState.failed;
            break;
          default:
            return;
        }
        final hasConnected = states.values
            .any((value) => value == GroupMemberCallState.connected);
        _room = _room!.copyWith(
          connectionStates: states,
          phase: hasConnected ? GroupCallPhase.connected : GroupCallPhase.connecting,
        );
        _emit();
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _schedulePeerRecovery(nickname, peer);
        }
      };
      return peer;
    } catch (_) {
      await pc.close();
      await renderer.dispose();
      rethrow;
    }
  }

  Future<void> _attachStreamlessVideo(
    _MeshPeer peer,
    MediaStreamTrack track,
    int generation,
    String roomId,
  ) async {
    final stream = peer.syntheticVideoStream ??
        await createLocalMediaStream('group-video-$roomId-${track.id}');
    if (!_isCurrent(generation, roomId)) {
      if (peer.syntheticVideoStream == null) await stream.dispose();
      return;
    }
    if (!stream.getVideoTracks().any((item) => item.id == track.id)) {
      await stream.addTrack(track);
    }
    peer.syntheticVideoStream = stream;
    peer.renderer.srcObject = stream;
  }

  Future<void> _removePeer(String nickname) async {
    final peer = _peers.remove(nickname);
    _earlyIce.remove(nickname);
    _remoteMediaRevisions.remove(nickname);
    if (peer == null) return;
    await _disposePeer(peer);
  }

  Future<void> _disposePeer(_MeshPeer peer) async {
    peer.retryTimer?.cancel();
    peer.retryTimer = null;
    peer.renderer.srcObject = null;
    try { await peer.pc.close(); } catch (_) { /* Best effort. */ }
    try { await peer.syntheticVideoStream?.dispose(); } catch (_) { /* Best effort. */ }
    try { await peer.renderer.dispose(); } catch (_) { /* Best effort. */ }
  }

  // Mesh sends a separate encoded stream to each remote participant.
  // Keep capture modest on mobile, especially in four-member rooms.
  Map<String, dynamic> _groupVideoConstraints(int memberCount) => {
    'facingMode': 'user',
    'width': memberCount >= 4 ? 480 : 640,
    'height': memberCount >= 4 ? 360 : 480,
    'frameRate': memberCount >= 4 ? 15 : 24,
  };

  Future<void> _prepareMedia(bool video) async {
    final generation = _generation;
    final roomId = _room!.roomId;
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? _groupVideoConstraints(_room!.members.length)
          : false,
    });
    if (!_isCurrent(generation, roomId)) {
      await stream.dispose();
      return;
    }
    _localStream = stream;
    if (video) _localRenderer?.srcObject = stream;
    final identity = await sessionManager.identityStore.getIdentityKeyPair();
    final registrationId =
        await sessionManager.identityStore.getLocalRegistrationId();
    if (!_isCurrent(generation, roomId)) return;
    final challenge = await directory.getTurnChallenge(
      nickname: _local, deviceId: 1, registrationId: registrationId,
    );
    if (!_isCurrent(generation, roomId)) return;
    final message = DirectoryClient.buildTurnAuthMessage(
      nickname: _local, deviceId: 1,
      registrationId: registrationId, challenge: challenge,
    );
    final signature = Curve.calculateSignature(
      identity.getPrivateKey(), Uint8List.fromList(utf8.encode(message)),
    );
    final response = await directory.getTurnCredentials(
      nickname: _local, deviceId: 1,
      registrationId: registrationId,
      challenge: challenge, signature: base64Encode(signature),
    );
    if (!_isCurrent(generation, roomId)) return;
    if (response['iceServers'] is! List ||
        (response['iceServers'] as List).isEmpty) {
      throw StateError('No TURN credentials for group call');
    }
    final servers = response['iceServers'] as List;
    // Do not accept malformed or non-ICE URLs from the credential endpoint.
    final validated = <Map<String, dynamic>>[];
    for (final entry in servers) {
      if (entry is! Map) throw StateError('Invalid ICE configuration');
      final rawUrls = entry['urls'];
      final urls = rawUrls is String ? [rawUrls] : rawUrls;
      if (urls is! List || urls.isEmpty ||
          urls.any((url) => url is! String ||
              !RegExp(r'^(stun|stuns|turn|turns):[^\s]+
  }

  Future<void> _send(String recipient, String type,
      [Map<String, dynamic> fields = const {}]) async {
    final room = _room;
    if (room == null) return;
    final recipientName = GroupCallProtocol.normalize(recipient);
    if (!room.members.contains(recipientName) || recipientName == _local) {
      throw StateError('Unauthorized group call recipient');
    }
    final generation = _generation;
    final identity = await sessionManager.identityStore.getIdentityKeyPair();
    if (!_isCurrent(generation, room.roomId)) return;
    final payload = <String, dynamic>{
      ...fields,
      'type': type,
      'roomId': room.roomId,
      'membersDigest': room.membersDigest,
      'callId': room.roomId,
      'chatId': room.chatId,
      'kind': room.video ? 'video' : 'voice',
      'sentAt': DateTime.now().millisecondsSinceEpoch,
      'recipient': recipientName,
    };
    final signature = CallSignalAuthenticator.sign(
      identityKeyPair: identity,
      recipient: recipientName,
      payload: payload,
    );
    await relay.sendCallSignal(
      recipient: recipientName,
      plaintext: Uint8List.fromList(utf8.encode(
        'STELLAR_CALL_V1:${jsonEncode({
          ...payload, 'signature': base64Encode(signature),
        })}',
      )),
    );
  }

  Future<void> toggleMute(bool muted) async {
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  Future<void> setSpeakerphone(bool enabled) => Helper.setSpeakerphoneOn(enabled);

  Future<void> switchCamera() async {
    final track = (_cameraCaptureStream ?? _localStream)
        ?.getVideoTracks().firstOrNull;
    if (track != null) await Helper.switchCamera(track);
  }

  Future<void> setVideoEnabled(bool enabled) async {
    final room = _room;
    if (room == null || !isActive || _changingVideo) return;
    if (room.localVideo == enabled) return;
    _changingVideo = true;
    final generation = _generation;
    MediaStream? newCapture;
    try {
      if (enabled) {
        newCapture = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': _groupVideoConstraints(room.members.length),
        });
        if (!_isCurrent(generation, room.roomId)) {
          return;
        }
      }
      final newTrack = enabled ? newCapture!.getVideoTracks().first : null;
      final previousTrack = (_cameraCaptureStream ?? _localStream)
          ?.getVideoTracks().firstOrNull;
      final updated = <_MeshPeer>[];
      try {
        for (final peer in _peers.values.toList()) {
          if (!_isCurrent(generation, room.roomId)) break;
          await peer.videoSender.replaceTrack(newTrack);
          updated.add(peer);
        }
      } catch (_) {
        for (final peer in updated) {
          try { await peer.videoSender.replaceTrack(previousTrack); } catch (_) { /* Recover in next transition. */ }
        }
        rethrow;
      }
      if (!_isCurrent(generation, room.roomId)) {
        return;
      }

      final oldCapture = _cameraCaptureStream;
      _cameraCaptureStream = newCapture;
      _room = _room!.copyWith(localVideo: enabled);
      unawaited(_groupForeground('startGroupForeground', room.roomId,
          video: enabled));
      _localRenderer?.srcObject = enabled ? (newCapture ?? _localStream) : null;
      _emit();
      if (oldCapture != null) {
        await oldCapture.dispose();
      } else if (!enabled) {
        for (final track in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
          await track.stop();
          await _localStream?.removeTrack(track);
        }
      }
      if (!_isCurrent(generation, room.roomId)) return;
      final revision = ++_mediaRevision;
      for (final remote in _room!.joined.toList()) {
        if (!_isCurrent(generation, room.roomId)) return;
        if (remote == _local) continue;
        try {
          await _send(remote, 'group-media', {
            'videoEnabled': enabled, 'mediaRevision': revision,
          });
        } catch (_) {
          print('GROUP_MEDIA_ANNOUNCE_FAILED');
        }
      }
    } finally {
      if (newCapture != null && !identical(_cameraCaptureStream, newCapture)) {
        try { await newCapture.dispose(); } catch (_) { /* Best effort. */ }
      }
      _changingVideo = false;
    }
  }

  Future<void> leaveRoom() async {
    final room = _room;
    if (room == null) return;
    final generation = _generation;
    if (room.phase == GroupCallPhase.ringing) {
      await declineInvitation();
      return;
    }
    if (room.phase != GroupCallPhase.ringing) {
      for (final remote in room.members) {
        if (!_isCurrent(generation, room.roomId)) return;
        if (remote == _local) continue;
        try {
          await _send(remote, 'group-leave')
              .timeout(const Duration(seconds: 2));
        } catch (_) { /* Local teardown is unconditional. */ }
      }
    }
    if (_isCurrent(generation, room.roomId)) await _closeRoom(room.roomId);
  }

  Future<void> _closeRoom(String roomId) async {
    if (_room?.roomId != roomId) return;
    ++_generation;
    if (_room?.phase != GroupCallPhase.ringing) {
      unawaited(_groupForeground('stopGroupForeground', roomId));
    }
    unawaited(_nativeInvitation('dismissInvitation', roomId));
    _invitationTimeout?.cancel();
    _invitationTimeout = null;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _room = null;
    _iceConfiguration = null;
    _earlyIce.clear();
    _remoteMediaRevisions.clear();
    _mediaRevision = 0;
    final peers = _peers.values.toList();
    _peers.clear();
    _creatingPeers.clear();
    _localRenderer?.srcObject = null;
    final capture = _cameraCaptureStream;
    final stream = _localStream;
    _cameraCaptureStream = null;
    _localStream = null;
    _emit();
    await Future.wait(peers.map(_disposePeer));
    try { await capture?.dispose(); } catch (_) { /* Best effort. */ }
    try { await stream?.dispose(); } catch (_) { /* Best effort. */ }
  }

  Future<void> dispose() async {
    _disposed = true;
    _nativeGroupCalls.setMethodCallHandler(null);
    await _subscription?.cancel();
    final room = _room;
    if (room != null) await _closeRoom(room.roomId);
    await _roomController.close();
  }
}

class _MeshPeer {
  _MeshPeer({
    required this.pc,
    required this.renderer,
    required this.videoSender,
  });
  final RTCPeerConnection pc;
  final RTCVideoRenderer renderer;
  final RTCRtpSender videoSender;
  MediaStream? syntheticVideoStream;
  RTCPeerConnectionState? connectionState;
  Timer? retryTimer;
  int retryCount = 0;
  bool restarting = false;
  int negotiation = 0;
  int remoteNegotiation = 0;
  bool offered = false;
  bool remoteDescriptionSet = false;
}
,
                  caseSensitive: false).hasMatch(url))) {
        throw StateError('Invalid ICE server URL');
      }
      validated.add(Map<String, dynamic>.from(entry));
    }
    _iceConfiguration = {'iceServers': validated};
  }

  Future<void> _send(String recipient, String type,
      [Map<String, dynamic> fields = const {}]) async {
    final room = _room;
    if (room == null) return;
    final recipientName = GroupCallProtocol.normalize(recipient);
    if (!room.members.contains(recipientName) || recipientName == _local) {
      throw StateError('Unauthorized group call recipient');
    }
    final identity = await sessionManager.identityStore.getIdentityKeyPair();
    if (_room?.roomId != room.roomId) return;
    final payload = <String, dynamic>{
      ...fields,
      'type': type,
      'roomId': room.roomId,
      'membersDigest': room.membersDigest,
      'callId': room.roomId,
      'chatId': room.chatId,
      'kind': room.video ? 'video' : 'voice',
      'sentAt': DateTime.now().millisecondsSinceEpoch,
      'recipient': recipientName,
    };
    final signature = CallSignalAuthenticator.sign(
      identityKeyPair: identity,
      recipient: recipientName,
      payload: payload,
    );
    await relay.sendCallSignal(
      recipient: recipientName,
      plaintext: Uint8List.fromList(utf8.encode(
        'STELLAR_CALL_V1:${jsonEncode({
          ...payload, 'signature': base64Encode(signature),
        })}',
      )),
    );
  }

  Future<void> toggleMute(bool muted) async {
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  Future<void> setSpeakerphone(bool enabled) => Helper.setSpeakerphoneOn(enabled);

  Future<void> switchCamera() async {
    final track = (_cameraCaptureStream ?? _localStream)
        ?.getVideoTracks().firstOrNull;
    if (track != null) await Helper.switchCamera(track);
  }

  Future<void> setVideoEnabled(bool enabled) async {
    final room = _room;
    if (room == null || !isActive || _changingVideo) return;
    if (room.localVideo == enabled) return;
    _changingVideo = true;
    final generation = _generation;
    MediaStream? newCapture;
    try {
      if (enabled) {
        newCapture = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': _groupVideoConstraints(room.members.length),
        });
        if (!_isCurrent(generation, room.roomId)) {
          await newCapture.dispose();
          return;
        }
      }
      final newTrack = enabled ? newCapture!.getVideoTracks().first : null;
      final previousTrack = (_cameraCaptureStream ?? _localStream)
          ?.getVideoTracks().firstOrNull;
      final updated = <_MeshPeer>[];
      try {
        for (final peer in _peers.values) {
          await peer.videoSender.replaceTrack(newTrack);
          updated.add(peer);
        }
      } catch (_) {
        for (final peer in updated) {
          try { await peer.videoSender.replaceTrack(previousTrack); } catch (_) { /* Recover in next transition. */ }
        }
        rethrow;
      }
      if (!_isCurrent(generation, room.roomId)) {
        await newCapture?.dispose();
        return;
      }

      final oldCapture = _cameraCaptureStream;
      _cameraCaptureStream = newCapture;
      _room = _room!.copyWith(localVideo: enabled);
      unawaited(_groupForeground('startGroupForeground', room.roomId,
          video: enabled));
      _localRenderer?.srcObject = enabled ? (newCapture ?? _localStream) : null;
      _emit();
      if (oldCapture != null) {
        await oldCapture.dispose();
      } else if (!enabled) {
        for (final track in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
          await track.stop();
          await _localStream?.removeTrack(track);
        }
      }
      final revision = ++_mediaRevision;
      for (final remote in _room!.joined) {
        if (remote == _local) continue;
        try {
          await _send(remote, 'group-media', {
            'videoEnabled': enabled, 'mediaRevision': revision,
          });
        } catch (_) {
          print('GROUP_MEDIA_ANNOUNCE_FAILED');
        }
      }
    } finally {
      _changingVideo = false;
    }
  }

  Future<void> leaveRoom() async {
    final room = _room;
    if (room == null) return;
    if (room.phase == GroupCallPhase.ringing) {
      await declineInvitation();
      return;
    }
    if (room.phase != GroupCallPhase.ringing) {
      for (final remote in room.members) {
        if (remote == _local) continue;
        try {
          await _send(remote, 'group-leave')
              .timeout(const Duration(seconds: 2));
        } catch (_) { /* Local teardown is unconditional. */ }
      }
    }
    await _closeRoom(room.roomId);
  }

  Future<void> _closeRoom(String roomId) async {
    if (_room?.roomId != roomId) return;
    ++_generation;
    if (_room?.phase != GroupCallPhase.ringing) {
      unawaited(_groupForeground('stopGroupForeground', roomId));
    }
    unawaited(_nativeInvitation('dismissInvitation', roomId));
    _invitationTimeout?.cancel();
    _invitationTimeout = null;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _room = null;
    _iceConfiguration = null;
    _earlyIce.clear();
    _remoteMediaRevisions.clear();
    _mediaRevision = 0;
    final peers = _peers.values.toList();
    _peers.clear();
    _creatingPeers.clear();
    _localRenderer?.srcObject = null;
    final capture = _cameraCaptureStream;
    final stream = _localStream;
    _cameraCaptureStream = null;
    _localStream = null;
    _emit();
    await Future.wait(peers.map(_disposePeer));
    try { await capture?.dispose(); } catch (_) { /* Best effort. */ }
    try { await stream?.dispose(); } catch (_) { /* Best effort. */ }
  }

  Future<void> dispose() async {
    _disposed = true;
    _nativeGroupCalls.setMethodCallHandler(null);
    await _subscription?.cancel();
    final room = _room;
    if (room != null) await _closeRoom(room.roomId);
    await _roomController.close();
  }
}

class _MeshPeer {
  _MeshPeer({
    required this.pc,
    required this.renderer,
    required this.videoSender,
  });
  final RTCPeerConnection pc;
  final RTCVideoRenderer renderer;
  final RTCRtpSender videoSender;
  MediaStream? syntheticVideoStream;
  RTCPeerConnectionState? connectionState;
  Timer? retryTimer;
  int retryCount = 0;
  bool restarting = false;
  String? lastRemoteOffer;
  bool offered = false;
  bool remoteDescriptionSet = false;
}
