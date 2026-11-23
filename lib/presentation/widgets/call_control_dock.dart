import 'package:flutter/material.dart';

import '../../core/theme/stellar_theme.dart';

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

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: StellarColors.bgElevated.withOpacity(0.9),
        borderRadius: BorderRadius.circular(32),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _DockButton(
            icon: muted ? Icons.mic_off : Icons.mic,
            active: muted,
            onTap: onToggleMute,
          ),
          _DockButton(
            icon: speakerOn ? Icons.volume_up : Icons.volume_down,
            active: speakerOn,
            onTap: onToggleSpeaker,
          ),
          if (showCameraControls) ...[
            _DockButton(
              icon: cameraOff ? Icons.videocam_off : Icons.videocam,
              active: !cameraOff,
              onTap: cameraBusy ? null : onToggleCamera,
              tooltip: cameraOff ? 'Turn on video' : 'Turn off video',
            ),
            if (!cameraOff) _DockButton(
              icon: Icons.cameraswitch,
              active: false,
              onTap: cameraBusy ? null : onFlipCamera,
              tooltip: 'Switch camera',
            ),
          ],
          _DockButton(
            icon: Icons.call_end,
            active: true,
            activeColor: StellarColors.danger,
            onTap: onEndCall,
          ),
        ],
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
  });

  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      icon: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? activeColor : Colors.white10,
        ),
        child: Icon(icon, color: onTap == null ? Colors.white38 : Colors.white),
      ),
    );
  }
}
