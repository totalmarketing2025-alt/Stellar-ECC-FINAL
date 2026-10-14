import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/moderation/stellar_broadcast.dart';
import '../../state/app_providers.dart';

class BroadcastInboxScreen extends ConsumerStatefulWidget {
  const BroadcastInboxScreen({super.key});

  @override
  ConsumerState<BroadcastInboxScreen> createState() =>
      _BroadcastInboxScreenState();
}

class _BroadcastInboxScreenState
    extends ConsumerState<BroadcastInboxScreen> {
  List<StellarBroadcast> _broadcasts = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    final nickname = ref.read(localNicknameProvider)?.trim();

    if (nickname == null || nickname.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Set your Stellar nickname before opening broadcasts.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await ref
          .read(moderationClientProvider)
          .fetchBroadcasts(nickname: nickname, limit: 50, offset: 0);

      if (!mounted) return;

      setState(() {
        _broadcasts = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = 'Could not load broadcasts: $e';
      });
    }
  }

  String _formatDate(DateTime date) {
    final value = date.toLocal();
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');

    return '$day.$month.${value.year}  $hour:$minute';
  }

  Future<void> _openAttachment(StellarBroadcast broadcast) async {
    if (!broadcast.hasAttachment) return;

    final nickname = ref.read(localNicknameProvider)?.trim();

    if (nickname == null || nickname.isEmpty) {
      _showMessage('Your Stellar nickname is not available.');
      return;
    }

    try {
      final Uint8List bytes = await ref
          .read(moderationClientProvider)
          .fetchBroadcastAttachment(
            broadcastId: broadcast.broadcastId,
            nickname: nickname,
          );

      if (!mounted) return;

      final mimeType =
          (broadcast.attachmentMimeType ?? 'application/octet-stream')
              .toLowerCase();

      if (mimeType.startsWith('image/')) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => Dialog(
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
                    child: Text('Unable to display this image.'),
                  ),
                ),
              ),
            ),
          ),
        );
      } else if (mimeType == 'text/plain') {
        final text = utf8.decode(bytes, allowMalformed: true);

        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Text attachment'),
            content: SingleChildScrollView(
              child: SelectableText(text),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Attachment received'),
            content: Text(
              'Type: $mimeType\n'
              'Size: ${bytes.length} bytes\n\n'
              'The attachment was retrieved successfully. '
              'This screen does not save it to your device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showMessage('Could not open attachment: $e');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildBody() {
    if (_loading && _broadcasts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _broadcasts.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 100),
          const Icon(Icons.cloud_off_outlined, size: 48),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.icon(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ),
        ],
      );
    }

    if (_broadcasts.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 140),
            Icon(Icons.campaign_outlined, size: 52),
            SizedBox(height: 16),
            Center(child: Text('No broadcasts yet')),
            SizedBox(height: 8),
            Center(
              child: Text('Pull down to check for new announcements.'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: _broadcasts.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final broadcast = _broadcasts[index];

          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.campaign_outlined, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          broadcast.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SelectableText(broadcast.message),
                  const SizedBox(height: 12),
                  Text(
                    'Published: ${_formatDate(broadcast.createdAtDate)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (broadcast.hasAttachment) ...[
                    const Divider(height: 24),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => _openAttachment(broadcast),
                        icon: const Icon(Icons.attach_file),
                        label: const Text('Open attachment'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Broadcasts'),
        actions: [
          IconButton(
            tooltip: 'Refresh broadcasts',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null && _broadcasts.isNotEmpty)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: _refresh,
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }
}
