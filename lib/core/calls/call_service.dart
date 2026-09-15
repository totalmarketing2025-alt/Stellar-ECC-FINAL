import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../crypto/session_manager.dart';
import '../network/envelope.dart';
import '../network/relay_client.dart';
import '../../domain/models/call_session.dart';
import 'call_platform_bridge.dart';

enum CallDirection { outgoing, incoming }

class CallService {
  CallService({
    required this.relayClient,
    required this.sessionManager,
    required this.platformBridge,
    this.localRenderer,
    this.remoteRenderer,
  });

  final RelayClient relayClient;
  final SessionManager sessionManager;
  final CallPlatformBridge platformBridge;
  final RTCVideoRenderer? localRenderer;
  final RTCVideoRenderer? remoteRenderer;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  String? _callId;
  String? _chatId;
  CallKind? _callKind;

  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingIceCandidates = [];

  static const _signalPrefix = 'STELLAR_CALL_V1:';

  final _configuration = <String, dynamic>{
    'iceServers': [
      {'urls': 'stun:stun.stellarecc.example:3478'},
      {
        'urls': 'turn:turn.stellarecc.example:3478',
        'username': 'REPLACE_WITH_FETCHED_TURN_USERNAME',
        'credential': 'REPLACE_WITH_FETCHED_TURN_CREDENTIAL',
      },
    ],
  };

  String? get callId => _callId;
  String? get chatId => _chatId;
  CallKind? get callKind => _callKind;

