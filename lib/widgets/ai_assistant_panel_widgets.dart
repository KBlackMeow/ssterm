part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// Small reusable widgets used by the AI assistant panel:
//   • _AgentHeader / _PositionToggle                    — panel header
//   • _ReasoningSection                                  — collapsible thinking
//   • _CommandResultCard / _ExitBadge                    — command output card
//   • _AiCodeBlock                                       — code-fence renderer
//
// Extracted from `ai_assistant_panel.dart` to keep that file under the
// project-wide 1000-line cap.
// ───────────────────────────────────────────────────────────────────────────

// ── Agent header ──────────────────────────────────────────────────────────

class _AgentHeader extends StatelessWidget {
  const _AgentHeader({
    required this.position,
    required this.onClear,
    required this.onNewSession,
    required this.onContinueSession,
    this.onPositionToggle,
  });

  final AiPanelPosition position;
  final VoidCallback onClear;
  final VoidCallback onNewSession;
  final VoidCallback onContinueSession;
  final VoidCallback? onPositionToggle;

  @override
  Widget build(BuildContext context) {
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.6);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 12, color: _kAccent),
          const SizedBox(width: 4),
          const Text(
            'Agent',
            style: TextStyle(
              color: _kAccent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Tooltip(
            message: 'New session',
            child: InkWell(
              onTap: onNewSession,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.add_comment_outlined, size: 14, color: dim),
              ),
            ),
          ),
          Tooltip(
            message: 'Continue session',
            child: InkWell(
              onTap: onContinueSession,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.history_outlined, size: 14, color: dim),
              ),
            ),
          ),
          Tooltip(
            message: 'Clear conversation',
            child: InkWell(
              onTap: onClear,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.delete_outline, size: 14, color: dim),
              ),
            ),
          ),
          if (onPositionToggle != null)
            _PositionToggle(
              position: position,
              onTap: onPositionToggle!,
              color: dim,
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

// ── Reasoning section (collapsible thinking block) ──────────────────────────

class _ReasoningSection extends StatefulWidget {
  final String reasoning;
  final int? tokenCount;
  final bool isExactTokenCount;

  const _ReasoningSection({
    required this.reasoning,
    this.tokenCount,
    this.isExactTokenCount = false,
  });

  @override
  State<_ReasoningSection> createState() => _ReasoningSectionState();
}

class _ReasoningSectionState extends State<_ReasoningSection> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.6);

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
                  style: TextStyle(
                    color: dim,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                if (widget.tokenCount != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    LlmService.reasoningTokenCountLabel(
                      tokenCount: widget.tokenCount!,
                      isExact: widget.isExactTokenCount,
                    ),
                    style: TextStyle(color: dim, fontSize: 11),
                  ),
                ],
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
/// the auto-execute loop runs a command. Mirrors the background stdout/stderr
/// sent to the LLM so the user can spot-check the agent's view of reality.
class _CommandResultCard extends StatefulWidget {
  const _CommandResultCard({
    required this.command,
    required this.output,
    required this.purpose,
    required this.exitCode,
    required this.lastThreeLines,
    required this.running,
    required this.risk,
  });

  final String command;
  final String output;
  final String? purpose;
  final int? exitCode;
  final List<String> lastThreeLines;
  final bool running;
  final CommandRiskAssessment? risk;

  @override
  State<_CommandResultCard> createState() => _CommandResultCardState();
}

class _CommandResultCardState extends State<_CommandResultCard> {
  static const _kCommandCollapsedLines = 3;
  // Nested scrollables break drag-selection inside the chat's SelectionArea,
  // so long output is truncated by line count instead of scrolled.
  static const _kExpandedOutputMaxLines = 200;
  // Running and finished commands share one preview: the last few lines.
  static const _kTailLines = 3;

  // The whole card starts as a one-line header; the body is opt-in.
  bool _cardExpanded = false;
  bool _expanded = false;
  bool _commandExpanded = false;

  @override
  Widget build(BuildContext context) {
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.6);
    final commandStyle = TextStyle(
      color: fg,
      fontSize: 12,
      fontFamily: 'JetBrainsMono',
      height: 1.3,
    );
    final out = widget.running
        ? widget.lastThreeLines.join('\n')
        : widget.output;
    final outputStyle = TextStyle(
      color: dim,
      fontSize: 11,
      fontFamily: 'JetBrainsMono',
      height: 1.35,
    );
    final purpose = widget.purpose?.trim();
    final displayPurpose = purpose == null || purpose.isEmpty
        ? 'AI 未提供'
        : purpose;
    final lines = out.isEmpty ? const <String>[] : out.trimRight().split('\n');
    final tail = lines.length > _kTailLines
        ? lines.sublist(lines.length - _kTailLines)
        : lines;
    // The preview is always the tail; "view all" is the only second tier and
    // exists only once the command has finished.
    final showAll = !widget.running && _expanded;
    final truncated = lines.length > _kExpandedOutputMaxLines
        ? lines.length - _kExpandedOutputMaxLines
        : 0;
    final visible = truncated > 0
        ? lines.sublist(0, _kExpandedOutputMaxLines).join('\n')
        : out;

