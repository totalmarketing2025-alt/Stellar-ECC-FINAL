import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Plays local ringback/ringtone only on Windows. Android keeps its existing
/// native audio implementation, and iOS remains untouched.
class WindowsCallAudioService {
  WindowsCallAudioService._();

  static final WindowsCallAudioService instance = WindowsCallAudioService._();

  final AudioPlayer _player = AudioPlayer(playerId: 'stellar-windows-call');
  final Map<String, Future<File>> _ringFiles = <String, Future<File>>{};
  String? _activeCallId;

  Future<void> startOutgoingRingback(String callId) =>
      _start(callId, incoming: false);

  Future<void> startIncomingRingtone(String callId) =>
      _start(callId, incoming: true);

  Future<void> _start(String callId, {required bool incoming}) async {
    if (!Platform.isWindows || callId.isEmpty) return;
    try {
      _activeCallId = callId;
      await _player.stop();
      if (_activeCallId != callId) return;
      final ringFile = await _ringFile(incoming);
      if (_activeCallId != callId) return;
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(0.55);
      if (_activeCallId != callId) return;
      await _player.play(DeviceFileSource(ringFile.path));
    } catch (error) {
      print('WINDOWS_CALL_AUDIO_START_FAILED: $error');
    }
  }

  Future<void> stop(String callId) async {
    if (!Platform.isWindows || callId.isEmpty || _activeCallId != callId) {
      return;
    }
    _activeCallId = null;
    try {
      await _player.stop();
    } catch (error) {
      print('WINDOWS_CALL_AUDIO_STOP_FAILED: $error');
    }
  }

  Future<File> _ringFile(bool incoming) {
    final name = incoming ? 'incoming.wav' : 'outgoing.wav';
    return _ringFiles.putIfAbsent(name, () async {
      final temporaryDirectory = await getTemporaryDirectory();
      final ringDirectory = Directory(
        path.join(temporaryDirectory.path, 'Stellar ECC', 'call-audio'),
      );
      await ringDirectory.create(recursive: true);
      final ringFile = File(path.join(ringDirectory.path, name));
      if (!await ringFile.exists()) {
        final sections = incoming
            ? <(double, List<double>, double)>[
                (0.38, <double>[523.25, 659.25], 0.28),
                (0.16, <double>[], 0),
                (0.38, <double>[659.25, 783.99], 0.28),
                (1.35, <double>[], 0),
              ]
            : <(double, List<double>, double)>[
                (1.8, <double>[440.0, 480.0], 0.20),
                (3.2, <double>[], 0),
              ];
        await ringFile.writeAsBytes(_encodeWave(sections), flush: true);
      }
      return ringFile;
    });
  }

  Uint8List _encodeWave(List<(double, List<double>, double)> sections) {
    const sampleRate = 22050;
    final sampleCount = sections.fold<int>(
      0,
      (count, section) => count + (sampleRate * section.$1).round(),
    );
    final dataLength = sampleCount * 2;
    final bytes = ByteData(44 + dataLength);
    void writeFourCc(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeFourCc(0, 'RIFF');
    bytes.setUint32(4, 36 + dataLength, Endian.little);
    writeFourCc(8, 'WAVE');
    writeFourCc(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    writeFourCc(36, 'data');
    bytes.setUint32(40, dataLength, Endian.little);

    var offset = 44;
    for (final section in sections) {
      final duration = section.$1;
      final frequencies = section.$2;
      final gain = section.$3;
      final sectionSamples = (sampleRate * duration).round();
      for (var i = 0; i < sectionSamples; i++) {
        final edgeIn = i / (sampleRate * 0.025);
        final edgeOut = (sectionSamples - i - 1) / (sampleRate * 0.05);
        final envelope = math.min(1.0, math.min(edgeIn, edgeOut));
        var sample = 0.0;
        for (final frequency in frequencies) {
          sample += math.sin(2 * math.pi * frequency * i / sampleRate);
        }
        if (frequencies.isNotEmpty) sample /= frequencies.length;
        bytes.setInt16(
          offset,
          (32767 * gain * envelope * sample)
              .round()
              .clamp(-32768, 32767)
              .toInt(),
          Endian.little,
        );
        offset += 2;
      }
    }
    return bytes.buffer.asUint8List();
  }
}
