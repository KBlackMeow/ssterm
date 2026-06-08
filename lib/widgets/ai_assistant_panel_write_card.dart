part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _WriteProposalCard — chat-card UI for a pending [_WriteProposal].
//
// Extracted from `ai_assistant_panel.dart` to keep that file under the
// project-wide 1000-line cap.  Stays a private widget because the only
// public surface of this library is [AiAssistantOverlay].
// ───────────────────────────────────────────────────────────────────────────

/// Chat-card UI for an [_WriteProposal].  Shows the proposed file path,
/// the existing-vs-proposed byte / line summary, an expandable diff
/// preview, and Apply / Reject buttons.  Re-renders on state changes
/// because the underlying [_WriteProposal] is mutated in place from
/// `_AiAssistantOverlayState._decideWriteProposal`.
///
/// Visual hierarchy is intentionally heavier than the system command
/// card — file writes are irreversible (no `git restore` for files
/// the agent created from scratch) so we want the card to read as
/// "look at this before clicking", not "another tool output".
class _WriteProposalCard extends StatefulWidget {
  const _WriteProposalCard({
    required this.proposal,
    required this.onApply,
    required this.onReject,
  });

  final _WriteProposal proposal;
  final VoidCallback onApply;
  // Reject takes an optional reason string the user can type before
  // clicking — surfaced in the rejection envelope so the model has
  // context for its next turn ("user said the path was wrong").
  final void Function({String? reason}) onReject;

  @override
  State<_WriteProposalCard> createState() => _WriteProposalCardState();
}

class _WriteProposalCardState extends State<_WriteProposalCard> {
  bool _previewExpanded = false;
  bool _rejectFormOpen = false;
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.7);
    final surface =
        AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    // Visual accent colour switches with the lifecycle state so a glance
    // at the card colour conveys what happened — green = applied,
    // red = failed, amber = pending decision, grey = rejected.
    final accent = switch (p.state) {
      _WriteProposalState.pending => const Color(0xFFE5C07B), // amber
      _WriteProposalState.applying => const Color(0xFF61AFEF), // blue
      _WriteProposalState.applied => const Color(0xFF98C379), // green
      _WriteProposalState.rejected =>
        dim, // muted — user said no, not an error
      _WriteProposalState.failed => const Color(0xFFFF6E67), // red
    };

    final lineCount = const LineSplitter().convert(p.content).length;
    final byteCount = utf8.encode(p.content).length;
    final existingLines = p.preview.existingLines;
    final existingBytes = p.preview.existingSize;

    return Container(
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.5), width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: state badge + path
          Row(
            children: [
              _buildStateBadge(p.state, accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.resolvedPath,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontFamily: 'JetBrainsMono',
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          Text(
            _buildSummaryLine(
              exists: p.preview.exists,
              existingBytes: existingBytes,
              existingLines: existingLines,
              newBytes: byteCount,
              newLines: lineCount,
            ),
            style: TextStyle(color: dim, fontSize: 12),
          ),

          if (p.outcomeMessage != null) ...[
            const SizedBox(height: 6),
            Text(
              p.outcomeMessage!,
              style: TextStyle(color: accent, fontSize: 12),
            ),
          ],
          if (p.result != null) ...[
            const SizedBox(height: 6),
            Text(
              'Wrote ${p.result!.bytesWritten} bytes — '
              '${p.result!.created ? "created" : "updated"} '
              '@ ${p.result!.mtime?.toIso8601String() ?? "—"}',
              style: TextStyle(color: dim, fontSize: 12),
            ),
          ],

          // Preview toggle + body (collapsed by default — a 200-line
          // diff would otherwise dominate the chat scrollback).
          const SizedBox(height: 8),
          InkWell(
            onTap: () => setState(() => _previewExpanded = !_previewExpanded),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    _previewExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 14,
                    color: dim,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _previewExpanded ? 'Hide content' : 'Show content',
                    style: TextStyle(color: dim, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          if (_previewExpanded) ...[
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(4),
              ),
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                child: SelectableText(
                  p.content,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontFamily: 'JetBrainsMono',
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],

          // Action row — only shown while pending.  Once we transition
          // to a terminal state the buttons disappear; the card stays
          // as a transcript record of the decision.
          if (p.state == _WriteProposalState.pending ||
              p.state == _WriteProposalState.applying) ...[
            const SizedBox(height: 10),
            if (_rejectFormOpen) ...[
              TextField(
                controller: _reasonController,
                style: TextStyle(color: fg, fontSize: 12),
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: 'Why? (optional, sent to the model)',
                  hintStyle: TextStyle(
                      color: dim.withValues(alpha: 0.6), fontSize: 12),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: dim.withValues(alpha: 0.3)),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: p.state == _WriteProposalState.applying
                      ? null
                      : () {
                          if (_rejectFormOpen) {
                            widget.onReject(reason: _reasonController.text);
                          } else {
                            setState(() => _rejectFormOpen = true);
                          }
                        },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6E67),
                  ),
                  child: Text(_rejectFormOpen ? 'Send rejection' : 'Reject'),
                ),
                const SizedBox(width: 8),
                if (p.state == _WriteProposalState.applying)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  ElevatedButton(
                    onPressed: widget.onApply,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF98C379),
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Apply'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStateBadge(_WriteProposalState state, Color accent) {
    final label = switch (state) {
      _WriteProposalState.pending =>
        widget.proposal.preview.exists ? 'OVERWRITE' : 'CREATE',
      _WriteProposalState.applying => 'WRITING…',
      _WriteProposalState.applied => 'APPLIED',
      _WriteProposalState.rejected => 'REJECTED',
      _WriteProposalState.failed => 'FAILED',
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

  String _buildSummaryLine({
    required bool exists,
    required int existingBytes,
    required int? existingLines,
    required int newBytes,
    required int newLines,
  }) {
    if (!exists) {
      return 'Will create: $newBytes B, $newLines line${newLines == 1 ? '' : 's'}';
    }
    final lineDelta = existingLines == null
        ? ''
        : ' (Δ ${(newLines - existingLines).abs()} '
            'line${(newLines - existingLines).abs() == 1 ? '' : 's'} '
            '${newLines >= existingLines ? 'added' : 'removed'})';
    return 'Will overwrite: $existingBytes B → $newBytes B, '
        '${existingLines ?? "—"} → $newLines lines$lineDelta';
  }
}
