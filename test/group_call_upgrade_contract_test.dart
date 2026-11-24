import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final group = File('lib/core/calls/group_call_coordinator.dart')
      .readAsStringSync();
  final direct = File('lib/core/calls/call_coordinator.dart')
      .readAsStringSync();
  final service = File('lib/core/calls/call_service.dart')
      .readAsStringSync();
  final callDock = File('lib/presentation/widgets/call_control_dock.dart')
      .readAsStringSync();
  final upgradeUi = File(
    'lib/presentation/screens/calls/add_participant_to_call_dialog.dart',
  ).readAsStringSync();

  test('active 1:1 UI offers a group upgrade with voice or video', () {
    expect(callDock, contains('onAddParticipant'));
    expect(upgradeUi, contains('SegmentedButton<bool>'));
    expect(upgradeUi, contains('createGroupChat'));
    expect(upgradeUi, contains('startOutgoing'));
  });

  test('group upgrade borrows the current media and avoids a second capture', () {
    expect(group, contains('prepareDirectMedia(video: video)'));
    expect(group, contains('_ownsLocalMedia = false'));
    expect(group, contains('_ownsCameraMedia = false'));
    expect(direct, contains('prepareGroupUpgradeMedia'));
  });

  test('direct call stays alive until the complete mesh is connected', () {
    expect(group, contains('_allMembersConnected(room)'));
    expect(group, contains('await onDirectUpgradeComplete(roomId)'));
    expect(direct, contains('_groupUpgradePeerReady!.future.timeout'));
    expect(direct, contains('signalGroupUpgradeReady'));
  });

  test('successful handoff preserves the capture tracks for the group mesh', () {
    expect(service, contains('bool preserveMedia = false'));
    expect(service, contains('if (!preserveMedia) await localStream?.dispose()'));
    expect(service, contains('if (!preserveMedia) await cameraCaptureStream?.dispose()'));
    expect(group, contains('_ownsLocalMedia = true'));
  });
}
