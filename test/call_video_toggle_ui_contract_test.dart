import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final voiceScreen =
      File('lib/presentation/screens/calls/voice_call_screen.dart')
          .readAsStringSync();
  final videoScreen =
      File('lib/presentation/screens/calls/video_call_screen.dart')
          .readAsStringSync();
  final controlDock =
      File('lib/presentation/widgets/call_control_dock.dart')
          .readAsStringSync();

  test('voice and video call screens keep the camera toggle visible', () {
    expect(voiceScreen, contains('showCameraControls: true'));
    expect(videoScreen, contains('showCameraControls: true'));
    expect(voiceScreen, contains('onToggleCamera: _toggleVideo'));
    expect(videoScreen, contains('onToggleCamera: _toggleVideo'));
  });

  test('camera control stays disabled until connected and while switching', () {
    expect(
      voiceScreen,
      contains(
        'cameraBusy: _cameraSwitching || session?.state != CallState.connected',
      ),
    );
    expect(
      videoScreen,
      contains('_cameraSwitching ||\n                         _session?.state != CallState.connected'),
    );
  });

  test('camera action uses a compact camera icon and localized state tooltip', () {
    expect(controlDock, contains('size: 44'));
    expect(controlDock, contains('Icons.videocam_off : Icons.videocam'));
    expect(controlDock, contains('l10n.turnVideoOn : l10n.turnVideoOff'));
  });
}
