import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/moderation/moderation_admin_message.dart";
import "../../state/app_providers.dart";

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

      setState(() {
        _authenticated = true;
        _messages = messages;
        _loading = false;
      });
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
      final messages = await ref
          .read(moderationAdminClientProvider)
          .fetchMessages(
            limit: _pageSize,
            offset: 0,
          );

      if (!mounted) return;

      setState(() {
        _offset = 0;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text("Moderation Room"),
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
          : _buildMessages(context),
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

  Future<void> _viewAttachment(
    ModerationAdminMessage message,
  ) async {
    final mimeType = message.attachmentMimeType;

    if (mimeType == null || mimeType.isEmpty) {
      return;
    }

    final isImage = mimeType.toLowerCase().startsWith("image/");

    if (!isImage) {
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Attachment"),
          content: Text(
            "Attachment is stored securely in the moderation "
            "R2 bucket.\n\nMIME type: $mimeType",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Close"),
            ),
          ],
        ),
      );

      return;
    }

    try {
      final bytes = await ref
          .read(moderationAdminClientProvider)
          .fetchAttachment(message.messageId);

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text("Unable to render attachment"),
                ),
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Attachment error: $e"),
        ),
      );
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
                      : "View attachment info",
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
