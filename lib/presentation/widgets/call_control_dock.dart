import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';
import '../../l10n/app_localizations.dart';

class CallControlDock extends StatelessWidget {
  const CallControlDock({
    super.key,
    required this.muted,
    required this.speakerOn,
    required this.onToggleMute,
    required this.onToggleSpeaker,
    required this.onEndCall,
    this.cameraOff = false,
    this.showCameraControls = false,
    this.cameraBusy = false,
    this.onToggleCamera,
    this.onFlipCamera,
    this.onAddParticipant,
  });

  final bool muted;
  final bool speakerOn;
  final bool cameraOff;
  final bool showCameraControls;
  final bool cameraBusy;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleSpeaker;
  final VoidCallback onEndCall;
  final VoidCallback? onToggleCamera;
  final VoidCallback? onFlipCamera;
  final VoidCallback? onAddParticipant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      // Keep the dock usable on narrow phones as controls are added.
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: StellarColors.bgElevated.withOpacity(0.9),
        borderRadius: BorderRadius.circular(32),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _DockButton(
            icon: muted ? Icons.mic_off : Icons.mic,
            active: muted,
            onTap: onToggleMute,
            tooltip: muted ? l10n.unmuteMicrophone : l10n.muteMicrophone,
          ),
          _DockButton(
            icon: speakerOn ? Icons.volume_up : Icons.volume_down,
            active: speakerOn,
            onTap: onToggleSpeaker,
            tooltip: speakerOn ? l10n.turnSpeakerOff : l10n.turnSpeakerOn,
          ),
          if (showCameraControls) ...[
            _DockButton(
              icon: cameraOff ? Icons.videocam_off : Icons.videocam,
              active: !cameraOff,
              size: 44,
              onTap: cameraBusy ? null : onToggleCamera,
              tooltip: cameraOff ? l10n.turnVideoOn : l10n.turnVideoOff,
            ),
            if (!cameraOff) _DockButton(
              icon: Icons.cameraswitch,
              active: false,
              onTap: cameraBusy ? null : onFlipCamera,
              tooltip: l10n.switchCamera,
            ),
          ],
          if (onAddParticipant != null)
            _DockButton(
              icon: Icons.person_add_alt_1,
              active: false,
              onTap: onAddParticipant,
              tooltip: l10n.addParticipantToGroupCall,
            ),
          _DockButton(
            icon: Icons.call_end,
            active: true,
            activeColor: StellarColors.danger,
            onTap: onEndCall,
            tooltip: l10n.endCall,
          ),
          ],
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.icon,
    required this.active,
    required this.onTap,
    this.activeColor = StellarColors.accentBlue,
    this.tooltip,
    this.size = 52,
  });

  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      icon: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? activeColor : Colors.white10,
        ),
        child: Icon(icon, color: onTap == null ? Colors.white38 : Colors.white),
      ),
    );
  }
}
