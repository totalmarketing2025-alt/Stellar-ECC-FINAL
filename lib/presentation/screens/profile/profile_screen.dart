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
    final bytes = await ref
        .read(profilePhotoServiceProvider)
        .loadPhoto(widget.userId);

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
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (selected == null || !mounted) return;

      final bytes = await selected.readAsBytes();

      if (bytes.isEmpty) {
        _showMessage('The selected image is empty.');
        return;
      }

      if (bytes.length > 10 * 1024 * 1024) {
        _showMessage('Choose an image smaller than 10 MB.');
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
                'The photo will be encrypted and stored on this device.',
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
              userId: widget.userId,
              imageBytes: bytes,
            );

        if (!mounted) return;

        setState(() {
          _photoBytes = bytes;
          _savingPhoto = false;
        });

        _showMessage('Profile photo saved securely on this device.');
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
          'Your locally stored profile photo and its encryption key '
          'will be removed.',
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
      await ref.read(profilePhotoServiceProvider).removePhoto(widget.userId);

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
          Center(child: _buildProfileAvatar()),
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
                Icons.block,
                color: StellarColors.danger,
              ),
              title: const Text(
                'Block',
                style: TextStyle(color: StellarColors.danger),
              ),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(
                Icons.flag_outlined,
                color: StellarColors.danger,
              ),
              title: const Text(
                'Report',
                style: TextStyle(color: StellarColors.danger),
              ),
              onTap: () {},
            ),
          ],
        ],
      ),
    );
  }
}
