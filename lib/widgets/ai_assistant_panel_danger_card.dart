part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _DangerProposalCard — chat-card UI for a pending [_DangerProposal].
//
// Renders TWO visual variants off the same [_DangerProposal] shape:
//   • `proposal.verdict != null` — a flagged dangerous command.  Red
//     border + warning icon + matched-rule hint; destructive intent is
//     the most consequential UI affordance in the whole panel, so it
//     elevates above the (already-elevated) file-write card.
//   • `proposal.verdict == null` — an ordinary command proposed while
//     auto-execute is off.  Same card shape, neutral blue accent, no
//     rule hint — this is what shows instead of the old bare "Exec"
//     button, so every manual command gets an explicit confirm step.
//
// Visual sibling of [_WriteProposalCard] but stripped down: no diff /
// preview pane (a command line is one line, expanding it would just be
// wasted vertical space) and no reason field (the meaningful signal is
// just yes/no; a rejection feeds a fixed envelope back to the LLM,
// identical for every reject so the model's heuristic is uniform).
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
    final verdict = p.verdict;
    final isDanger = verdict != null;

    // State drives the accent colour exactly like [_WriteProposalCard]:
    // red/blue = pending (please decide — red for a flagged dangerous
    // command, blue for an ordinary one), blue = running, green =
    // approved (ran to completion), muted = rejected (user said no, not
    // an error).
    final accent = switch (p.state) {
      _DangerProposalState.pending =>
        isDanger ? const Color(0xFFFF6E67) : _kAccent,
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
              _buildStateBadge(p.state, accent, isDanger),
              const SizedBox(width: 8),
              Icon(
                isDanger ? Icons.warning_amber_rounded : Icons.terminal,
                color: accent,
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  verdict?.label ?? 'Run this command?',
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
          if (isDanger) ...[
            const SizedBox(height: 6),
            Text(
              // Rule-id hint helps the user correlate a card with the
              // Settings → Safety toggle that produced it.  Stays subtle
              // (dim text, small) — power-user info, not primary content.
              verdict.source == DangerRuleSource.builtin
                  ? 'Built-in rule: ${verdict.patternId.substring(8)}'
                  : 'Custom rule: ${verdict.patternId}',
              style: TextStyle(color: dim, fontSize: 11),
            ),
          ],
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
                    // Danger approval shouldn't look as friendly as an
                    // ordinary "Run" — amber, not green, signals "you
                    // sure?" right up until the click.  Ordinary
                    // commands get the same green the old Exec button
                    // used, so the action still reads as "go".
                    backgroundColor: isDanger
                        ? const Color(0xFFE5C07B)
                        : const Color(0xFF2E7D32),
                    foregroundColor: isDanger ? Colors.black : Colors.white,
                  ),
                  child: Text(isDanger ? 'Run anyway' : 'Run'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStateBadge(
    _DangerProposalState state,
    Color accent,
    bool isDanger,
  ) {
    final label = switch (state) {
      _DangerProposalState.pending => isDanger ? 'DANGEROUS' : 'CONFIRM',
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
