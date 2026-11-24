import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/stories/story_temp_files.dart';

void main() {
  test('startup cleanup removes only decrypted Story video files', () async {
    final directory = await Directory.systemTemp.createTemp('stellar-story-test-');
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final orphan = File('${directory.path}/stellar-story-abc.mp4');
    final unrelated = File('${directory.path}/voice-message.mp4');
    await orphan.writeAsBytes([1, 2, 3]);
    await unrelated.writeAsBytes([4, 5, 6]);

    await cleanupStoryTemporaryFiles(directory: directory);

    expect(await orphan.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
  });
}
