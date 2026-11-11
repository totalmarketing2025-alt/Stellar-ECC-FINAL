import "dart:io";
import "dart:typed_data";

import "package:audioplayers/audioplayers.dart";
import "package:path_provider/path_provider.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/moderation/moderation_admin_message.dart";
import "../../../core/moderation/moderation_admin_client.dart";
import "../../state/app_providers.dart";
import "moderation_broadcast_admin_tab.dart";

class ModerationRoomScreen extends ConsumerStatefulWidget {
  const ModerationRoomScreen({super.key});

  @override
  ConsumerState<ModerationRoomScreen> createState() =>
      _ModerationRoomScreenState();
}

class _ModerationRoomScreenState
    extends ConsumerState<ModerationRoomScreen> {
  final _secretController = TextEditingController();

  List<ModerationAdminMessage> _messages = [];
  List<ModerationAdminUser> _users = [];
  String? _usersError;
  bool _loading = false;
  bool _authenticated = false;
  String? _error;

  int _offset = 0;
  static const _pageSize = 50;

  @override
  void dispose() {
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _authenticate() async {
    final secret = _secretController.text.trim();

    if (secret.isEmpty) {
      setState(() {
        _error = "Enter moderation admin secret";
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _usersError = null;
    });

    try {
      final client = ref.read(moderationAdminClientProvider);
      await client.authenticate(secret);

      _secretController.clear();
      _offset = 0;

      final messages = await client.fetchMessages(
        limit: _pageSize,
        offset: 0,
      );

      if (!mounted) return;

      // Admin access and Messages do not depend on the Users endpoint.
      setState(() {
        _authenticated = true;
        _messages = messages;
        _loading = false;
      });

      try {
        final users = await client.fetchUsers();
        if (!mounted) return;
        setState(() {
          _users = users;
          _usersError = null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _usersError = e.toString();
        });
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _authenticated = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _refresh() async {
    if (!_authenticated) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final client = ref.read(moderationAdminClientProvider);
      final messages = await client.fetchMessages(
        limit: _pageSize,
        offset: 0,
      );

      if (!mounted) return;

      setState(() {
        _offset = 0;
        _messages = messages;
        _loading = false;
      });

      // A Users API failure must not fail the Messages refresh.
      try {
        final users = await client.fetchUsers();
        if (!mounted) return;
        setState(() {
          _users = users;
          _usersError = null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _usersError = e.toString();
        });
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _nextPage() async {
    if (!_authenticated || _messages.length < _pageSize) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final nextOffset = _offset + _pageSize;

      final messages = await ref
          .read(moderationAdminClientProvider)
          .fetchMessages(
            limit: _pageSize,
            offset: nextOffset,
          );

      if (!mounted) return;

      setState(() {
        _offset = nextOffset;
        _messages = messages;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _logout() {
    ref.read(moderationAdminClientProvider).logout();

    setState(() {
      _authenticated = false;
      _messages = [];
      _users = [];
      _usersError = null;
      _offset = 0;
      _error = null;
    });
  }

  String _formatDate(int millis) {
    if (millis <= 0) return "-";

    final date = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();

    String two(int value) => value.toString().padLeft(2, "0");

    return "${date.year}-${two(date.month)}-${two(date.day)} "
        "${two(date.hour)}:${two(date.minute)}:${two(date.second)}";
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Moderation Room"),
          bottom: _authenticated
              ? const TabBar(
                  tabs: [
                    Tab(text: "Messages"),
                    Tab(text: "Broadcasts"),
                    Tab(text: "Users"),
                  ],
                )
              : null,
          actions: [
            if (_authenticated)
              IconButton(
                tooltip: "Refresh",
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            if (_authenticated)
              IconButton(
                tooltip: "Logout",
                onPressed: _loading ? null : _logout,
                icon: const Icon(Icons.logout),
              ),
          ],
        ),
        body: !_authenticated
            ? _buildLogin(context)
            : TabBarView(
                children: [
                  _buildMessages(context),
                  const ModerationBroadcastAdminTab(),
                  _buildUsers(context),
                ],
              ),
      ),
    );
  }

  Widget _buildLogin(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.admin_panel_settings,
                    size: 56,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Moderation Admin",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Enter the administrator secret to access "
                    "the moderation room.",
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _secretController,
                    obscureText: true,
                    enabled: !_loading,
                    decoration: const InputDecoration(
                      labelText: "Admin secret",
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _authenticate(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _loading ? null : _authenticate,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.lock_open),
                    label: Text(
                      _loading
                          ? "Authenticating..."
                          : "Open Moderation Room",
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUsers(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: _users.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 180),
                Center(
                  child: Text(
                    _usersError == null
                        ? "No registered users"
                        : "Could not load users: $_usersError",
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _users.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final user = _users[index];

                return Card(
                  child: ListTile(
                    leading: Icon(
                      user.wantedModeEnabled
                          ? Icons.warning_rounded
                          : Icons.person_outline,
                      color: user.wantedModeEnabled
                          ? Colors.red
                          : null,
                    ),
                    title: Text(
                      user.nickname,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: user.wantedModeEnabled
                        ? Text(
                            user.wantedModeUpdatedAt == null
                                ? "WANTED MODE ACTIVE"
                                : "WANTED MODE ACTIVE • ${_formatDate(user.wantedModeUpdatedAt!.millisecondsSinceEpoch)}",
                            style: const TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : const Text("Normal status"),
                    trailing: user.wantedModeEnabled
                        ? const Icon(
                            Icons.circle,
                            color: Colors.red,
                            size: 12,
                          )
                        : null,
                  ),
                );
              },
            ),
    );
  }

  Widget _buildMessages(BuildContext context) {
    if (_loading && _messages.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_messages.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: const [
            SizedBox(height: 180),
            Center(
              child: Text("No active moderation messages"),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _messages.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index == _messages.length) {
            return _buildPagination();
          }

          return _buildMessageCard(_messages[index]);
        },
      ),
    );
  }

  Future<void> _viewAttachment(ModerationAdminMessage message) async {
    final mime = message.attachmentMimeType?.toLowerCase() ?? "";
    if (mime.isEmpty || !_authenticated) return;
    try {
      final bytes = await ref.read(moderationAdminClientProvider)
          .fetchAttachment(message.messageId);
      if (!mounted || !_authenticated) return;
      if (bytes.isEmpty) throw StateError("Attachment is empty");
      // Avoid retaining oversized attachments in the admin UI.
      if (bytes.length > 32 * 1024 * 1024) {
        throw StateError("Attachment exceeds 32 MiB preview limit");
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Moderation attachment"),
          content: SizedBox(
            width: 440,
            child: mime.startsWith("image/")
                ? InteractiveViewer(
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  )
                : mime.startsWith("audio/")
                    ? _ModerationAudioPlayer(bytes: bytes)
                    : Text("File type: $mime\\nSize: ${bytes.length} bytes"),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                try {
                  final dir = await getApplicationDocumentsDirectory();
                  final ext = _attachmentExtension(mime);
                  final safeId = message.messageId
                      .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
                  final file = File('${dir.path}/moderation_$safeId.$ext');
                  await file.writeAsBytes(bytes, flush: true);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Saved in app documents: ${file.path}")),
                  );
                } catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Save failed: $error")),
                  );
                }
              },
              icon: const Icon(Icons.save_alt),
              label: const Text("Save to app documents"),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Close"),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Attachment error: $error")),
      );
    }
  }

  String _attachmentExtension(String mime) {
    switch (mime.split(";").first.trim()) {
      case "image/jpeg": return "jpg";
      case "image/png": return "png";
      case "image/webp": return "webp";
      case "audio/mpeg": return "mp3";
      case "audio/mp4":
      case "audio/x-m4a": return "m4a";
      case "audio/ogg": return "ogg";
      case "audio/wav":
      case "audio/x-wav": return "wav";
      case "application/pdf": return "pdf";
      case "video/mp4": return "mp4";
      default: return "bin";
    }
  }

  Widget _buildMessageCard(ModerationAdminMessage message) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shield_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "${message.sender} → ${message.recipient}",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              message.plaintext,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 10),
            Text(
              "Created: ${_formatDate(message.createdAt)}",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              "Expires: ${_formatDate(message.expiresAt)}",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              "Type: ${message.contentType}",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (message.chatId != null)
              Text(
                "Chat: ${message.chatId}",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (message.attachmentMimeType != null) ...[
              Text(
                "Attachment: ${message.attachmentMimeType}",
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: _loading
                    ? null
                    : () => _viewAttachment(message),
                icon: const Icon(Icons.attachment),
                label: Text(
                  message.attachmentMimeType!
                          .toLowerCase()
                          .startsWith("image/")
                      ? "View attachment"
                      : "Open attachment",
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              "ID: ${message.messageId}",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPagination() {
    final canGoBack = _offset > 0;
    final canGoNext = _messages.length >= _pageSize;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: "Previous page",
          onPressed: !_loading && canGoBack
              ? () async {
                  setState(() => _loading = true);

                  try {
                    final previousOffset =
                        (_offset - _pageSize).clamp(0, 1 << 30);

                    final messages = await ref
                        .read(moderationAdminClientProvider)
                        .fetchMessages(
                          limit: _pageSize,
                          offset: previousOffset,
                        );

                    if (!mounted) return;

                    setState(() {
                      _offset = previousOffset;
                      _messages = messages;
                      _loading = false;
                    });
                  } catch (e) {
                    if (!mounted) return;

                    setState(() {
                      _loading = false;
                      _error = e.toString();
                    });
                  }
                }
              : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Text("Page ${(_offset ~/ _pageSize) + 1}"),
        IconButton(
          tooltip: "Next page",
          onPressed: !_loading && canGoNext ? _nextPage : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

class _ModerationAudioPlayer extends StatefulWidget {
  const _ModerationAudioPlayer({required this.bytes});
  final Uint8List bytes;

  @override
  State<_ModerationAudioPlayer> createState() => _ModerationAudioPlayerState();
}

class _ModerationAudioPlayerState extends State<_ModerationAudioPlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  String? _error;

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
      } else {
        await _player.play(BytesSource(widget.bytes));
      }
      if (mounted) setState(() => _playing = !_playing);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text("Voice message"),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: _playing ? "Pause" : "Play",
              onPressed: _toggle,
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            ),
            IconButton(
              tooltip: "Stop",
              onPressed: () async {
                await _player.stop();
                if (mounted) setState(() => _playing = false);
              },
              icon: const Icon(Icons.stop),
            ),
          ],
        ),
        StreamBuilder<Duration>(
          stream: _player.onPositionChanged,
          builder: (context, snapshot) {
            final position = snapshot.data ?? Duration.zero;
            return Text("${position.inMinutes.toString().padLeft(2, '0')}:${(position.inSeconds % 60).toString().padLeft(2, '0')}");
          },
        ),
        if (_error != null) Text(_error!),
      ],
    );
  }
}
