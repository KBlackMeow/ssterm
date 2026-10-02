/// Agent 面板的工具栏切换控件。

import 'package:flutter/material.dart';

import 'frosted_glass.dart';

const _kFgInactive = Color(0xFF8E8E8E);

/// 根据 `visible` 显示当前开关状态，点击时只调用父级回调，
/// 由标签状态决定面板显隐和布局尺寸。
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
