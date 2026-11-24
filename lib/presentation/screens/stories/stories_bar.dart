import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../core/stories/stories_service.dart';
import '../../../core/stories/story_temp_files.dart';
import '../../../core/stories/stories_timeline.dart';
import '../../../core/theme/stellar_theme.dart';
import '../../../domain/models/chat.dart';
import '../../../l10n/stellar_translations.dart';
import '../../state/app_providers.dart';

class StoriesBar extends ConsumerStatefulWidget {
  const StoriesBar({super.key});

  @override
  ConsumerState<StoriesBar> createState() => _StoriesBarState();
}

class _StoriesBarState extends ConsumerState<StoriesBar> {
  List<StellarStory> _stories = [];
  bool _loading = true;
  bool _working = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStories());
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadStories());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStories() async {
    final nickname = ref.read(localNicknameProvider)?.trim();
    if (nickname == null || nickname.isEmpty) return;
    try {
      final stories = await ref.read(storiesServiceProvider).load(nickname: nickname);
      if (mounted) {
        setState(() {
          _stories = stories;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final nickname = ref.watch(localNicknameProvider) ?? '';
    final chats = ref.watch(chatListProvider).valueOrNull ?? const <Chat>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    final activeStories = _stories.where((story) => story.expiresAt > now).toList();
    final storiesByOwner = groupStoriesByOwner(activeStories);
    final own = storiesByOwner.remove(nickname.toLowerCase()) ?? <StellarStory>[];
    return SizedBox(
      height: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
            child: Text(stellarText(context, 'Stories'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _StoryCircle(
                  label: stellarText(context, 'Your story'),
                  icon: Icons.add,
                  hasStory: own.isNotEmpty,
                  onTap: own.isEmpty
                      ? () => _composeStory(chats)
                      : () => _openStories(own),
                  onAdd: _working ? null : () => _composeStory(chats),
                ),
                for (final entry in storiesByOwner.entries)
                  _StoryCircle(
                    label: entry.value.first.owner,
                    icon: Icons.person_outline,
                    hasStory: true,
                    onTap: () => _openStories(entry.value),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _composeStory(List<Chat> chats) async {
    if (_working) return;
    final eligible = chats.where((chat) =>
        chat.chatType == ChatType.direct &&
        (chat.peerName?.trim().isNotEmpty ?? false)).toList();
    if (eligible.isEmpty) {
      _message(stellarText(context, 'Start a direct chat before sharing a Story.'));
      return;
    }
    final audience = await _chooseAudience(eligible);
    if (audience == null || audience.isEmpty || !mounted) return;
    final picker = ImagePicker();
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: StellarColors.bgElevated,
      builder: (sheetContext) => SafeArea(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(leading: const Icon(Icons.photo_library_outlined),
              title: Text(stellarText(context, 'Choose photo')),
              onTap: () => Navigator.pop(sheetContext, 'image')),
          ListTile(leading: const Icon(Icons.video_library_outlined),
              title: Text(stellarText(context, 'Choose video (up to 15 seconds)')),
              onTap: () => Navigator.pop(sheetContext, 'video')),
          ListTile(leading: const Icon(Icons.camera_alt_outlined),
              title: Text(stellarText(context, 'Take photo')),
              onTap: () => Navigator.pop(sheetContext, 'camera-image')),
          ListTile(leading: const Icon(Icons.videocam_outlined),
              title: Text(stellarText(context, 'Record video (up to 15 seconds)')),
              onTap: () => Navigator.pop(sheetContext, 'camera-video')),
        ],
      )),
    );
    if (choice == null || !mounted) return;
    try {
      final XFile? selected;
      if (choice == 'image' || choice == 'camera-image') {
        selected = await picker.pickImage(
          source: choice == 'image' ? ImageSource.gallery : ImageSource.camera,
          imageQuality: 92,
        );
      } else {
        selected = await picker.pickVideo(
          source: choice == 'video' ? ImageSource.gallery : ImageSource.camera,
          maxDuration: const Duration(seconds: 15),
        );
      }
      if (selected == null || !mounted) return;
      final isVideo = choice == 'video' || choice == 'camera-video';
      var durationMs = 0;
      if (isVideo) {
        final controller = VideoPlayerController.file(File(selected.path));
        try {
          await controller.initialize();
          durationMs = controller.value.duration.inMilliseconds;
        } finally {
          await controller.dispose();
        }
        if (durationMs <= 0 || durationMs > StoriesService.maxVideoDurationMs) {
          _message(stellarText(context, 'Videos must be 15 seconds or shorter.'));
          return;
        }
      }
      final bytes = await selected.readAsBytes();
      final nickname = ref.read(localNicknameProvider)?.trim();
      if (nickname == null || nickname.isEmpty) return;
      setState(() => _working = true);
      await ref.read(storiesServiceProvider).publish(
        nickname: nickname,
        audience: audience,
        media: Uint8List.fromList(bytes),
        mediaType: isVideo ? 'video' : 'image',
        durationMs: durationMs,
        videoExtension: selected.name.contains('.')
            ? selected.name.split('.').last.toLowerCase()
            : 'mp4',
      );
      await _loadStories();
      if (mounted) _message(stellarText(context, 'Story shared for 24 hours.'));
    } catch (error) {
      if (mounted) _message('${stellarText(context, 'Could not share Story:')} $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<List<String>?> _chooseAudience(List<Chat> chats) async {
    final chosen = <String>{};
    return showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
        title: Text(stellarText(context, 'Share Story with')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final chat in chats)
                CheckboxListTile(
                  value: chosen.contains(chat.peerName!.toLowerCase()),
                  title: Text(chat.displayName),
                  subtitle: Text('@${chat.peerName}'),
                  onChanged: (checked) => setDialogState(() {
                    final peer = chat.peerName!.toLowerCase();
                    if (checked == true) { chosen.add(peer); } else { chosen.remove(peer); }
                  }),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext),
              child: Text(stellarText(context, 'Cancel'))),
          FilledButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(dialogContext, chosen.toList()),
              child: Text(stellarText(context, 'Continue'))),
        ],
      )),
    );
  }

  void _openStories(List<StellarStory> stories) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StoryViewerScreen(stories: stories),
      fullscreenDialog: true,
    )).then((_) => _loadStories());
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

