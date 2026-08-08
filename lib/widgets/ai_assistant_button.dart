import 'package:flutter/material.dart';

import 'frosted_glass.dart';

const _kFgInactive = Color(0xFF8E8E8E);

class AiAssistantButton extends StatelessWidget {
  const AiAssistantButton({
    super.key,
    required this.visible,
    required this.onToggle,
    this.tooltip,
    this.icon = Icons.auto_awesome,
  });

  final bool visible;
  final VoidCallback onToggle;
  final String? tooltip;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? (visible ? 'Hide AI Assistant' : 'Show AI Assistant'),
      child: GestureDetector(
        onTap: onToggle,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 15,
            color: visible
                ? const Color(0xFF2472C8)
                : AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive,
          ),
        ),
      ),
    );
  }
}
