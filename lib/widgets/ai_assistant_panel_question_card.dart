part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _QuestionProposalCard — chat-card UI for a pending [_QuestionProposal].
//
// Structured sibling of the bare `[ASK_USER]` marker: the model supplied
// concrete candidate answers (`ask_user_question` tool call), so instead
// of a free-text prompt we render them as a tappable list, with an
// automatic "Other" row appended for anything not on the list. Visual
// sibling of [_DangerProposalCard] — same container / border / badge
// language — but the body is a vertical option list instead of a
// command line + Approve/Reject pair.
// ───────────────────────────────────────────────────────────────────────────

class _QuestionProposalCard extends StatelessWidget {
  const _QuestionProposalCard({
    required this.proposal,
    required this.onOptionSelected,
    required this.onOther,
  });

  final _QuestionProposal proposal;

  /// Called with the tapped option's `label` when the user picks a
  /// regular option row. Not called for "Other" — see [onOther].
  final ValueChanged<String> onOptionSelected;

  /// Called when the user taps the always-present "Other" row.
  final VoidCallback onOther;

  static const _kOtherLabel = 'Other';

  @override
  Widget build(BuildContext context) {
    final p = proposal;
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.7);
    final surface =
        AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    final accent = switch (p.state) {
      _QuestionProposalState.pending => _kAccent,
      _QuestionProposalState.awaitingCustom => _kAccent,
      _QuestionProposalState.answered => const Color(0xFF98C379), // green
      _QuestionProposalState.stale => dim,
    };
    final locked = p.state != _QuestionProposalState.pending;

    return Container(
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.6), width: 1.2),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildStateBadge(p.state, accent),
              const SizedBox(width: 8),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    p.header,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      color: accent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            p.question,
            style: TextStyle(
              color: fg,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          for (final option in p.options)
            _buildOptionRow(
              label: option.label,
              description: option.description,
              selected: p.answerText == option.label,
              accent: accent,
              fg: fg,
              dim: dim,
              enabled: !locked,
              onTap: () => onOptionSelected(option.label),
            ),
          _buildOptionRow(
            label: _kOtherLabel,
            description: 'Type a custom answer',
            selected: p.state == _QuestionProposalState.awaitingCustom,
            accent: accent,
            fg: fg,
            dim: dim,
            enabled: !locked,
            onTap: onOther,
          ),
          if (p.state == _QuestionProposalState.awaitingCustom) ...[
            const SizedBox(height: 6),
            Text(
              'Type your answer in the box below and send it.',
              style: TextStyle(
                color: dim,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (p.state == _QuestionProposalState.stale) ...[
            const SizedBox(height: 6),
            Text(
              'Cancelled — newer conversation started before an answer was given.',
              style: TextStyle(color: dim, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionRow({
    required String label,
    required String description,
    required bool selected,
    required Color accent,
    required Color fg,
    required Color dim,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? accent.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: enabled ? onTap : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected
                    ? accent.withValues(alpha: 0.6)
                    : dim.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: enabled ? fg : dim,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(description, style: TextStyle(color: dim, fontSize: 11)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStateBadge(_QuestionProposalState state, Color accent) {
    final label = switch (state) {
      _QuestionProposalState.pending => 'QUESTION',
      _QuestionProposalState.awaitingCustom => 'ANSWERING…',
      _QuestionProposalState.answered => 'ANSWERED',
      _QuestionProposalState.stale => 'CANCELLED',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
