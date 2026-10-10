import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../crypto/session_manager.dart';
import '../network/directory_client.dart';
import '../network/relay_client.dart';
import '../../domain/models/call_session.dart';
import 'call_platform_bridge.dart';
import 'call_signal_authenticator.dart';

enum CallDirection { outgoing, incoming }

class CallService {
  CallService({
    required this.relayClient,
    required this.sessionManager,
    required this.platformBridge,
    required this.directoryClient,
    required this.localNickname,
    this.localRenderer,
    this.remoteRenderer,
  });

  final RelayClient relayClient;
  final SessionManager sessionManager;
  final CallPlatformBridge platformBridge;
  final DirectoryClient directoryClient;
  final String localNickname;
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  String? _callId;
  String? _chatId;
  CallKind? _callKind;

  // Invalidates asynchronous work belonging to an older call lifecycle.
  int _callGeneration = 0;

  bool _isCurrentGeneration(int generation) {
    return generation == _callGeneration;
  }

  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingIceCandidates = [];

  void Function(RTCPeerConnectionState state)? onConnectionStateChanged;

  static const _signalPrefix = 'STELLAR_CALL_V1:';

  Future<Map<String, dynamic>> _buildIceConfiguration() async {
    final response = await _fetchIceServers(
      localNickname: localNickname,
    );

    final iceServers = response['iceServers'];
    if (iceServers is! List || iceServers.isEmpty) {
      throw const FormatException(
        'Invalid ICE servers returned by Directory',
      );
    }

    return <String, dynamic>{
      'iceServers': iceServers,
    };
  }

  String? get callId => _callId;
  String? get chatId => _chatId;
  CallKind? get callKind => _callKind;

  void attachRenderers({
    RTCVideoRenderer? local,
    RTCVideoRenderer? remote,
  }) {
    if (local != null) {
      localRenderer = local;
      local.srcObject = _localStream;
    }

    if (remote != null) {
      remoteRenderer = remote;
      remote.srcObject = _remoteStream;
    }
  }

  Future<Map<String, dynamic>> _fetchIceServers({
    required String localNickname,
  }) async {
    final nickname = localNickname.trim().toLowerCase();
    final identityKeyPair =
        await sessionManager.identityStore.getIdentityKeyPair();
    final registrationId =
        await sessionManager.identityStore.getLocalRegistrationId();
    const deviceId = 1;

    final challenge = await directoryClient.getTurnChallenge(
      nickname: nickname,
      deviceId: deviceId,
      registrationId: registrationId,
    );

    final message = DirectoryClient.buildTurnAuthMessage(
      nickname: nickname,
      deviceId: deviceId,
      registrationId: registrationId,
      challenge: challenge,
    );

    final signature = Curve.calculateSignature(
      identityKeyPair.getPrivateKey(),
      Uint8List.fromList(utf8.encode(message)),
    );

    return directoryClient.getTurnCredentials(
      nickname: nickname,
      deviceId: deviceId,
      registrationId: registrationId,
      challenge: challenge,
      signature: base64Encode(signature),
    );
  }

  Future<void> start({
    required String remoteNickname,
    required CallDirection direction,
    required bool video,
    String? callId,
    String? chatId,
  }) async {
    final generation = ++_callGeneration;
    var phase = 'initialize';

    try {
      _callId ??= callId ?? _generateCallId();
      _chatId ??= chatId;
      _callKind = video ? CallKind.video : CallKind.voice;

      print(
        'CALL_START_BEGIN: direction=$direction '
        'video=$video callId=$_callId',
      );

      phase = 'getUserMedia';
      final acquiredStream =
          await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video
            ? {'facingMode': 'user', 'width': 640, 'height': 480}
            : false,
      });

      if (!_isCurrentGeneration(generation)) {
        await acquiredStream.dispose();
        return;
      }

      _localStream = acquiredStream;

      print('CALL_START_MEDIA_OK: callId=$_callId');

      localRenderer?.srcObject = _localStream;

      phase = 'buildIceConfiguration';
      final iceConfiguration = await _buildIceConfiguration();

