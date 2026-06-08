part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// Small reusable widgets used by the AI assistant panel:
//   • _ModeSwitch / _ShellIntegrationBadge / _TabChip   — top mode bar
//   • _ReasoningSection                                  — collapsible thinking
//   • _CommandResultCard / _ExitBadge                    — command output card
//   • _AiCodeBlock                                       — code-fence renderer
//
// Extracted from `ai_assistant_panel.dart` to keep that file under the
// project-wide 1000-line cap.
// ───────────────────────────────────────────────────────────────────────────

// ── Mode switch ────────────────────────────────────────────────────────────

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.mode,
    required this.onChanged,
    this.shellIntegrationActive,
    required this.position,
    this.onPositionToggle,
  });

  final AiPanelMode mode;
  final ValueChanged<AiPanelMode> onChanged;
  final bool? shellIntegrationActive;
  final AiPanelPosition position;
  final VoidCallback? onPositionToggle;

  @override
  Widget build(BuildContext context) {
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.6);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      // Layout shape:
      //   [Command] [Agent]  ╌╌  [badge] [toggle] [label]
      // The trailing cluster sits inside an `Expanded` so it can never
      // push the row past its constraint — when the right-docked panel
      // gets narrow (≤ ~280 px) each trailing item shrinks (badge text
      // collapses to a dot-only pill, label ellipses, finally label
      // drops entirely) instead of overflowing.  See the long-form
      // calc in the commit that introduced the position toggle: at
      // 300 px wide the badge + toggle ALONE exceeded the available
      // width, so the previous Spacer-based layout couldn't help.
      child: Row(
        children: [
          _TabChip(
            label: 'Command',
            icon: Icons.terminal,
            selected: mode == AiPanelMode.command,
            onTap: () => onChanged(AiPanelMode.command),
          ),
          const SizedBox(width: 8),
          _TabChip(
            label: 'Agent',
            icon: Icons.auto_awesome,
            selected: mode == AiPanelMode.agent,
            onTap: () => onChanged(AiPanelMode.agent),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (mode == AiPanelMode.agent &&
                    shellIntegrationActive != null) ...[
                  // Flexible badge — its inner label shrinks first, then
                  // hides entirely (dot-only pill) when the trailing
                  // cluster can't fit.  Tooltip retains the full meaning.
                  Flexible(
                    child: _ShellIntegrationBadge(
                      active: shellIntegrationActive!,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (onPositionToggle != null)
                  _PositionToggle(
                    position: position,
                    onTap: onPositionToggle!,
                    color: dim,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact dock-side toggle.  Mirrors the SFTP toolbar's pair of
/// `view_agenda_outlined` / `view_sidebar_outlined` icons so a user
/// who flips one panel intuits the same gesture for the other.
class _PositionToggle extends StatelessWidget {
  const _PositionToggle({
    required this.position,
    required this.onTap,
    required this.color,
  });

  final AiPanelPosition position;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final dockedRight = position == AiPanelPosition.right;
    return Tooltip(
      message: dockedRight ? 'Move to bottom' : 'Move to right',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            dockedRight
                ? Icons.view_agenda_outlined
                : Icons.view_sidebar_outlined,
            size: 14,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _ShellIntegrationBadge extends StatelessWidget {
  const _ShellIntegrationBadge({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF2EE767) : const Color(0xFFFFB454);
    final tooltip = active
        ? 'OSC 133 shell integration is active — '
            'agent captures clean stdout + exit codes.'
        : 'Shell integration not detected — '
            'agent uses an echo-sentinel fallback. '
            'Reopen the tab after upgrading to enable OSC 133.';
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
        ),
        // Compact pill — the dot's colour conveys status at a glance and
        // the tooltip carries the full explanation, so we keep the label
        // to a single short token ("OSC133" / "echo") to leave room for
        // the position toggle in a narrow right-docked panel.
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                active ? 'OSC133' : 'echo',
                style: TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dim = AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? _kAccent.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? _kAccent : dim.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: selected ? _kAccent : dim),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: selected ? _kAccent : dim,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}

// ── Reasoning section (collapsible thinking block) ──────────────────────────

class _ReasoningSection extends StatefulWidget {
  final String reasoning;
  const _ReasoningSection({required this.reasoning});

  @override
  State<_ReasoningSection> createState() => _ReasoningSectionState();
}

class _ReasoningSectionState extends State<_ReasoningSection> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.6);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: dim.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.unfold_less : Icons.unfold_more,
                  size: 12,
                  color: dim,
                ),
                const SizedBox(width: 4),
                Text(
                  _expanded ? 'Hide reasoning' : 'Show reasoning',
                  style: TextStyle(color: dim, fontSize: 11, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: dim.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: dim.withValues(alpha: 0.15)),
            ),
            child: Text(
              widget.reasoning,
              style: TextStyle(
                color: dim,
                fontSize: 12,
                fontStyle: FontStyle.italic,
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }
}

// ── Command result card (collapsible) ──────────────────────────────────────

/// Inline "command executed" card shown in the agent transcript whenever
/// the auto-execute loop runs a command.  Mirrors what the LLM saw via
/// OSC 133 shell integration so the user can spot-check the agent's
/// view of reality.
class _CommandResultCard extends StatefulWidget {
  const _CommandResultCard({
    required this.command,
    required this.output,
    required this.exitCode,
  });

  final String command;
  final String output;
  final int? exitCode;

  @override
  State<_CommandResultCard> createState() => _CommandResultCardState();
}

class _CommandResultCardState extends State<_CommandResultCard> {
  static const _kCollapsedLines = 8;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.6);
    final out = widget.output;
    final lines = out.isEmpty ? const <String>[] : out.split('\n');
    final overflow = !_expanded && lines.length > _kCollapsedLines;
    final visible = overflow ? lines.sublist(0, _kCollapsedLines).join('\n') : out;

    return Container(
      decoration: BoxDecoration(
        color: dim.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: dim.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SelectableText(
                    '\$ ${widget.command}',
                    style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontFamily: 'JetBrainsMono',
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _ExitBadge(exitCode: widget.exitCode),
              ],
            ),
          ),
          if (out.isNotEmpty) ...[
            Container(
              height: 1,
              color: dim.withValues(alpha: 0.12),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    visible,
                    style: TextStyle(
                      color: dim,
                      fontSize: 11,
                      fontFamily: 'JetBrainsMono',
                      height: 1.35,
                    ),
                  ),
                  if (overflow) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => setState(() => _expanded = true),
                      child: Text(
                        '+ ${lines.length - _kCollapsedLines} more lines',
                        style: TextStyle(
                          color: dim,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          decoration: TextDecoration.underline,
                          decorationColor: dim.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ],
                  if (_expanded && lines.length > _kCollapsedLines) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => setState(() => _expanded = false),
                      child: Text(
                        'Collapse',
                        style: TextStyle(
                          color: dim,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          decoration: TextDecoration.underline,
                          decorationColor: dim.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExitBadge extends StatelessWidget {
  const _ExitBadge({required this.exitCode});

  final int? exitCode;

  @override
  Widget build(BuildContext context) {
    final ({Color bg, Color fg, String label}) style;
    if (exitCode == null) {
      style = (
        bg: const Color(0xFF8E8E8E).withValues(alpha: 0.2),
        fg: const Color(0xFF8E8E8E),
        label: 'exit ?',
      );
    } else if (exitCode == 0) {
      style = (
        bg: const Color(0xFF2E7D32).withValues(alpha: 0.18),
        fg: const Color(0xFF2EE767),
        label: 'exit 0',
      );
    } else {
      style = (
        bg: const Color(0xFFFF6E67).withValues(alpha: 0.18),
        fg: const Color(0xFFFF6E67),
        label: 'exit $exitCode',
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        style.label,
        style: TextStyle(
          color: style.fg,
          fontSize: 10,
          fontFamily: 'JetBrainsMono',
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Custom fenced-code-block renderer for AI replies.
///
/// Replaces `gpt_markdown.CodeField` for two concrete reasons (see the
/// `codeBuilder:` call site in `_buildMarkdown` for the full why):
///
///   • Trims trailing whitespace from the captured code body — without
///     this, `gpt_markdown` 1.1.7 leaves a `\n` from the closing-fence
///     match in the body string, which renders as a phantom blank line
///     at the bottom of every block.
///   • Uses tighter padding than `EdgeInsets.all(16)` so short commands
///     (typical agent output is single-line) don't look stranded.
class _AiCodeBlock extends StatefulWidget {
  const _AiCodeBlock({
    required this.name,
    required this.code,
    required this.background,
    required this.foreground,
    required this.lineHeight,
  });

  final String name;
  final String code;
  final Color background;
  final Color foreground;
  final double lineHeight;

  @override
  State<_AiCodeBlock> createState() => _AiCodeBlockState();
}

class _AiCodeBlockState extends State<_AiCodeBlock> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final code = widget.code.replaceFirst(RegExp(r'\s+$'), '');

    final dim = widget.foreground.withValues(alpha: 0.5);
    final showHeader = widget.name.isNotEmpty || code.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: widget.background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
              child: Row(
                children: [
                  if (widget.name.isNotEmpty)
                    Text(
                      widget.name,
                      style: TextStyle(
                        color: dim,
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: code));
                      if (!mounted) return;
                      setState(() => _copied = true);
                      await Future.delayed(const Duration(seconds: 2));
                      if (!mounted) return;
                      setState(() => _copied = false);
                    },
                    icon: Icon(
                      _copied ? Icons.check : Icons.content_copy,
                      size: 12,
                      color: dim,
                    ),
                    label: Text(
                      _copied ? 'Copied' : 'Copy',
                      style: TextStyle(color: dim, fontSize: 11),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 24),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(12, showHeader ? 0 : 8, 12, 8),
            child: SelectableText(
              code,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 13,
                color: widget.foreground,
                height: widget.lineHeight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
