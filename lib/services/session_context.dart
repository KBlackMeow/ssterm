/// Builds the per-conversation `<session_context>` block injected on the
/// first user turn of every fresh agent conversation.
///
/// Lives outside [AiAssistantOverlay] so the format can be unit tested
/// without spinning up a Tab / SshSession harness, and so the per-field
/// gating ("don't emit `Working directory:` when we don't know the cwd")
/// is regression-pinned by tests rather than buried inside widget code.
///
/// Design notes:
///   • Local (not UTC) time + explicit numeric offset.  Shell `date`,
///     log files, and the user's mental model all live in local time;
///     sending UTC would force the model to re-translate every
///     relative-time query.
///   • ISO 8601 string format → unambiguous across providers, with
///     weekday + timezone abbreviation appended for the cases ISO
///     doesn't cover ("next Tuesday", disambiguating `CST` =
///     China Standard Time when the offset is +08:00).
///   • Lives in the SESSION block (per-conversation), NOT the SYSTEM
///     prompt.  The system prompt is process-cached for prompt-cache
///     warmth; embedding a live timestamp there would either freeze
///     at app launch (bad) or invalidate the cache on every call
///     (worse).  Per-conversation injection naturally gets a fresh
///     timestamp each new chat without touching the cached path.
library;

class SessionContext {
  SessionContext._();

  /// Formats [now] as a single-line, model-friendly timestamp:
  ///   `2026-06-08T20:54:00+08:00 (Monday, CST)`
  ///
  /// We intentionally avoid `DateTime.toIso8601String()` because it
  /// emits a trailing `Z` for UTC and otherwise omits the offset entirely
  /// for non-UTC times — both losses for an LLM that needs to do
  /// relative-time math.
  static String formatDateTime(DateTime now) {
    final local = now.toLocal();
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final iso =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}T'
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}'
        '$sign$hh:$mm';
    final tzName = local.timeZoneName;
    if (tzName.isEmpty) return '$iso (${_weekday(local.weekday)})';
    return '$iso (${_weekday(local.weekday)}, $tzName)';
  }

  static String _weekday(int w) => const [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ][w - 1];

  /// Builds the full `<session_context>` XML-style block.
  ///
  /// Always returns a non-empty string — even when every adapter-derived
  /// field is null the date/time line is enough to be worth the few
  /// tokens.  Callers that previously branched on null can simplify;
  /// the legacy `Future<String?>` return shape is preserved at the call
  /// site for backwards safety only.
  ///
  /// Field order matches the order the model is likeliest to read them
  /// in: identity (tab), location (cwd, home), then clock — environment
  /// description before live data, mirroring how `<host_environment>`
  /// is laid out at the bottom of the system prompt.
  static String build({
    String? activeTab,
    String? cwd,
    String? home,
    required DateTime now,
  }) {
    final buf = StringBuffer('<session_context>\n');
    if (activeTab != null && activeTab.isNotEmpty) {
      buf.writeln('Active tab: $activeTab');
    }
    if (cwd != null && cwd.isNotEmpty) {
      buf.writeln('Working directory: $cwd');
    }
    if (home != null && home.isNotEmpty) {
      buf.writeln('HOME: $home');
    }
    buf.writeln('Current date/time: ${formatDateTime(now)}');
    buf.write(
      'Note: relative file-write paths AND `~/…` are resolved against '
      'the working directory shown above by the write_file tool, so '
      'either form is safe to emit. Prefer absolute paths when you '
      'want to write outside the current directory. The date/time above '
      'is your authoritative "now" — use it for relative-time math '
      '("last 7 days", "next Tuesday"), default years in generated '
      'files, and weekday lookups instead of training-data guesses.\n'
      '</session_context>',
    );
    return buf.toString();
  }
}
