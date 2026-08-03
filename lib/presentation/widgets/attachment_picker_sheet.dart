import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/theme/stellar_theme.dart';

enum AttachmentKind { camera, gallery, file, voice }

class AttachmentPickerSheet extends StatelessWidget {
  const AttachmentPickerSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Wrap(
        children: [
          _AttachmentOption(
            icon: Icons.camera_alt_outlined,
            label: 'Camera',
            color: StellarColors.accentBlue,
            onTap: () async {
              final picker = ImagePicker();
              final file = await picker.pickImage(source: ImageSource.camera);
              if (context.mounted) Navigator.pop(context, file?.path);
            },
          ),
          _AttachmentOption(
            icon: Icons.photo_outlined,
            label: 'Gallery',
            color: StellarColors.accentPurple,
            onTap: () async {
              final picker = ImagePicker();
              final file = await picker.pickImage(source: ImageSource.gallery);
              if (context.mounted) Navigator.pop(context, file?.path);
            },
          ),
          _AttachmentOption(
            icon: Icons.insert_drive_file_outlined,
            label: 'File',
            color: StellarColors.success,
            onTap: () async {
              final result = await FilePicker.platform.pickFiles();
              if (context.mounted) Navigator.pop(context, result?.files.single.path);
            },
          ),
          _AttachmentOption(
            icon: Icons.mic_outlined,
            label: 'Voice message',
            color: StellarColors.danger,
            onTap: () {
              // Hold-to-record UX is implemented directly on the composer's
              // mic button (long-press + drag-to-cancel), not via this
              // sheet — this entry exists for the tap-to-open recorder
              // fallback on devices/screen-readers where long-press
              // gestures are harder to perform.
              Navigator.pop(context, 'voice');
            },
          ),
        ],
      ),
    );
  }
}

class _AttachmentOption extends StatelessWidget {
  const _AttachmentOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(backgroundColor: color.withOpacity(0.2), child: Icon(icon, color: color)),
      title: Text(label),
      onTap: onTap,
    );
  }
}
