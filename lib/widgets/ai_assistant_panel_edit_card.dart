part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _EditProposalCard — chat-card UI for a pending [_EditProposal].
//
// Same Apply/Reject shell as `_WriteProposalCard` (ai_assistant_panel_
// write_card.dart), but the body renders a line-level diff (via
// `computeLineDiff`) instead of a flat content preview, since an edit
// is a targeted change rather than a full-file replacement.
// ───────────────────────────────────────────────────────────────────────────

/// Number of unchanged context lines kept around each change when a run
/// of `equal` lines is long enough to fold.
const _kDiffContextLines = 3;

/// A run of `equal` lines shorter than this is never folded — folding
/// it would save less vertical space than the "N lines unchanged" row
/// itself costs.
const _kDiffFoldThreshold = _kDiffContextLines * 2 + 2;

/// One item in the flattened, fold-aware render list for the diff body.
sealed class _DiffDisplayItem {}

class _DiffLineItem extends _DiffDisplayItem {
  final DiffLine line;
  _DiffLineItem(this.line);
}

class _DiffFoldItem extends _DiffDisplayItem {
  final List<DiffLine> hidden;
  _DiffFoldItem(this.hidden);
}

/// Collapses long runs of unchanged lines in [lines] into
/// [_DiffFoldItem]s, keeping [_kDiffContextLines] lines of context
/// immediately before and after every changed region.  Pure function —
/// no widget state — so it's cheap to recompute on every build.
List<_DiffDisplayItem> _buildDiffDisplayItems(List<DiffLine> lines) {
  final out = <_DiffDisplayItem>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].kind != DiffLineKind.equal) {
      out.add(_DiffLineItem(lines[i]));
      i++;
      continue;
    }
    var j = i;
    while (j < lines.length && lines[j].kind == DiffLineKind.equal) {
      j++;
    }
    final runLength = j - i;
    if (runLength < _kDiffFoldThreshold) {
      for (var k = i; k < j; k++) {
        out.add(_DiffLineItem(lines[k]));
      }
    } else {
      final headEnd = i + _kDiffContextLines;
      final tailStart = j - _kDiffContextLines;
      final atStart = i == 0;
      final atEnd = j == lines.length;
      if (!atStart) {
        for (var k = i; k < headEnd; k++) {
          out.add(_DiffLineItem(lines[k]));
        }
      }
      final foldStart = atStart ? i : headEnd;
      final foldEnd = atEnd ? j : tailStart;
      if (foldEnd > foldStart) {
        out.add(_DiffFoldItem(lines.sublist(foldStart, foldEnd)));
      }
      if (!atEnd) {
        for (var k = tailStart; k < j; k++) {
          out.add(_DiffLineItem(lines[k]));
        }
      }
    }
    i = j;
  }
  return out;
}

class _EditProposalCard extends StatefulWidget {
  const _EditProposalCard({
    required this.proposal,
    required this.onApply,
    required this.onReject,
  });

  final _EditProposal proposal;
  final VoidCallback onApply;
  final void Function({String? reason}) onReject;

  @override
  State<_EditProposalCard> createState() => _EditProposalCardState();
}

class _EditProposalCardState extends State<_EditProposalCard> {
  bool _rejectFormOpen = false;
  final _reasonController = TextEditingController();
  final Set<int> _expandedFolds = {};

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

    final accent = switch (p.state) {
      _EditProposalState.pending => const Color(0xFFE5C07B),
      _EditProposalState.applying => const Color(0xFF61AFEF),
      _EditProposalState.applied => const Color(0xFF98C379),
      _EditProposalState.rejected => dim,
      _EditProposalState.failed => const Color(0xFFFF6E67),
    };

    final diffLines = computeLineDiff(p.currentContent, p.newContent);
    final displayItems = _buildDiffDisplayItems(diffLines);

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
          Row(
            children: [
              _buildStateBadge(p, accent),
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
          if (p.outcomeMessage != null) ...[
            Text(
              p.outcomeMessage!,
              style: TextStyle(color: accent, fontSize: 12),
            ),
            const SizedBox(height: 6),
          ],
          Container(
            constraints: const BoxConstraints(maxHeight: 360),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var idx = 0; idx < displayItems.length; idx++)
                    _buildDisplayItem(displayItems[idx], idx, fg, dim),
                ],
              ),
            ),
          ),
          if (p.state == _EditProposalState.pending ||
              p.state == _EditProposalState.applying) ...[
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
                  onPressed: p.state == _EditProposalState.applying
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
                if (p.state == _EditProposalState.applying)
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

  Widget _buildStateBadge(_EditProposal p, Color accent) {
    final label = switch (p.state) {
      _EditProposalState.pending =>
        p.matchCount > 1 ? 'EDIT ×${p.matchCount}' : 'EDIT',
      _EditProposalState.applying => 'EDITING…',
      _EditProposalState.applied => 'APPLIED',
      _EditProposalState.rejected => 'REJECTED',
      _EditProposalState.failed => 'FAILED',
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

  Widget _buildDisplayItem(
    _DiffDisplayItem item,
    int index,
    Color fg,
    Color dim,
  ) {
    if (item is _DiffFoldItem) {
      final expanded = _expandedFolds.contains(index);
      if (expanded) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in item.hidden) _buildDiffLine(line, fg, dim),
          ],
        );
      }
      return InkWell(
        onTap: () => setState(() => _expandedFolds.add(index)),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: Text(
            '⋯ ${item.hidden.length} unchanged line'
            '${item.hidden.length == 1 ? '' : 's'} — click to expand ⋯',
            style: TextStyle(
              color: dim,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }
    return _buildDiffLine((item as _DiffLineItem).line, fg, dim);
  }

  Widget _buildDiffLine(DiffLine line, Color fg, Color dim) {
    final (bg, prefix, textColor) = switch (line.kind) {
      DiffLineKind.removed => (
          const Color(0x33FF6E67),
          '-',
          const Color(0xFFFF8A85),
        ),
      DiffLineKind.added => (
          const Color(0x3398C379),
          '+',
          const Color(0xFFA8D6A0),
        ),
      DiffLineKind.equal => (Colors.transparent, ' ', dim),
    };
    final lineNo =
        line.oldLineNo?.toString() ?? line.newLineNo?.toString() ?? '';
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${lineNo.padLeft(5)}  ',
              style: TextStyle(
                color: dim.withValues(alpha: 0.6),
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
              ),
            ),
            TextSpan(
              text: '$prefix ${line.text}',
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