    return Container(
      decoration: BoxDecoration(
        color: dim.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: dim.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CollapsibleHeader(
            expanded: _cardExpanded,
            onToggle: () => setState(() => _cardExpanded = !_cardExpanded),
            dim: dim,
            leading: [
              _RiskBadge(assessment: widget.risk),
              widget.running
                  ? Text('运行中', style: TextStyle(color: dim, fontSize: 11))
                  : _ExitBadge(exitCode: widget.exitCode),
            ],
            title: '\$ ${widget.command}',
            titleStyle: commandStyle,
          ),
          if (_cardExpanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final text = '\$ ${widget.command}';
                  final painter = TextPainter(
                    text: TextSpan(text: text, style: commandStyle),
                    textDirection: TextDirection.ltr,
                    maxLines: _kCommandCollapsedLines,
                  )..layout(maxWidth: constraints.maxWidth);
                  final commandOverflow = painter.didExceedMaxLines;
                  painter.dispose();
                  final collapsed = commandOverflow && !_commandExpanded;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        text,
                        maxLines: collapsed ? _kCommandCollapsedLines : null,
                        style: commandStyle,
                      ),
                      if (commandOverflow) ...[
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () => setState(
                            () => _commandExpanded = !_commandExpanded,
                          ),
                          child: Text(
                            _commandExpanded
                                ? 'Collapse'
                                : '… show full command',
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
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SelectableText(
                '执行目的：$displayPurpose',
                style: TextStyle(color: dim, fontSize: 11, height: 1.35),
              ),
            ),
            if (out.isNotEmpty) ...[
              Container(height: 1, color: dim.withValues(alpha: 0.12)),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showAll)
                      SelectableText(visible, style: outputStyle)
                    else
                      for (final line in tail)
                        Text(
                          line,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: outputStyle,
                        ),
                    if (showAll && truncated > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '… $truncated more lines truncated',
                        style: TextStyle(
                          color: dim,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                    if (!widget.running && lines.length > _kTailLines) ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: () => setState(() => _expanded = !_expanded),
                        child: Text(
                          _expanded ? '收起' : '查看全部 (${lines.length} 行)',
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
        ],
      ),
    );
  }
}

/// One-line card header: leading badges, a single-line ellipsized title
/// (hidden while expanded, where the body shows it in full) and a chevron.
class _CollapsibleHeader extends StatelessWidget {
  const _CollapsibleHeader({
    required this.expanded,
    required this.onToggle,
    required this.dim,
    required this.leading,
    required this.title,
    required this.titleStyle,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final Color dim;
  final List<Widget> leading;
  final String title;
  final TextStyle titleStyle;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
          child: Row(
            children: [
              for (final widget in leading) ...[
                widget,
                const SizedBox(width: 6),
              ],
              Expanded(
                child: expanded
                    ? const SizedBox.shrink()
                    : Text(
                        title.replaceAll(RegExp(r'\s*\n\s*'), ' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
              ),
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: dim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Result of a built-in read tool: a one-line header (the tool's own
/// path/range line) that expands to the returned text.
class _ToolOutputCard extends StatefulWidget {
  const _ToolOutputCard({required this.data});

  final _ToolOutputData data;

  @override
  State<_ToolOutputCard> createState() => _ToolOutputCardState();
}

class _ToolOutputCardState extends State<_ToolOutputCard> {
  // Nested scrollables break drag-selection inside the chat's SelectionArea,
  // so long output is truncated by line count instead of scrolled.
  static const _kMaxLines = 200;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.6);
    final data = widget.data;
    final icon = switch (data.toolName) {
      'grep_file' => Icons.search,
      'read_output' => Icons.terminal,
      _ => Icons.description_outlined,
    };
    final lines = data.body.isEmpty ? const <String>[] : data.body.split('\n');
    final truncated = lines.length > _kMaxLines ? lines.length - _kMaxLines : 0;
    final visible = truncated > 0
        ? lines.sublist(0, _kMaxLines).join('\n')
        : data.body;

    return Container(
      decoration: BoxDecoration(
        color: dim.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: data.isError
              ? const Color(0xFFFF6E67).withValues(alpha: 0.35)
              : dim.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CollapsibleHeader(
            expanded: _expanded,
            onToggle: () => setState(() => _expanded = !_expanded),
            dim: dim,
            leading: [
              Icon(
                data.isError ? Icons.error_outline : icon,
                size: 14,
                color: data.isError ? const Color(0xFFFF6E67) : dim,
              ),
            ],
            title: data.title,
            titleStyle: TextStyle(color: fg, fontSize: 12),
          ),
          if (_expanded) ...[
            Container(height: 1, color: dim.withValues(alpha: 0.12)),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    data.isError && data.body.isEmpty
                        ? data.content
                        : (data.body.isEmpty ? data.title : visible),
                    style: TextStyle(
                      color: dim,
                      fontSize: 11,
                      fontFamily: 'JetBrainsMono',
                      height: 1.35,
                    ),
                  ),
                  if (truncated > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '… $truncated more lines truncated',
                      style: TextStyle(
                        color: dim,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
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

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({required this.assessment});

  final CommandRiskAssessment? assessment;

  @override
  Widget build(BuildContext context) {
    final level = assessment?.level ?? CommandRiskLevel.warning;
    final style = switch (level) {
      CommandRiskLevel.normal => (label: '普通', color: const Color(0xFF98C379)),
      CommandRiskLevel.warning => (label: '警告', color: const Color(0xFFE5C07B)),
      CommandRiskLevel.dangerous => (
        label: '危险',
        color: const Color(0xFFFF6E67),
      ),
    };
    final upgrade = assessment?.source == CommandRiskSource.hostOverride
        ? 'AI ${assessment?.aiLevel?.name ?? 'unknown'} → host ${assessment!.level.name}. '
        : '';
    return Tooltip(
      message:
          '$upgrade${assessment?.reason ?? '缺少风险分类，按警告处理'} '
          '(source: ${assessment?.source.name ?? 'missingAiFallback'})',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: style.color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          style.label,
          style: TextStyle(
            color: style.color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
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
