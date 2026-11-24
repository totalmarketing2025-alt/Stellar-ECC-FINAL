import 'package:flutter_test/flutter_test.dart';
import 'package:stellar_ecc/core/stories/stories_service.dart';
import 'package:stellar_ecc/core/stories/stories_timeline.dart';

StellarStory story(String id, String owner, int createdAt, {int? expiresAt}) => StellarStory(
      id: id,
      owner: owner,
      mediaType: 'image',
      durationMs: 0,
      createdAt: createdAt,
      expiresAt: expiresAt ?? createdAt + 86400000,
      mediaSize: 100,
      reactionCounts: const {},
      videoExtension: '',
    );

void main() {
  test('groups every story by normalized owner in chronological order', () {
    final grouped = groupStoriesByOwner([
      story('alice-new', 'Alice', 30),
      story('bob-one', 'bob', 20),
      story('alice-old', 'alice', 10),
    ]);

    expect(grouped.keys, containsAll(['alice', 'bob']));
    expect(grouped['alice']!.map((item) => item.id), ['alice-old', 'alice-new']);
    expect(grouped['bob']!.map((item) => item.id), ['bob-one']);
  });

  test('viewer navigation skips expired stories and respects sequence bounds', () {
    final stories = [
      story('expired', 'alice', 1, expiresAt: 5),
      story('active-a', 'alice', 2, expiresAt: 20),
      story('active-b', 'alice', 3, expiresAt: 30),
    ];

    expect(
      findUnexpiredStoryIndex(
        stories: stories, startIndex: -1, direction: 1, nowMs: 10,
      ),
      isNull,
    );
    expect(
      findUnexpiredStoryIndex(
        stories: stories, startIndex: 1, direction: 1, nowMs: 21,
      ),
      2,
    );
    expect(
      findUnexpiredStoryIndex(
        stories: stories, startIndex: 1, direction: -1, nowMs: 10,
      ),
      1,
    );
  });
}
