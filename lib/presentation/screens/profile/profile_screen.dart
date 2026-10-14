import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/stellar_theme.dart';
import '../../state/app_providers.dart';
import '../../widgets/stellar_avatar.dart';
import '../../widgets/ttl_picker_sheet.dart';
import '../../../domain/models/chat.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Uint8List? _photoBytes;
  bool _loadingPhoto = true;
  bool _savingPhoto = false;

  @override
  void initState() {
    super.initState();
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    Uint8List? bytes;

    try {
      bytes = await ref.read(
        profilePhotoBytesProvider(widget.userId).future,
      );
    } catch (_) {
      // Fall back to the encrypted local copy if loading fails.
      bytes = await ref
          .read(profilePhotoServiceProvider)
          .loadPhoto(widget.userId);
    }

    if (!mounted) return;

    setState(() {
      _photoBytes = bytes;
      _loadingPhoto = false;
    });
  }

  Future<void> _choosePhoto() async {
    if (_savingPhoto) return;

    try {
      final picker = ImagePicker();
      final selected = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 65,
      );

      if (selected == null || !mounted) return;

      final bytes = await selected.readAsBytes();

      if (bytes.isEmpty) {
        _showMessage('The selected image is empty.');
        return;
      }

      if (bytes.length > 512 * 1024) {
        _showMessage(
          'This photo is larger than 512 KiB. Choose a smaller image '
          'and try again. Your existing photo has not been changed.',
        );
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: StellarColors.bgElevated,
          title: const Text('Use this profile photo?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipOval(
                child: Image.memory(
                  bytes,
                  width: 160,
                  height: 160,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 160,
                    height: 160,
                    child: Icon(Icons.broken_image_outlined, size: 48),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'The photo will be encrypted on this device. '
                'If this is your profile, it can also be published to '
                'the Stellar directory.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save photo'),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      setState(() => _savingPhoto = true);

      try {
        await ref.read(profilePhotoServiceProvider).savePhoto(
              userId: widget.userId.trim().toLowerCase(),
              imageBytes: bytes,
            );

        if (!mounted) return;

        setState(() {
          _photoBytes = bytes;
        });

        // Refresh all avatar consumers even if the remote upload fails.
        ref.invalidate(
          profilePhotoBytesProvider(widget.userId.trim().toLowerCase()),
        );

        // Only publish a photo under the authenticated local nickname.
        final localNickname = ref.read(localNicknameProvider);
        if (localNickname != null &&
            localNickname.trim().toLowerCase() ==
                widget.userId.trim().toLowerCase()) {
          try {
            await ref.read(profilePhotoSyncServiceProvider).uploadPhoto(
                  nickname: localNickname,
                  imageBytes: bytes,
                );

            if (!mounted) return;
            setState(() => _savingPhoto = false);
            _showMessage('Profile photo saved and synchronized.');
          } catch (_) {
            if (!mounted) return;
            setState(() => _savingPhoto = false);
            _showMessage(
              'Photo saved on this device, but upload failed. '
              'The server copy was not confirmed.',
            );
          }
        } else {
          if (!mounted) return;
          setState(() => _savingPhoto = false);
          _showMessage('Profile photo saved securely on this device.');
        }
      } catch (_) {
        if (!mounted) return;
        setState(() => _savingPhoto = false);
        _showMessage('Could not save the profile photo.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _savingPhoto = false);
      _showMessage('Could not open or read the selected photo.');
    }
  }

  Future<void> _removePhoto() async {
    if (_savingPhoto || _photoBytes == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: StellarColors.bgElevated,
        title: const Text('Remove profile photo?'),
        content: const Text(
          'Your local photo will be removed. For your own profile, '
          'the directory copy will also be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _savingPhoto = true);

    try {
      final localNickname = ref.read(localNicknameProvider);

      // If this is the local user's profile, delete the remote copy first.
      // A failed remote delete must not be reported as a complete deletion.
      if (localNickname != null &&
            localNickname.trim().toLowerCase() ==
                widget.userId.trim().toLowerCase()) {
        await ref
            .read(profilePhotoSyncServiceProvider)
            .deletePhoto(localNickname);
      } else {
        await ref
            .read(profilePhotoServiceProvider)
            .removePhoto(widget.userId.trim().toLowerCase());
      }

      ref.invalidate(
        profilePhotoBytesProvider(widget.userId.trim().toLowerCase()),
      );

      if (!mounted) return;

      setState(() {
        _photoBytes = null;
        _savingPhoto = false;
      });

      _showMessage('Profile photo removed.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _savingPhoto = false);
      _showMessage('Could not completely remove the profile photo.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildProfileAvatar() {
    if (_loadingPhoto) {
      return const SizedBox(
        width: 96,
        height: 96,
        child: Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final bytes = _photoBytes;

    if (bytes == null) {
      return StellarAvatar(
        seed: widget.userId,
        label: widget.userId,
        size: 96,
      );
    }

    return ClipOval(
      child: Image.memory(
        bytes,
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => StellarAvatar(
          seed: widget.userId,
          label: widget.userId,
          size: 96,
        ),
      ),
    );
  }

  Future<void> _showReportDialog() async {
    final localNickname = ref.read(localNicknameProvider);

    if (localNickname == null || localNickname.trim().isEmpty) {
      _showMessage(
        'Set up your Stellar nickname before reporting a profile.',
      );
      return;
    }

    final target = widget.userId.trim().toLowerCase();

    if (target.isEmpty ||
        target == localNickname.trim().toLowerCase()) {
      return;
    }

    const reasons = <String>[
      'Spam',
      'Harassment or abuse',
      'Impersonation',
      'Inappropriate profile',
      'Scam or fraud',
      'Other',
    ];

    String selectedReason = reasons.first;
    final descriptionController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: StellarColors.bgElevated,
          title: Text('Report @$target'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Why are you reporting this profile?'),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedReason,
                  isExpanded: true,
                  items: reasons.map((reason) {
                    return DropdownMenuItem(
                      value: reason,
                      child: Text(reason),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedReason = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  maxLength: 2000,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Additional details (optional)',
                    hintText: 'Describe what happened',
                    border: OutlineInputBorder(),
                  ),
                ),
                const Text(
                  'Your report will be sent to Stellar Moderator.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Submit report'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) {
      descriptionController.dispose();
      return;
    }

    try {
      await ref.read(moderationClientProvider).submitReport(
        target: target,
        reason: selectedReason,
        description: descriptionController.text,
        nickname: localNickname,
      );

      if (mounted) {
        _showMessage('Report submitted to Stellar Moderator.');
      }
    } catch (error) {
      if (mounted) {
        _showMessage('Could not submit report. $error');
      }
    } finally {
      descriptionController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final localNickname = ref.watch(localNicknameProvider);
    final isSelf = localNickname != null &&
        widget.userId.trim().toLowerCase() ==
            localNickname.trim().toLowerCase();

    return Scaffold(
      appBar: AppBar(
        title: Text(isSelf ? 'Your Profile' : 'Profile'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: GestureDetector(
              onTap: isSelf && !_savingPhoto ? _choosePhoto : null,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  _buildProfileAvatar(),
                  if (isSelf)
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: StellarColors.accentBlue,
                        shape: BoxShape.circle,
                        border: Border.all(color: StellarColors.bgSurface, width: 2),
                      ),
                      child: const Icon(Icons.camera_alt_outlined, size: 17, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (isSelf) ...[
            Center(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _savingPhoto ? null : _choosePhoto,
                    icon: _savingPhoto
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_library_outlined),
                    label: Text(
                      _savingPhoto
                          ? 'Please wait...'
                          : _photoBytes == null
                              ? 'Add photo'
                              : 'Change photo',
                    ),
                  ),
                  if (_photoBytes != null)
                    TextButton.icon(
                      onPressed: _savingPhoto ? null : _removePhoto,
                      icon: const Icon(
                        Icons.delete_outline,
                        color: StellarColors.danger,
                      ),
                      label: const Text(
                        'Remove',
                        style: TextStyle(color: StellarColors.danger),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Center(
            child: Text(
              '@${widget.userId}',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (isSelf) ...[
            ListTile(
              leading: const Icon(
                Icons.qr_code,
                color: StellarColors.accentBlue,
              ),
              title: const Text('Safety number / QR code'),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(
                Icons.warning_amber_rounded,
                color: StellarColors.danger,
              ),
              title: const Text(
                'Reset Identity',
                style: TextStyle(color: StellarColors.danger),
              ),
              onTap: () {},
            ),
          ] else ...[
            ListTile(
              leading: const Icon(
                Icons.verified_user_outlined,
                color: StellarColors.accentBlue,
              ),
              title: const Text('Verify safety number'),
              subtitle: const Text(
                'Compare fingerprints to confirm no one is intercepting this chat',
              ),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(
                Icons.timer_outlined,
                color: StellarColors.accentPurple,
              ),
              title: const Text('Chat disappearing timer'),
              onTap: () async {
                await showModalBottomSheet<int>(
                  context: context,
                  backgroundColor: StellarColors.bgElevated,
                  builder: (_) => TtlPickerSheet(
                    current: TtlPreset.oneHour,
                    title: 'Disappearing timer',
                  ),
                );
              },
            ),
            const Divider(color: StellarColors.bgElevated),
            ListTile(
              leading: const Icon(
                Icons.flag_outlined,
                color: StellarColors.danger,
              ),
              title: const Text(
                'Report',
                style: TextStyle(color: StellarColors.danger),
              ),
              subtitle: const Text('Report this profile to Stellar Moderator'),
              onTap: _showReportDialog,
            ),
          ],
        ],
      ),
    );
  }
}
