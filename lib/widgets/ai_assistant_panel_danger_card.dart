part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _DangerProposalCard — chat-card UI for a pending [_DangerProposal].
//
// Visual sibling of [_WriteProposalCard] but stripped down:
//   • No diff / preview pane — a command line is one line, expanding it
//     would just be wasted vertical space.
//   • No reason field — for a destructive command the meaningful signal
//     is just yes/no.  A rejection feeds a fixed "[Dangerous command
//     rejected by user]" envelope back to the LLM, identical for every
//     reject so the model's heuristic is uniform.
//   • Red-tinted border + warning icon — destructive intent is the most
//     consequential UI affordance in the whole panel; the chat-card
//     hierarchy explicitly elevates this above the (already-elevated)
//     file-write card.
// ───────────────────────────────────────────────────────────────────────────

class _DangerProposalCard extends StatelessWidget {
  const _DangerProposalCard({
    required this.proposal,
    required this.onApprove,
    required this.onReject,
  });

  final _DangerProposal proposal;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final p = proposal;
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.7);
    final surface =
        AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    // State drives the accent colour exactly like [_WriteProposalCard]:
    // amber = pending (please decide), blue = running, green = approved
    // (ran to completion), muted = rejected (user said no, not an error).
    final accent = switch (p.state) {
      _DangerProposalState.pending => const Color(0xFFFF6E67), // red — pre-decision
      _DangerProposalState.running => const Color(0xFF61AFEF), // blue
      _DangerProposalState.ran => const Color(0xFF98C379), // green
      _DangerProposalState.rejected => dim,
    };

    return Container(
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        // Slightly thicker border than the write-card to keep the
        // hierarchy honest — destructive > irreversible-write > info.
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
              Icon(Icons.warning_amber_rounded, color: accent, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  p.verdict.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // The actual command — monospace, selectable so the user can
          // copy-paste it into a different terminal to inspect first.
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: SelectableText(
              p.command,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            // Rule-id hint helps the user correlate a card with the
            // Settings → Safety toggle that produced it.  Stays subtle
            // (dim text, small) — power-user info, not primary content.
            p.verdict.source == DangerRuleSource.builtin
                ? 'Built-in rule: ${p.verdict.patternId.substring(8)}'
                : 'Custom rule: ${p.verdict.patternId}',
            style: TextStyle(color: dim, fontSize: 11),
          ),
          if (p.state == _DangerProposalState.pending) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onReject,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6E67),
                  ),
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: onApprove,
                  style: ElevatedButton.styleFrom(
                    // Approving a dangerous command shouldn't look as
                    // friendly as "Apply" on a file-write — amber, not
                    // green, signals "you sure?" right up until the
                    // click.
                    backgroundColor: const Color(0xFFE5C07B),
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Run anyway'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStateBadge(_DangerProposalState state, Color accent) {
    final label = switch (state) {
      _DangerProposalState.pending => 'DANGEROUS',
      _DangerProposalState.running => 'RUNNING…',
      _DangerProposalState.ran => 'APPROVED',
      _DangerProposalState.rejected => 'REJECTED',
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