class _StoryCircle extends StatelessWidget {
  const _StoryCircle({
    required this.label,
    required this.icon,
    required this.onTap,
    this.onAdd,
    this.hasStory = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onAdd;
  final bool hasStory;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 76,
    child: InkWell(
      onTap: onTap,
      child: Column(children: [
        Stack(clipBehavior: Clip.none, children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: hasStory ? StellarColors.stellarGradient : null,
              border: hasStory ? null : Border.all(color: Colors.white38),
            ),
            child: CircleAvatar(
              radius: 25,
              backgroundColor: StellarColors.bgElevated,
              child: Icon(icon, color: Colors.white),
            ),
          ),
          if (onAdd != null)
            Positioned(right: -2, bottom: -1, child: GestureDetector(
              onTap: onAdd,
              child: Container(
                decoration: const BoxDecoration(color: StellarColors.accentPurple, shape: BoxShape.circle),
                padding: const EdgeInsets.all(3),
                child: const Icon(Icons.add, size: 15, color: Colors.white),
              ),
            )),
        ]),
        const SizedBox(height: 4),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    ),
  );
}

class StoryViewerScreen extends ConsumerStatefulWidget {
  const StoryViewerScreen({super.key, required this.stories});
  final List<StellarStory> stories;

  @override
  ConsumerState<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen> {
  int _storyIndex = 0;
  Uint8List? _bytes;
  VideoPlayerController? _video;
  File? _temporaryVideo;
  String? _error;
  bool _loading = true;
  bool _reacting = false;
  int _openGeneration = 0;
  Timer? _expiryTimer;

  StellarStory get _story => widget.stories[_storyIndex];

  @override
  void initState() {
    super.initState();
    _startExpiryTimer();
    _open();
  }

  void _startExpiryTimer() {
    _expiryTimer?.cancel();
    final remaining = _story.expiresAt - DateTime.now().millisecondsSinceEpoch;
    _expiryTimer = Timer(Duration(milliseconds: remaining < 0 ? 0 : remaining), () {
      if (!mounted) return;
      if (_storyIndex < widget.stories.length - 1) {
        _showStory(_storyIndex + 1);
      } else {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _showStory(int index) async {
    if (index < 0 || index >= widget.stories.length || index == _storyIndex) return;
    final direction = index > _storyIndex ? 1 : -1;
    final nextIndex = findUnexpiredStoryIndex(
      stories: widget.stories,
      startIndex: index,
      direction: direction,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (nextIndex == null) {
      if (direction > 0 && mounted) Navigator.of(context).pop();
      return;
    }
    index = nextIndex;
    _expiryTimer?.cancel();
    await _video?.dispose();
    _video = null;
    final oldFile = _temporaryVideo;
    _temporaryVideo = null;
    if (oldFile != null) {
      try { await oldFile.delete(); } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _storyIndex = index;
      _bytes = null;
      _error = null;
      _loading = true;
    });
    _startExpiryTimer();
    await _open();
  }

  Future<void> _open() async {
    final story = _story;
    final generation = ++_openGeneration;
    try {
      final nickname = ref.read(localNicknameProvider)?.trim();
      if (nickname == null || nickname.isEmpty) throw StateError('Profile unavailable.');
      final bytes = await ref.read(storiesServiceProvider).openMedia(
        nickname: nickname, story: story,
      );
      if (!mounted || generation != _openGeneration) return;
      if (story.mediaType == 'video') {
        final dir = await getTemporaryDirectory();
        await cleanupStoryTemporaryFiles(directory: dir);
        final file = File('${dir.path}/stellar-story-${story.id}.${story.videoExtension}');
        _temporaryVideo = file;
        await file.writeAsBytes(bytes, flush: true);
        final controller = VideoPlayerController.file(file);
        _video = controller;
        await controller.initialize();
        if (!mounted || generation != _openGeneration) {
          await controller.dispose();
          try { await file.delete(); } catch (_) {}
          return;
        }
        await controller.setLooping(false);
        await controller.play();
      }
      if (mounted && generation == _openGeneration) {
        setState(() { _bytes = bytes; _loading = false; });
      }
    } catch (error) {
      if (mounted && generation == _openGeneration) {
        setState(() { _error = error.toString(); _loading = false; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final story = _story;
    final isOwn = story.owner.toLowerCase() ==
        (ref.watch(localNicknameProvider) ?? '').toLowerCase();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: Stack(children: [
        Positioned.fill(child: Center(child: _buildMedia())),
        Positioned(left: 16, right: 16, top: 12, child: Row(children: [
          CircleAvatar(radius: 18, child: Text(
            story.owner.isEmpty ? '?' : story.owner.substring(0, 1).toUpperCase(),
          )),
          const SizedBox(width: 10),
          Expanded(child: Text(story.owner,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
          if (isOwn) ...[
            IconButton(tooltip: stellarText(context, 'Delete Story'),
              onPressed: _delete, icon: const Icon(Icons.delete_outline, color: Colors.white)),
          ],
          IconButton(onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.white)),
        ])),
        if (!isOwn && !_loading && _error == null)
          Positioned(left: 12, right: 12, bottom: 20,
            child: Wrap(alignment: WrapAlignment.center, spacing: 10,
              children: ['❤️', '😂', '😮', '😢', '👏', '🔥'].map((emoji) =>
                ActionChip(label: Text(emoji), onPressed: _reacting ? null : () => _react(emoji)),
              ).toList(),
            ),
          ),
        if (isOwn && story.reactionCounts.isNotEmpty)
          Positioned(left: 12, right: 12, bottom: 20,
            child: Wrap(alignment: WrapAlignment.center, spacing: 10,
              children: story.reactionCounts.entries.map((e) =>
                Chip(label: Text('${e.key} ${e.value}')),
              ).toList(),
            ),
          ),
        if (_reacting) const Positioned.fill(child: Center(child: CircularProgressIndicator())),
        if (widget.stories.length > 1) ...[
          Positioned(left: 4, top: 0, bottom: 0, child: Center(
            child: IconButton(
              tooltip: stellarText(context, 'Previous Story'),
              onPressed: _storyIndex > 0 ? () => _showStory(_storyIndex - 1) : null,
              icon: const Icon(Icons.chevron_left, color: Colors.white, size: 34),
              style: IconButton.styleFrom(backgroundColor: Colors.black38),
            ),
          )),
          Positioned(right: 4, top: 0, bottom: 0, child: Center(
            child: IconButton(
              tooltip: stellarText(context, 'Next Story'),
              onPressed: _storyIndex < widget.stories.length - 1
                  ? () => _showStory(_storyIndex + 1) : null,
              icon: const Icon(Icons.chevron_right, color: Colors.white, size: 34),
              style: IconButton.styleFrom(backgroundColor: Colors.black38),
            ),
          )),
        ],
      ])),
    );
  }

  Widget _buildMedia() {
    final story = _story;
    if (_loading) return const CircularProgressIndicator();
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error!, style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center),
      );
    }
    if (story.mediaType == 'video') {
      final controller = _video;
      if (controller == null || !controller.value.isInitialized) return const CircularProgressIndicator();
      return AspectRatio(aspectRatio: controller.value.aspectRatio,
        child: Stack(alignment: Alignment.bottomCenter, children: [
          VideoPlayer(controller),
          VideoProgressIndicator(controller, allowScrubbing: false,
              colors: const VideoProgressColors(playedColor: Colors.white)),
          Align(alignment: Alignment.center, child: IconButton(
            iconSize: 58,
            icon: Icon(controller.value.isPlaying ? Icons.pause_circle_outline : Icons.play_circle_outline,
                color: Colors.white),
            onPressed: () {
              if (controller.value.isPlaying) {
                controller.pause();
              } else {
                controller.play();
              }
              setState(() {});
            },
          )),
        ]));
    }
    return InteractiveViewer(child: Image.memory(_bytes!, fit: BoxFit.contain));
  }

  Future<void> _react(String emoji) async {
    final nickname = ref.read(localNicknameProvider)?.trim();
    if (nickname == null) return;
    setState(() => _reacting = true);
    try {
      await ref.read(storiesServiceProvider).react(
        nickname: nickname, story: _story, emoji: emoji,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(stellarText(context, 'Reaction sent.'))),
        );
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _reacting = false);
    }
  }

  Future<void> _delete() async {
    final nickname = ref.read(localNicknameProvider)?.trim();
    if (nickname == null) return;
    try {
      await ref.read(storiesServiceProvider).delete(nickname: nickname, storyId: _story.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  void dispose() {
    _openGeneration++;
    _expiryTimer?.cancel();
    _video?.dispose();
    final file = _temporaryVideo;
    if (file != null) file.delete().catchError((_) => file);
    super.dispose();
  }
}
