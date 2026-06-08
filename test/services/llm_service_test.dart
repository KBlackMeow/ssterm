import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/services/llm_service.dart';
import 'package:ssterm/services/skill_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('LlmService.extractCommands', () {
    test('extracts a single bash block', () {
      const input = '''
Here is the command:

```bash
ls -la
```
''';
      expect(LlmService.extractCommands(input), equals(['ls -la']));
    });

    test('IGNORES untagged code blocks (regression — previous regex used `?`)', () {
      // The LLM might emit a plain ``` block for warnings, JSON, diff
      // output, etc.  Executing those as shell commands would be a
      // foot-gun (`command not found: warning`).
      const input = '''
Here is some output:

```
WARNING: file not found
```

And the actual command:

```bash
ls /tmp
```
''';
      expect(LlmService.extractCommands(input), equals(['ls /tmp']));
    });

    test('case-insensitive language tags (Bash, SH, ZSH all valid)', () {
      const input = '''
```Bash
echo a
```

```SH
echo b
```

```ZSH
echo c
```
''';
      expect(
        LlmService.extractCommands(input),
        equals(['echo a', 'echo b', 'echo c']),
      );
    });

    test('strips pseudo-prompt prefixes (\$ , # , > )', () {
      const input = '''
```bash
\$ ls -la
# whoami
> echo continuation
```
''';
      expect(
        LlmService.extractCommands(input),
        equals(['ls -la\nwhoami\necho continuation']),
      );
    });

    test('preserves \$VAR expansions and \$() substitutions', () {
      // `\$ ` (dollar + space) is a prompt; `\$HOME` (dollar + identifier)
      // is a variable expansion — must not be touched.
      const input = '''
```bash
echo \$HOME
echo "\$(date)"
```
''';
      expect(
        LlmService.extractCommands(input),
        equals(['echo \$HOME\necho "\$(date)"']),
      );
    });

    test('skips empty bodies', () {
      const input = '''
```bash
```

```bash
real cmd
```
''';
      expect(LlmService.extractCommands(input), equals(['real cmd']));
    });

    test('strips OUR injected hint suffix when LLM echoes it back', () {
      // Defensive: the LLM might echo prompt fragments verbatim.  Make
      // sure that doesn't somehow show up as a runnable command.
      const input = '''
Working on it.

```bash
true
```

[TASK_COMPLETE]
''';
      expect(LlmService.extractCommands(input), equals(['true']));
    });

    test('EXACT duplicate commands across two blocks are deduplicated '
        '(REGRESSION: ifconfig ran twice)', () {
      // Real-world failure: model emitted the same command in two
      // separate ```bash``` fences (an "explanation" block and a "let
      // me run this" block), and the auto-execute loop ran it twice
      // back-to-back.  Dedupe by exact string, preserve first-seen
      // order.
      const input = '''
First, let me show you the command:

```bash
ifconfig | grep "inet "
```

Now I'll run it:

```bash
ifconfig | grep "inet "
```
''';
      expect(LlmService.extractCommands(input),
          equals(['ifconfig | grep "inet "']));
    });

    test('NEAR-duplicates (different whitespace / args) are NOT deduplicated',
        () {
      // Distinct commands stay distinct — only EXACT post-strip matches
      // collapse, otherwise we'd mask legitimate "almost the same but
      // not quite" pairs (e.g. `ls` and `ls -la`).
      const input = '''
```bash
ls
```

```bash
ls -la
```
''';
      expect(LlmService.extractCommands(input), equals(['ls', 'ls -la']));
    });

    test('untagged ``` block with `rm -rf /tmp` is NOT executed', () {
      // Real-world worst case: LLM puts a destructive example inside a
      // generic ``` block as illustration.  We must NOT execute it.
      const input = '''
For example, you could run:

```
rm -rf /tmp/some-dir
```

But instead, do this safely:

```bash
ls /tmp/some-dir
```
''';
      expect(
        LlmService.extractCommands(input),
        equals(['ls /tmp/some-dir']),
      );
    });
  });

  group('LlmService completion markers', () {
    test('plain [TASK_COMPLETE] is detected and stripped', () {
      const input = 'All done.\n\n[TASK_COMPLETE]';
      expect(LlmService.hasTaskCompleteMarker(input), isTrue);
      expect(LlmService.stripCompletionMarkers(input), equals('All done.'));
    });

    test('markdown-emphasised **[TASK_COMPLETE]** is fully removed', () {
      // Real-world failure: model wraps the marker in bold so the literal
      // `replaceAll('[TASK_COMPLETE]', '')` left dangling `**` in the
      // chat bubble.
      const input = 'Finished.\n\n**[TASK_COMPLETE]**';
      expect(LlmService.hasTaskCompleteMarker(input), isTrue);
      expect(LlmService.stripCompletionMarkers(input), equals('Finished.'));
    });

    test('case- and space-insensitive: [Task Complete] still detected', () {
      const input = 'OK.\n\n[Task Complete]';
      expect(LlmService.hasTaskCompleteMarker(input), isTrue);
      expect(LlmService.stripCompletionMarkers(input), equals('OK.'));
    });

    test('[ASK_USER] in single-asterisk italics is removed', () {
      const input = 'Need a decision.\n\n*[ASK_USER]*';
      expect(LlmService.hasAskUserMarker(input), isTrue);
      expect(LlmService.stripCompletionMarkers(input),
          equals('Need a decision.'));
    });

    test('multiple consecutive blank lines collapse after stripping', () {
      const input = 'A\n\n\n\n[TASK_COMPLETE]\n\n\nB';
      final stripped = LlmService.stripCompletionMarkers(input);
      // No marker, no triple-blanks, content preserved.
      expect(stripped.contains('TASK_COMPLETE'), isFalse);
      expect(stripped.contains('\n\n\n'), isFalse);
      expect(stripped.contains('A'), isTrue);
      expect(stripped.contains('B'), isTrue);
    });

    test('text without any marker passes through unchanged', () {
      const input = 'Just chatting.\n\nNo markers here.';
      expect(LlmService.hasTaskCompleteMarker(input), isFalse);
      expect(LlmService.hasAskUserMarker(input), isFalse);
      expect(LlmService.stripCompletionMarkers(input), equals(input));
    });

    test('a marker glued to surrounding prose is still detected', () {
      // Models occasionally write `done [TASK_COMPLETE]` without the
      // suggested newline.  We must still detect AND strip it.
      const input = 'Everything passed [TASK_COMPLETE]';
      expect(LlmService.hasTaskCompleteMarker(input), isTrue);
      final stripped = LlmService.stripCompletionMarkers(input);
      expect(stripped.contains('TASK_COMPLETE'), isFalse);
      expect(stripped.startsWith('Everything passed'), isTrue);
    });
  });

  group('LlmService.stripStreamingMarkers', () {
    // The streaming variant runs on every SSE chunk so it has to handle
    // *partial* markers — `[`, `[T`, `[TASK_COMP`, … — that the post-stream
    // strip never sees because the closing `]` always arrives before then.
    test('hides a complete [TASK_COMPLETE] mid-stream', () {
      const input = 'All done.\n\n[TASK_COMPLETE]';
      expect(LlmService.stripStreamingMarkers(input), equals('All done.\n\n'));
    });

    test('hides a partial trailing `[` (could be either marker)', () {
      const input = 'Almost there.\n\n[';
      expect(
          LlmService.stripStreamingMarkers(input), equals('Almost there.\n\n'));
    });

    test('hides `[TASK_COM` — definitely a marker prefix', () {
      const input = 'Done.\n\n[TASK_COM';
      expect(LlmService.stripStreamingMarkers(input), equals('Done.\n\n'));
    });

    test('hides `[ASK_US` — partial ASK_USER prefix', () {
      const input = 'Need input?\n\n[ASK_US';
      expect(
          LlmService.stripStreamingMarkers(input), equals('Need input?\n\n'));
    });

    test('hides `**[TASK` — markdown-emphasised partial', () {
      const input = 'Yes.\n\n**[TASK';
      expect(LlmService.stripStreamingMarkers(input), equals('Yes.\n\n'));
    });

    test('does NOT hide a CLOSED markdown link earlier in the text', () {
      // `[See here](url)` contains `]` so it is NOT a trailing partial.
      const input = 'See [here](https://x) for details.';
      expect(LlmService.stripStreamingMarkers(input), equals(input));
    });

    test('does NOT hide non-marker partials (e.g. a code reference)', () {
      // Tail `[See` cannot be a prefix of TASK_COMPLETE / ASK_USER, so leave
      // it intact — false-hiding markdown text would be worse than briefly
      // showing a marker.
      const input = 'Look at the [See';
      expect(LlmService.stripStreamingMarkers(input), equals(input));
    });

    test('preserves trailing whitespace (no jitter during streaming)', () {
      // Unlike the post-stream strip, we deliberately do NOT collapse blank
      // lines or trim — that would jitter as new tokens arrive.
      const input = 'A\n\n\n\nB\n';
      expect(LlmService.stripStreamingMarkers(input), equals(input));
    });

    test('idempotent — running twice yields the same result', () {
      const input = 'Done.\n\n[TASK_COMP';
      final once = LlmService.stripStreamingMarkers(input);
      final twice = LlmService.stripStreamingMarkers(once);
      expect(once, equals(twice));
    });
  });

  group('LlmService.systemPromptFor', () {
    // The system prompt is the heaviest reusable thing on every turn.
    // These tests pin the cache-key shape so we can't accidentally
    // regress prompt-cache hit rate by introducing a per-call timestamp,
    // random nonce, or other instability.
    setUp(() {
      LlmService.refreshSystemPrompt();
    });

    test('repeated calls with the same whitelist return the SAME string',
        () {
      // Identity check (`identical`) proves the cache is hot — the
      // builder isn't running on every call.  This is what makes the
      // Anthropic prefix cache stay warm.
      final a = LlmService.systemPromptFor(enabledSkillIds: {'x'});
      final b = LlmService.systemPromptFor(enabledSkillIds: {'x'});
      expect(identical(a, b), isTrue);
    });

    test('toggling the whitelist invalidates the cache once', () {
      final a = LlmService.systemPromptFor(enabledSkillIds: <String>{});
      final b = LlmService.systemPromptFor(enabledSkillIds: null);
      // Different shape, so different bytes; but the new value sticks.
      expect(identical(a, b), isFalse);
      final c = LlmService.systemPromptFor(enabledSkillIds: null);
      expect(identical(b, c), isTrue);
    });

    test('refreshSystemPrompt forces a fresh build', () {
      final a = LlmService.systemPromptFor(enabledSkillIds: null);
      LlmService.refreshSystemPrompt();
      final b = LlmService.systemPromptFor(enabledSkillIds: null);
      // Content equal but NOT identical — the cache slot was wiped.
      expect(a, equals(b));
      expect(identical(a, b), isFalse);
    });

    test('disabled set never embeds <skills_protocol>', () async {
      // With NO skills enabled, the `<skills_protocol>` block must be
      // omitted entirely so the model isn't tempted to emit USE_SKILL
      // markers for something it can't reach.
      final prompt =
          LlmService.systemPromptFor(enabledSkillIds: <String>{});
      expect(prompt.contains('<skills_protocol>'), isFalse);
    });
  });

  group('LlmService skills + AgentConfig wiring', () {
    test('AgentConfig.enabledSkills round-trips through JSON', () {
      final cfg = AgentConfig(
        enabledSkills: {'git-bisect', 'verify-fix'},
      );
      final json = cfg.toJson();
      // Sorted-list serialisation keeps the on-disk diff stable when
      // unrelated settings change — verify the order here so a future
      // refactor doesn't drop it.
      expect(json['enabledSkills'], equals(['git-bisect', 'verify-fix']));

      final decoded = AgentConfig.fromJson(json);
      expect(decoded.enabledSkills, equals({'git-bisect', 'verify-fix'}));
    });

    test('AgentConfig with null enabledSkills omits the key', () {
      final cfg = AgentConfig();
      expect(cfg.toJson().containsKey('enabledSkills'), isFalse);
    });

    test('copyWith(resetEnabledSkills: true) restores the null sentinel',
        () {
      final cfg = AgentConfig(enabledSkills: {'git-bisect'});
      final reset = cfg.copyWith(resetEnabledSkills: true);
      expect(reset.enabledSkills, isNull);
      // The explicit value should NOT survive when reset is requested,
      // even if both are passed (reset takes precedence).
      final both =
          cfg.copyWith(enabledSkills: {'x'}, resetEnabledSkills: true);
      expect(both.enabledSkills, isNull);
    });

    test('SkillService.userSkillsDirPath honours the debug override', () {
      // The override is what makes the user-dir scan unit-testable —
      // assert the getter actually exposes it instead of always
      // computing the real ~/.ssterm/skills path.
      SkillService.debugUserSkillsDirOverride = '/tmp/my-test-skills';
      expect(SkillService.userSkillsDirPath, equals('/tmp/my-test-skills'));
      SkillService.debugUserSkillsDirOverride = null;
      expect(SkillService.userSkillsDirPath.endsWith('/.ssterm/skills'),
          isTrue);
    });
  });
}
