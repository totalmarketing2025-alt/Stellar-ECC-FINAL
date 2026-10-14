import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/moderation/moderation_admin_client.dart';
import '../../../core/moderation/stellar_broadcast.dart';
import '../../state/app_providers.dart';

class ModerationBroadcastAdminTab extends ConsumerStatefulWidget {
  const ModerationBroadcastAdminTab({super.key});

  @override
  ConsumerState<ModerationBroadcastAdminTab> createState() =>
      _ModerationBroadcastAdminTabState();
}

class _ModerationBroadcastAdminTabState
    extends ConsumerState<ModerationBroadcastAdminTab> {
  final _titleController = TextEditingController();
  final _messageController = TextEditingController();

  List<StellarBroadcast> _broadcasts = [];
  PlatformFile? _attachment;
  bool _loading = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  String? _mimeType(String name) {
    switch (name.split('.').last.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _pickAttachment() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        allowMultiple: false,
      );

      if (!mounted || result == null || result.files.isEmpty) return;

      final file = result.files.single;

      if (file.bytes == null || file.bytes!.isEmpty) {
        setState(() => _error = 'Could not read the selected file.');
        return;
      }

      if (file.bytes!.length > 8 * 1024 * 1024) {
        setState(() => _error = 'Maximum attachment size is 8 MiB.');
        return;
      }

      setState(() {
        _attachment = file;
        _error = null;
        _notice = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'File selection failed: $e');
    }
  }

  Future<void> _refresh() async {
    if (!ref.read(moderationAdminClientProvider).isAuthenticated) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await ref
          .read(moderationAdminClientProvider)
          .fetchBroadcasts(limit: 50);

      if (!mounted) return;

      setState(() {
        _broadcasts = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _publish() async {
    final title = _titleController.text.trim();
    final message = _messageController.text.trim();

    if (title.isEmpty || message.isEmpty) {
      setState(() => _error = 'Enter both a title and a message.');
      return;
    }

    final file = _attachment;
    final bytes = file?.bytes;
    final mimeType = file == null ? null : _mimeType(file.name);

    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });

    var created = false;

    try {
      final client = ref.read(moderationAdminClientProvider);

      final broadcast = await client.createBroadcast(
        title: title,
        message: message,
        attachmentMimeType: mimeType,
      );

      created = true;

      if (file != null && bytes != null && mimeType != null) {
        await client.uploadBroadcastAttachment(
          broadcastId: broadcast.broadcastId,
          mimeType: mimeType,
          bytes: bytes,
        );
      }

      _titleController.clear();
      _messageController.clear();

      if (!mounted) return;

      setState(() {
        _attachment = null;
        _notice = 'Broadcast published successfully.';
      });

      await _refresh();
    } catch (e) {
      if (!mounted) return;

      final failureMessage = created
          ? 'The message was published, but the attachment upload failed: $e'
          : 'Broadcast could not be published: $e';

      setState(() {
        _loading = false;
        _error = failureMessage;
      });

      if (created) {
        await _refresh();
        if (!mounted) return;

        setState(() {
          _error = failureMessage;
        });
      }
    }
  }

  String _date(int millis) {
    if (millis <= 0) return 'Unknown date';
    return DateTime.fromMillisecondsSinceEpoch(millis)
        .toLocal()
        .toString()
        .split('.')
        .first;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Global Broadcast',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          const Text(
            'Publish an announcement that authenticated users can retrieve later, '
            'even if they were offline when it was published.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _titleController,
            maxLength: 160,
            enabled: !_loading,
            decoration: const InputDecoration(
              labelText: 'Announcement title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _messageController,
            maxLines: 5,
            maxLength: 20000,
            enabled: !_loading,
            decoration: const InputDecoration(
              labelText: 'Message',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _loading ? null : _pickAttachment,
            icon: const Icon(Icons.attach_file),
            label: const Text('Choose attachment (max 8 MiB)'),
          ),
          if (_attachment != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(_attachment!.name),
              subtitle: Text(
                '${(_attachment!.size / 1024).toStringAsFixed(1)} KiB',
              ),
              trailing: IconButton(
                tooltip: 'Remove attachment',
                onPressed: _loading
                    ? null
                    : () => setState(() => _attachment = null),
                icon: const Icon(Icons.close),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _loading ? null : _publish,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.campaign_outlined),
            label: Text(_loading ? 'Please wait...' : 'Publish Broadcast'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_notice != null) ...[
            const SizedBox(height: 12),
            Text(
              _notice!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Published announcements',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Refresh announcements',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_loading && _broadcasts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_broadcasts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No Broadcast announcements yet.'),
            )
          else
            ..._broadcasts.map(
              (item) => Card(
                child: ListTile(
                  leading: const Icon(Icons.campaign_outlined),
                  title: Text(item.title),
                  subtitle: Text(
                    '${_date(item.createdAt)}\n'
                    '${item.message}\n'
                    '${item.hasAttachment ? 'Attachment: ${item.attachmentMimeType}' : 'No attachment'}',
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
