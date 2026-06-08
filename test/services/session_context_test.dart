import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/session_context.dart';

void main() {
  group('SessionContext.formatDateTime', () {
    test('emits ISO 8601 with explicit numeric offset, weekday, tz name', () {
      // 2026-06-08 20:54:00 LOCAL on whatever host runs the test.
      // We construct via `DateTime(...)` (local) so the test observes
      // the host's real offset — same path the production code takes
      // when it calls `DateTime.now().toLocal()`.
      final dt = DateTime(2026, 6, 8, 20, 54, 0);
      final out = SessionContext.formatDateTime(dt);

      // Date + time prefix is offset-independent.
      expect(out, startsWith('2026-06-08T20:54:00'));
      // Numeric offset always present (+HH:MM or -HH:MM).  Trailing `Z`
      // is forbidden: it would force the model to re-translate to local
      // for relative-time math.
      expect(out, matches(RegExp(r'^[\d-]+T[\d:]+[+\-]\d{2}:\d{2} \(')));
      // Weekday — Jun 8 2026 is a Monday in every timezone the test
      // runner can plausibly inhabit (the LOCAL calendar day in TZs
      // from UTC-12 to UTC+14 all land on a Monday for this instant).
      expect(out, contains('(Monday'));
    });

    test('UTC offset renders as +00:00 (NEVER `Z`)', () {
      // Build a UTC instant and convert; toLocal() in the helper
      // re-converts back to whatever offset the host runs at, so we
      // exercise the offset-formatting path directly via a UTC clock.
      final dt = DateTime.utc(2026, 1, 1, 0, 0, 0);
      final out = SessionContext.formatDateTime(dt);
      // We DON'T pin the exact offset (test host could be in any TZ);
      // we only assert that the format is `+HH:MM` or `-HH:MM`, never
      // bare `Z` (which `DateTime.toIso8601String()` would emit for UTC
      // and which the model can't parse uniformly).
      expect(out, isNot(contains('Z ')));
      expect(out, isNot(endsWith('Z')));
      expect(out, matches(RegExp(r'[+\-]\d{2}:\d{2}')));
    });

    test('weekday cycles through all 7 names', () {
      // Pick a known-Monday and sweep forward 7 days; every English
      // weekday name must appear exactly once.  Catches off-by-one
      // bugs in the `_weekday` index (we use 1-indexed `DateTime.weekday`
      // so `Monday = 1`; subtracting 1 to look up in the array is the
      // classic spot a refactor breaks this).
      final monday = DateTime(2026, 6, 8); // verified Monday
      final names = <String>{};
      for (var i = 0; i < 7; i++) {
        final out = SessionContext.formatDateTime(
          monday.add(Duration(days: i)),
        );
        final match = RegExp(r'\((\w+)').firstMatch(out);
        expect(match, isNotNull, reason: 'weekday must appear in parens');
        names.add(match!.group(1)!);
      }
      expect(
        names,
        equals({
          'Monday',
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
          'Sunday',
        }),
      );
    });

    test('zero-pads single-digit month, day, hour, minute, second', () {
      final dt = DateTime(2026, 1, 2, 3, 4, 5);
      final out = SessionContext.formatDateTime(dt);
      expect(out, startsWith('2026-01-02T03:04:05'));
    });
  });

  group('SessionContext.build', () {
    test('full block contains all four fields + the policy note', () {
      final out = SessionContext.build(
        activeTab: 'local — zsh',
        cwd: '/Users/illya/Projects/ssterm',
        home: '/Users/illya',
        now: DateTime(2026, 6, 8, 20, 54, 0),
      );

      expect(out, startsWith('<session_context>\n'));
      expect(out, endsWith('</session_context>'));
      expect(out, contains('Active tab: local — zsh'));
      expect(out, contains('Working directory: /Users/illya/Projects/ssterm'));
      expect(out, contains('HOME: /Users/illya'));
      expect(out, contains('Current date/time: 2026-06-08T20:54:00'));
      // The note is what tells the model to TRUST the clock — without
      // it the model often falls back to training-data dates anyway.
      expect(out, contains('authoritative "now"'));
    });

    test('omits adapter-derived lines when their values are null/empty', () {
      // Settings tab / pre-handshake SSH case — no fs adapter, but the
      // clock is still useful.  This is the new behaviour: previously
      // we returned null in this branch, so the model got no context
      // at all.
      final out = SessionContext.build(
        activeTab: null,
        cwd: null,
        home: null,
        now: DateTime(2026, 6, 8, 20, 54, 0),
      );

      expect(out, isNotNull);
      expect(out, isNot(contains('Active tab:')));
      expect(out, isNot(contains('Working directory:')));
      expect(out, isNot(contains('HOME:')));
      expect(out, contains('Current date/time: 2026-06-08T20:54:00'));
    });

    test('treats empty strings the same as null', () {
      final out = SessionContext.build(
        activeTab: '',
        cwd: '',
        home: '',
        now: DateTime(2026, 6, 8, 20, 54, 0),
      );
      expect(out, isNot(contains('Active tab:')));
      expect(out, isNot(contains('Working directory:')));
      expect(out, isNot(contains('HOME:')));
    });

    test('field order is identity → location → clock', () {
      // Pin the ORDER because the model's attention falls off late in a
      // long message — putting the date/time AFTER cwd/home keeps the
      // "use this clock" reminder physically adjacent to the policy
      // note that anchors it.  If a refactor flips the order, the
      // note's "above" reference would dangle.
      final out = SessionContext.build(
        activeTab: 'tab',
        cwd: '/cwd',
        home: '/home',
        now: DateTime(2026, 6, 8, 20, 54, 0),
      );
      final tabIdx = out.indexOf('Active tab:');
      final cwdIdx = out.indexOf('Working directory:');
      final homeIdx = out.indexOf('HOME:');
      final clockIdx = out.indexOf('Current date/time:');
      expect(tabIdx, lessThan(cwdIdx));
      expect(cwdIdx, lessThan(homeIdx));
      expect(homeIdx, lessThan(clockIdx));
    });
  });
}