  Future<void> start({
    required String remoteNickname,
    required CallDirection direction,
    required bool video,
    String? callId,
    String? chatId,
  }) async {
    _callId ??= callId ?? _generateCallId();
    _chatId ??= chatId;
    _callKind = video ? CallKind.video : CallKind.voice;

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {'facingMode': 'user', 'width': 640, 'height': 480}
          : false,
    });

    localRenderer?.srcObject = _localStream;

    _peerConnection = await createPeerConnection(_configuration);

    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer?.srcObject = event.streams.first;
      }
    };

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      unawaited(
        _sendSignal(remoteNickname, {
          'type': 'ice-candidate',
          'candidate': candidate.toMap(),
        }),
      );
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      print('CALL_CONNECTION_STATE: $state');

      final callId = _callId;
      if (callId == null || callId.isEmpty) {
        return;
      }

      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          unawaited(platformBridge.setCallActive(callId));
          break;

        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          unawaited(platformBridge.setCallEnded(callId));
          break;

        default:
          break;
      }
    };

    if (direction == CallDirection.outgoing) {
      final offer = await _peerConnection!.createOffer();

      await _peerConnection!.setLocalDescription(offer);

      await _sendSignal(remoteNickname, {
        'type': 'offer',
        'sdp': offer.sdp,
        'sdpType': offer.type,
      });
    }
  }

  Future<void> handleSignal({
    required String remoteNickname,
    required Map<String, dynamic> signal,
  }) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      throw StateError('Call peer connection is not initialized');
    }

    final signalCallId = signal['callId'];
    if (signalCallId is! String ||
        signalCallId.isEmpty ||
        signalCallId != _callId) {
      throw StateError('Call signal callId mismatch');
    }

    final signalKind = signal['kind'];
    final expectedKind = _callKind == CallKind.video ? 'video' : 'voice';

    if (signalKind != expectedKind) {
      throw StateError('Call signal kind mismatch');
    }

    final type = signal['type'];

    switch (type) {
      case 'offer':
        final sdp = signal['sdp'];
        final sdpType = signal['sdpType'];

        if (sdp is! String ||
            sdp.isEmpty ||
            sdpType is! String ||
            sdpType.isEmpty) {
          throw StateError('Invalid call offer');
        }

        await peerConnection.setRemoteDescription(
          RTCSessionDescription(sdp, sdpType),
        );

        _remoteDescriptionSet = true;
        await _flushPendingIceCandidates(peerConnection);

        final answer = await peerConnection.createAnswer();

        await peerConnection.setLocalDescription(answer);

        await _sendSignal(remoteNickname, {
          'type': 'answer',
          'sdp': answer.sdp,
          'sdpType': answer.type,
        });
        break;

      case 'answer':
        final sdp = signal['sdp'];
        final sdpType = signal['sdpType'];

        if (sdp is! String ||
            sdp.isEmpty ||
            sdpType is! String ||
            sdpType.isEmpty) {
          throw StateError('Invalid call answer');
        }

        await peerConnection.setRemoteDescription(
          RTCSessionDescription(sdp, sdpType),
        );

        _remoteDescriptionSet = true;
        await _flushPendingIceCandidates(peerConnection);
        break;

      case 'ice-candidate':
        final rawCandidate = signal['candidate'];

        if (rawCandidate is! Map) {
          throw StateError('Invalid ICE candidate payload');
        }

        final candidate = <String, dynamic>{
          for (final entry in rawCandidate.entries)
            entry.key.toString(): entry.value,
        };

        final candidateValue = candidate['candidate'];

        if (candidateValue is! String || candidateValue.isEmpty) {
          throw StateError('Invalid ICE candidate');
        }

        final iceCandidate = RTCIceCandidate(
          candidateValue,
          candidate['sdpMid'] as String?,
          candidate['sdpMLineIndex'] as int?,
        );

        if (!_remoteDescriptionSet) {
          _pendingIceCandidates.add(iceCandidate);
        } else {
          await peerConnection.addCandidate(iceCandidate);
        }
        break;

      case 'reject':
        print('CALL_REJECTED: $_callId');
        await end();
        break;

      case 'end':
        print('CALL_ENDED_REMOTE: $_callId');
        await end();
        break;

      default:
        throw StateError('Unknown Stellar call signal type: $type');
    }
  }

  Future<void> _flushPendingIceCandidates(
    RTCPeerConnection peerConnection,
  ) async {
    if (_pendingIceCandidates.isEmpty) {
      return;
    }

    final pending = List<RTCIceCandidate>.from(_pendingIceCandidates);
    _pendingIceCandidates.clear();

    for (final candidate in pending) {
      await peerConnection.addCandidate(candidate);
    }
  }

  Future<void> _sendSignal(
    String remoteNickname,
    Map<String, dynamic> signal,
  ) async {
    final callId = _callId;
    final callKind = _callKind;

    if (callId == null || callKind == null) {
      throw StateError('Call session identity is not initialized');
    }

    final payload = <String, dynamic>{
      ...signal,
      'callId': callId,
      'chatId': _chatId,
      'kind': callKind == CallKind.video ? 'video' : 'voice',
    };

    final plaintext = Uint8List.fromList(
      utf8.encode('$_signalPrefix${jsonEncode(payload)}'),
    );

    final address = SignalProtocolAddress(remoteNickname, 1);

    final ciphertext = await sessionManager.encryptForSend(address, plaintext);

    final deliveryToken = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );

    final envelope = Envelope(
      deliveryToken: deliveryToken,
      recipientRoute: remoteNickname,
      ciphertext: Uint8List.fromList(ciphertext.serialize()),
    );

    await relayClient.send(envelope.encode());

    if (signal['type'] == 'offer') {
      await relayClient.sendCallWake(
        recipient: remoteNickname,
        callId: callId,
        kind: callKind == CallKind.video ? 'video' : 'voice',
        chatId: _chatId,
      );
    }
  }

  Future<void> reject(
    String remoteNickname, {
    String? callId,
    String? chatId,
    CallKind? kind,
  }) async {
    final effectiveCallId = _callId ?? callId;
    final effectiveCallKind = _callKind ?? kind;

    if (effectiveCallId == null || effectiveCallKind == null) {
      return;
    }

    _callId ??= effectiveCallId;
    _chatId ??= chatId;
    _callKind ??= effectiveCallKind;

    await _sendSignal(remoteNickname, {'type': 'reject'});

    await end();
  }

  Future<void> end() async {
    final callId = _callId;

    await _localStream?.dispose();
    await _peerConnection?.close();

    if (callId != null && callId.isNotEmpty) {
      await platformBridge.setCallEnded(callId);
    }

    _localStream = null;
    _peerConnection = null;
    _remoteDescriptionSet = false;
    _pendingIceCandidates.clear();
  }

  Future<void> toggleMute(bool muted) async {
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  Future<void> toggleCamera(bool cameraOff) async {
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !cameraOff;
    }
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];

    if (tracks.isNotEmpty) {
      await Helper.switchCamera(tracks.first);
    }
  }

  String _generateCallId() {
    final random = Random.secure();

    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