      if (!_isCurrentGeneration(generation)) return;

      print('CALL_START_ICE_CONFIG_OK: callId=$_callId');

      phase = 'createPeerConnection';
      final acquiredPeerConnection =
          await createPeerConnection(iceConfiguration);

      if (!_isCurrentGeneration(generation)) {
        await acquiredPeerConnection.close();
        return;
      }

      _peerConnection = acquiredPeerConnection;

      print('CALL_START_PEER_OK: callId=$_callId');

      phase = 'addLocalTracks';
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
        if (!_isCurrentGeneration(generation)) return;
      }

      print(
        'CALL_START_TRACKS_OK: callId=$_callId '
        'tracks=${_localStream!.getTracks().length}',
      );

      phase = 'attachPeerCallbacks';

      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (!_isCurrentGeneration(generation) ||
            _peerConnection != acquiredPeerConnection) {
          return;
        }

        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams.first;
          remoteRenderer?.srcObject = _remoteStream;
        }
      };

      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (!_isCurrentGeneration(generation) ||
            _peerConnection != acquiredPeerConnection) {
          return;
        }

        unawaited(
          _sendSignal(remoteNickname, {
            'type': 'ice-candidate',
            'candidate': candidate.toMap(),
          }),
        );
      };

      _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
        if (!_isCurrentGeneration(generation) ||
            _peerConnection != acquiredPeerConnection) {
          return;
        }

        print('CALL_CONNECTION_STATE: $state');

        onConnectionStateChanged?.call(state);

        final callId = _callId;
        if (callId == null || callId.isEmpty) {
          return;
        }

        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            unawaited(platformBridge.setCallActive(callId));
            break;

          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            unawaited(platformBridge.setCallEnded(callId));
            break;

          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            // A disconnected WebRTC state can be transient.
            // Do not mark the native call as ended until the connection
            // actually fails or closes.
            break;

          default:
            break;
        }
      };

      print('CALL_START_CALLBACKS_OK: callId=$_callId');

      if (direction == CallDirection.outgoing) {
        phase = 'createOffer';
        final offer = await _peerConnection!.createOffer();

        if (!_isCurrentGeneration(generation)) return;

        print('CALL_START_OFFER_CREATED: callId=$_callId');

        phase = 'setLocalDescription';
        await _peerConnection!.setLocalDescription(offer);

        if (!_isCurrentGeneration(generation)) return;

        print('CALL_START_LOCAL_DESCRIPTION_OK: callId=$_callId');

        phase = 'sendOffer';
        await _sendSignal(remoteNickname, {
          'type': 'offer',
          'sdp': offer.sdp,
          'sdpType': offer.type,
        });

        if (!_isCurrentGeneration(generation)) return;

        print('CALL_START_OFFER_SENT: callId=$_callId');
      }

      print(
        'CALL_START_SUCCESS: direction=$direction '
        'callId=$_callId',
      );
    } catch (error, stackTrace) {
      print(
        'CALL_START_FAILED: phase=$phase '
        'direction=$direction callId=$_callId error=$error',
      );
      print('CALL_START_STACK: $stackTrace');

      if (_isCurrentGeneration(generation)) {
        await _cleanupAfterStartFailure(generation);
      }

      rethrow;
    }
  }

  Future<void> _cleanupAfterStartFailure(int generation) async {
    if (!_isCurrentGeneration(generation)) return;

    final failedCallId = _callId;
    final localStream = _localStream;
    final peerConnection = _peerConnection;

    // Detach this failed call before awaiting cleanup.
    // A new call can safely start while these resources are closing.
    _callGeneration++;
    _localStream = null;
    _remoteStream = null;
    _peerConnection = null;
    _remoteDescriptionSet = false;
    _pendingIceCandidates.clear();
    _callId = null;
    _chatId = null;
    _callKind = null;

    localRenderer?.srcObject = null;
    remoteRenderer?.srcObject = null;

    print('CALL_START_CLEANUP_BEGIN: callId=$failedCallId');

    try {
      await localStream?.dispose();
    } catch (error) {
      print('CALL_START_CLEANUP_STREAM_FAILED: $error');
    }

    try {
      await peerConnection?.close();
    } catch (error) {
      print('CALL_START_CLEANUP_PEER_FAILED: $error');
    }

    if (failedCallId != null && failedCallId.isNotEmpty) {
      try {
        await platformBridge.setCallEnded(failedCallId);
      } catch (error) {
        print('CALL_START_CLEANUP_NATIVE_FAILED: $error');
      }
    }

    print('CALL_START_CLEANUP_DONE: callId=$failedCallId');
  }


  Future<void> handleSignal({
    required String remoteNickname,
    required Map<String, dynamic> signal,
  }) async {
    final generation = _callGeneration;
    final peerConnection = _peerConnection;
    final activeCallId = _callId;

    if (peerConnection == null || activeCallId == null) {
      throw StateError('Call peer connection is not initialized');
    }

    final signalCallId = signal['callId'];
    if (signalCallId is! String ||
        signalCallId.isEmpty ||
        signalCallId != activeCallId) {
      throw StateError('Call signal callId mismatch');
    }

    final signalKind = signal['kind'];
    final expectedKind = _callKind == CallKind.video ? 'video' : 'voice';

    if (signalKind != expectedKind) {
      throw StateError('Call signal kind mismatch');
    }

    bool stillCurrent() =>
        _isCurrentGeneration(generation) &&
        _peerConnection == peerConnection &&
        _callId == activeCallId;

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
        if (!stillCurrent()) return;

        _remoteDescriptionSet = true;
        await _flushPendingIceCandidates(peerConnection, generation);
        if (!stillCurrent()) return;

        final answer = await peerConnection.createAnswer();
        if (!stillCurrent()) return;

        await peerConnection.setLocalDescription(answer);
        if (!stillCurrent()) return;

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
        if (!stillCurrent()) return;

        _remoteDescriptionSet = true;
        await _flushPendingIceCandidates(peerConnection, generation);
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

        if (!stillCurrent()) return;

        if (!_remoteDescriptionSet) {
          _pendingIceCandidates.add(iceCandidate);
        } else {
          await peerConnection.addCandidate(iceCandidate);
        }
        break;

      case 'reject':
        if (!stillCurrent()) return;
        print('CALL_REJECTED: $activeCallId');
        await end();
        break;

      case 'end':
        if (!stillCurrent()) return;
        print('CALL_ENDED_REMOTE: $activeCallId');
        await end();
        break;

      default:
        throw StateError('Unknown Stellar call signal type: $type');
    }
  }

  Future<void> _flushPendingIceCandidates(
    RTCPeerConnection peerConnection,
    int generation,
  ) async {
    if (!_isCurrentGeneration(generation) ||
        _peerConnection != peerConnection ||
        _pendingIceCandidates.isEmpty) {
      return;
    }

    final pending = List<RTCIceCandidate>.from(_pendingIceCandidates);
    _pendingIceCandidates.clear();

    for (final candidate in pending) {
      if (!_isCurrentGeneration(generation) ||
          _peerConnection != peerConnection) {
        return;
      }
      await peerConnection.addCandidate(candidate);
    }
  }

  Future<void> _sendSignal(
    String remoteNickname,
    Map<String, dynamic> signal,
  ) async {
    final generation = _callGeneration;
    final callId = _callId;
    final chatId = _chatId;
    final callKind = _callKind;

    if (callId == null || callKind == null) {
      throw StateError('Call session identity is not initialized');
    }

    final identityKeyPair =
        await sessionManager.identityStore.getIdentityKeyPair();

    if (!_isCurrentGeneration(generation) || _callId != callId) {
      return;
    }

    final recipient = remoteNickname.trim().toLowerCase();
    final payload = <String, dynamic>{
      ...signal,
      'callId': callId,
      'chatId': chatId,
      'kind': callKind == CallKind.video ? 'video' : 'voice',
      'sentAt': DateTime.now().millisecondsSinceEpoch,
      'recipient': recipient,
    };

    final signature = CallSignalAuthenticator.sign(
      identityKeyPair: identityKeyPair,
      recipient: recipient,
      payload: payload,
    );

    final authenticatedPayload = <String, dynamic>{
      ...payload,
      'signature': base64Encode(signature),
    };

    final plaintext = Uint8List.fromList(
      utf8.encode('$_signalPrefix${jsonEncode(authenticatedPayload)}'),
    );

    if (!_isCurrentGeneration(generation) || _callId != callId) {
      return;
    }

    // Call signaling intentionally bypasses the message E2E layer.
    // The payload is cryptographically authenticated with the local
    // Signal identity key.
    await relayClient.sendCallSignal(
      recipient: remoteNickname,
      plaintext: plaintext,
    );

    if (signal['type'] == 'offer' &&
        _isCurrentGeneration(generation) &&
        _callId == callId) {
      try {
        await relayClient.sendCallWake(
          recipient: remoteNickname,
          callId: callId,
          kind: callKind == CallKind.video ? 'video' : 'voice',
          chatId: chatId,
        );
      } catch (error, stackTrace) {
        print('CALL_WAKE_FAILED: $error');
        print('CALL_WAKE_STACK: $stackTrace');
      }
    }
  }

  Future<void> reject(
    String remoteNickname, {
    String? callId,
    String? chatId,
    CallKind? kind,
  }) async {
    // Never reject a different call that became active in the meantime.
    if (_callId != null && callId != null && _callId != callId) {
      print('CALL_REJECT_IGNORED: active call ID mismatch');
      return;
    }

    if (_callKind != null && kind != null && _callKind != kind) {
      print('CALL_REJECT_IGNORED: active call kind mismatch');
      return;
    }

    final effectiveCallId = _callId ?? callId;
    final effectiveCallKind = _callKind ?? kind;

    if (effectiveCallId == null || effectiveCallKind == null) {
      return;
    }

    _callId ??= effectiveCallId;
    _chatId ??= chatId;
    _callKind ??= effectiveCallKind;

    final generation = _callGeneration;
    final rejectedCallId = _callId;

    await _sendSignal(remoteNickname, {'type': 'reject'});

    // Relay work may finish after this call has already been replaced.
    if (!_isCurrentGeneration(generation) ||
        _callId != rejectedCallId) {
      return;
    }

    await end();
  }

  Future<void> endForRemote(String remoteNickname) async {
    if (remoteNickname.isEmpty) {
      await end();
      return;
    }

    final generation = _callGeneration;
    final callId = _callId;
    final callKind = _callKind;

    if (callId != null && callId.isNotEmpty && callKind != null) {
      try {
        await _sendSignal(remoteNickname, {'type': 'end'});
      } catch (error) {
        print('CALL_END_SIGNAL_FAILED: $error');
      }
    }

    // Do not let delayed cleanup terminate a replacement call.
    if (!_isCurrentGeneration(generation) || _callId != callId) {
      return;
    }

    await end();
  }

  Future<void> end() async {
    // Invalidate outstanding start operations before releasing resources.
    _callGeneration++;

    final callId = _callId;
    final localStream = _localStream;
    final peerConnection = _peerConnection;

    // Reset Dart state even if a native or WebRTC cleanup operation fails.
    _localStream = null;
    _remoteStream = null;
    _peerConnection = null;
    _remoteDescriptionSet = false;
    _pendingIceCandidates.clear();
    _callId = null;
    _chatId = null;
    _callKind = null;

    localRenderer?.srcObject = null;
    remoteRenderer?.srcObject = null;

    try {
      await localStream?.dispose();
    } catch (error) {
      print('CALL_END_STREAM_CLEANUP_FAILED: $error');
    }

    try {
      await peerConnection?.close();
    } catch (error) {
      print('CALL_END_PEER_CLEANUP_FAILED: $error');
    }

    if (callId != null && callId.isNotEmpty) {
      try {
        await platformBridge.setCallEnded(callId);
      } catch (error) {
        print('CALL_END_NATIVE_CLEANUP_FAILED: $error');
      }
    }
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

  Future<void> setSpeakerphone(bool enabled) async {
    await Helper.setSpeakerphoneOn(enabled);
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
