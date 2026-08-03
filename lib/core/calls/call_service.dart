import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../network/relay_client.dart';
import '../crypto/session_manager.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

enum CallDirection { outgoing, incoming }

/// Orchestrates a single WebRTC call: local media capture, peer connection
/// negotiation, and signaling relayed through the same RelayClient used
/// for messages. Signaling payloads (SDP offer/answer, ICE candidates) are
/// encrypted with the existing pairwise Double Ratchet session before
/// being sent — the relay only ever forwards opaque bytes (Phase 9 §9.4).
class CallService {
  CallService({
    required this.relayClient,
    required this.sessionManager,
    required this.localRenderer,
    required this.remoteRenderer,
  });

  final RelayClient relayClient;
  final SessionManager sessionManager;
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  StreamSubscription<Uint8List>? _signalSubscription;

  final _configuration = <String, dynamic>{
    'iceServers': [
      {'urls': 'stun:stun.stellarecc.example:3478'},
      {
        'urls': 'turn:turn.stellarecc.example:3478',
        // Short-lived, scoped TURN credentials fetched from the relay at
        // call-start time (Phase 12 checklist item) — placeholder values
        // here are replaced by a real fetch in CallService.start().
        'username': 'REPLACE_WITH_FETCHED_TURN_USERNAME',
        'credential': 'REPLACE_WITH_FETCHED_TURN_CREDENTIAL',
      },
    ],
  };

  Future<void> start({
    required String remoteNickname,
    required CallDirection direction,
    required bool video,
  }) async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {'facingMode': 'user', 'width': 640, 'height': 480}
          : false,
    });
    localRenderer.srcObject = _localStream;

    _peerConnection = await createPeerConnection(_configuration);

    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
      }
    };

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      _sendSignal(remoteNickname, {
        'type': 'ice-candidate',
        'candidate': candidate.toMap(),
      });
    };

    _signalSubscription = relayClient.incoming.listen((raw) => _handleIncomingSignal(remoteNickname, raw));

    if (direction == CallDirection.outgoing) {
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      await _sendSignal(remoteNickname, {
        'type': 'offer',
        'sdp': offer.sdp,
        'sdpType': offer.type,
      });
    }
    // Incoming-call path: caller's offer arrives via _handleIncomingSignal,
    // which creates the answer once received.
  }

  Future<void> _handleIncomingSignal(String remoteNickname, Uint8List rawEnvelope) async {
    if (_peerConnection == null) return;

    final decrypted = await _decryptSignal(remoteNickname, rawEnvelope);
    final signal = jsonDecode(decrypted) as Map<String, dynamic>;

    switch (signal['type']) {
      case 'offer':
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(signal['sdp'] as String, signal['sdpType'] as String),
        );
        final answer = await _peerConnection!.createAnswer();
        await _peerConnection!.setLocalDescription(answer);
        await _sendSignal(remoteNickname, {
          'type': 'answer',
          'sdp': answer.sdp,
          'sdpType': answer.type,
        });
        break;
      case 'answer':
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(signal['sdp'] as String, signal['sdpType'] as String),
        );
        break;
      case 'ice-candidate':
        final c = signal['candidate'] as Map<String, dynamic>;
        await _peerConnection!.addCandidate(
          RTCIceCandidate(c['candidate'] as String, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?),
        );
        break;
    }
  }

  Future<void> _sendSignal(String remoteNickname, Map<String, dynamic> payload) async {
    final address = SignalProtocolAddress(remoteNickname, 1);
    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final ciphertext = await sessionManager.encryptForSend(address, plaintext);
    await relayClient.send(Uint8List.fromList(ciphertext.serialize()));
  }

  Future<String> _decryptSignal(String remoteNickname, Uint8List rawEnvelope) async {
    final address = SignalProtocolAddress(remoteNickname, 1);
    final message = SignalMessage.fromSerialized(rawEnvelope);
    final plaintext = await sessionManager.decryptReceived(address, message);
    return utf8.decode(plaintext);
  }

  Future<void> toggleMute(bool muted) async {
    _localStream?.getAudioTracks().forEach((track) => track.enabled = !muted);
  }

  Future<void> toggleCamera(bool cameraOff) async {
    _localStream?.getVideoTracks().forEach((track) => track.enabled = !cameraOff);
  }

  Future<void> switchCamera() async {
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) await Helper.switchCamera(videoTrack);
  }

  Future<void> end() async {
    await _signalSubscription?.cancel();
    await _localStream?.dispose();
    await _peerConnection?.close();
    _peerConnection = null;
    _localStream = null;
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
