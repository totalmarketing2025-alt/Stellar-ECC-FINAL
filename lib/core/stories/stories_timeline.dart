import 'stories_service.dart';

/// Groups stories by owner and orders each owner's sequence oldest-first.
Map<String, List<StellarStory>> groupStoriesByOwner(
  Iterable<StellarStory> stories,
) {
  final grouped = <String, List<StellarStory>>{};
  for (final story in stories) {
    grouped.putIfAbsent(story.owner.toLowerCase(), () => <StellarStory>[])
        .add(story);
  }
  for (final sequence in grouped.values) {
    sequence.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
  return grouped;
}

int? findUnexpiredStoryIndex({
  required List<StellarStory> stories,
  required int startIndex,
  required int direction,
  required int nowMs,
}) {
  if (direction != -1 && direction != 1) return null;
  var index = startIndex;
  while (index >= 0 && index < stories.length &&
      stories[index].expiresAt <= nowMs) {
    index += direction;
  }
  return index >= 0 && index < stories.length ? index : null;
}
