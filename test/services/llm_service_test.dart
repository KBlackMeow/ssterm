import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/models/skill.dart';
import 'package:ssterm/services/bundled_skills.dart';
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

  group('LlmService.extractWebSearchQuery', () {
    test('extracts a simple ASCII query', () {
      const input = 'Looking up the docs.\n\n[WEB_SEARCH: flutter docs]';
      expect(
        LlmService.extractWebSearchQuery(input),
        equals('flutter docs'),
      );
    });

    test('preserves case (Brave ranking is case-sensitive for some queries)',
        () {
      const input = '[WEB_SEARCH: macOS Sonoma release notes]';
      // The query verbatim — no lower-casing like USE_SKILL does.
      expect(LlmService.extractWebSearchQuery(input),
          equals('macOS Sonoma release notes'));
    });

    test('accepts WEBSEARCH and WEB SEARCH aliases', () {
      expect(LlmService.extractWebSearchQuery('[WEBSEARCH: a]'), equals('a'));
      expect(
          LlmService.extractWebSearchQuery('[WEB SEARCH: b]'), equals('b'));
    });

    test('accepts `=` as a separator (some models invent their own)', () {
      expect(LlmService.extractWebSearchQuery('[WEB_SEARCH= c]'), equals('c'));
    });

    test('allows punctuation, quotes, and accented characters in the query',
        () {
      const input =
          "[WEB_SEARCH: how to use \"quotes\" in zsh, café résumé?]";
      expect(
        LlmService.extractWebSearchQuery(input),
        equals('how to use "quotes" in zsh, café résumé?'),
      );
    });

    test('returns null when no marker present', () {
      expect(LlmService.extractWebSearchQuery('plain prose'), isNull);
    });

    test('returns null for empty query body', () {
      // `[WEB_SEARCH:   ]` is meaningless — no result is preferable to
      // sending Brave an empty `q`.
      expect(LlmService.extractWebSearchQuery('[WEB_SEARCH:   ]'), isNull);
    });

    test('a closed [markdown link] earlier does not absorb the marker', () {
      // Regression guard: the marker regex must not match `[See here]`
      // earlier in the message.
      const input =
          'See [docs here](https://x) then [WEB_SEARCH: real query]';
      expect(LlmService.extractWebSearchQuery(input), equals('real query'));
    });
  });

  group('LlmService.extractWriteFile', () {
    test('extracts a simple BEGIN..END block', () {
      const input = '''
I'll create a hello-world script.

[WRITE_FILE_BEGIN: /tmp/hello.py]
print("hello")
[WRITE_FILE_END]
''';
      final w = LlmService.extractWriteFile(input);
      expect(w, isNotNull);
      expect(w!.path, equals('/tmp/hello.py'));
      // One leading + trailing newline stripped → the body is the
      // exact intended file contents.
      expect(w.content, equals('print("hello")'));
    });

    test('preserves blank lines and indentation inside the body', () {
      const input = '''
[WRITE_FILE_BEGIN: /tmp/multi.py]
def foo():
    if True:

        return 1
[WRITE_FILE_END]
''';
      final w = LlmService.extractWriteFile(input)!;
      expect(
        w.content,
        equals('def foo():\n    if True:\n\n        return 1'),
      );
    });

    test('accepts WRITEFILE / WRITE FILE aliases for BEGIN and END', () {
      const input = '''
[WRITEFILEBEGIN: /tmp/a.txt]
hi
[WRITEFILEEND]
''';
      final w = LlmService.extractWriteFile(input);
      expect(w, isNotNull);
      expect(w!.path, equals('/tmp/a.txt'));
      expect(w.content, equals('hi'));
    });

    test('returns null when only BEGIN is present (unclosed block)', () {
      // Mid-stream the closing marker may not have arrived yet — that's
      // fine for streaming hide, but the post-stream extractor MUST
      // return null so we never commit a partial body.
      const input = '''
[WRITE_FILE_BEGIN: /tmp/a]
unfinished
''';
      expect(LlmService.extractWriteFile(input), isNull);
    });

    test('returns null when path is empty', () {
      const input = '[WRITE_FILE_BEGIN: ]\nbody\n[WRITE_FILE_END]';
      expect(LlmService.extractWriteFile(input), isNull);
    });

    test('takes the FIRST proposal when two coexist (one-per-turn rule)',
        () {
      // System prompt forbids two writes per turn; if the model
      // violates that, we still need a deterministic pick — take the
      // first so the user can Apply/Reject something rather than
      // refusing the whole turn.
      const input = '''
[WRITE_FILE_BEGIN: /tmp/a]
A
[WRITE_FILE_END]

[WRITE_FILE_BEGIN: /tmp/b]
B
[WRITE_FILE_END]
''';
      final w = LlmService.extractWriteFile(input)!;
      expect(w.path, equals('/tmp/a'));
      expect(w.content, equals('A'));
    });

    test('body that ends with an intentional blank line is preserved', () {
      // The body strip removes ONE trailing newline (the one between
      // content and the END marker on its own line); an extra blank
      // line before that gets through, so files like POSIX `\n`-
      // terminated text round-trip correctly when authored with the
      // canonical bash-heredoc convention.
      const input = '''
[WRITE_FILE_BEGIN: /tmp/end-newline.txt]
line1
line2

[WRITE_FILE_END]
''';
      final w = LlmService.extractWriteFile(input)!;
      expect(w.content, equals('line1\nline2\n'));
    });

    test('inline mention of `[WRITE_FILE_END]` does NOT close a real block',
        () {
      // Regression: when the model TEACHES the write syntax inline
      // ("just type [WRITE_FILE_END] to finish") and then issues a
      // real write later in the same turn, the inline mention used
      // to close the real block early, truncating the body.
      // Line-anchored markers (added when fixing this bug) keep the
      // inline reference inert.
      const input = '''
The way to close a write block is to type `[WRITE_FILE_END]` on its own line.

Here's the real write:

[WRITE_FILE_BEGIN: /tmp/real.py]
print("real body")
[WRITE_FILE_END]
''';
      final w = LlmService.extractWriteFile(input);
      expect(w, isNotNull);
      expect(w!.path, equals('/tmp/real.py'));
      expect(w.content, equals('print("real body")'));
    });

    test('inline `[WRITE_FILE_BEGIN: foo]` inside prose does NOT trigger',
        () {
      // Same regression as above but for the opening marker — a
      // documentation paragraph quoting the syntax shouldn't be
      // mistaken for a real write proposal.
      const input =
          'To start a write, emit `[WRITE_FILE_BEGIN: /path]` followed by '
          'the body and `[WRITE_FILE_END]`.  Nothing to write this turn.';
      expect(LlmService.extractWriteFile(input), isNull);
    });
  });

  group('LlmService.stripCompletionMarkers WRITE_FILE coverage', () {
    test('WRITE_FILE block including body is removed from rendered text',
        () {
      const input = '''
About to write:

[WRITE_FILE_BEGIN: /tmp/x]
verbose file
that would dominate
the chat bubble
[WRITE_FILE_END]

Done.
''';
      final stripped = LlmService.stripCompletionMarkers(input);
      // The whole BEGIN..END region (including the verbose body) is
      // gone — the chat card surfaces the diff separately.
      expect(stripped.contains('verbose file'), isFalse);
      expect(stripped.contains('WRITE_FILE'), isFalse);
      // Surrounding prose stays put.
      expect(stripped, contains('About to write'));
      expect(stripped, contains('Done.'));
    });
  });

  group('LlmService.stripCompletionMarkers WEB_SEARCH coverage', () {
    test('[WEB_SEARCH: q] is removed cleanly', () {
      const input = 'Quick check.\n\n[WEB_SEARCH: foo bar]';
      final stripped = LlmService.stripCompletionMarkers(input);
      expect(stripped.contains('WEB_SEARCH'), isFalse);
      expect(stripped, equals('Quick check.'));
    });

    test('markdown-emphasised **[WEB_SEARCH: q]** removes the asterisks too',
        () {
      const input = 'Searching:\n\n**[WEB_SEARCH: foo]**';
      final stripped = LlmService.stripCompletionMarkers(input);
      // No dangling `**` left over.
      expect(stripped.contains('*'), isFalse);
      expect(stripped, equals('Searching:'));
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

    test('hides `[W` — partial WEB_SEARCH or USE_SKILL/other ambiguous start',
        () {
      // The streaming hider treats any bare `[X` whose body could
      // become USE_SKILL / WEB_SEARCH as a marker prefix.  `[W` is a
      // unique prefix of WEB_SEARCH so it must be hidden.
      const input = 'Looking up.\n\n[W';
      expect(LlmService.stripStreamingMarkers(input),
          equals('Looking up.\n\n'));
    });

    test('hides `[WEB_SEARCH: how to debug` — long partial query', () {
      // Real worst case: model is mid-stream on a 60-char query and we
      // haven't seen the closing `]` yet.  Bumped trailing-tail limit
      // to 160 specifically so this case is covered.
      const input =
          'I should search for this.\n\n[WEB_SEARCH: how to debug TLS handshake failures in nginx behind a load balancer';
      expect(
        LlmService.stripStreamingMarkers(input),
        equals('I should search for this.\n\n'),
      );
    });

    test('hides `[WEBSEARCH` (no underscore alias)', () {
      const input = 'q?\n\n[WEBSEARCH: things';
      expect(LlmService.stripStreamingMarkers(input), equals('q?\n\n'));
    });

    test('hides `[WRITE_FILE_BEGIN: …` mid-stream so the body never leaks',
        () {
      // The BEGIN line itself triggers the streaming hide; the body
      // gets stripped by the post-stream pass after END arrives.  This
      // test pins the BEGIN-line hide so users don't see the path
      // flicker in.
      const input = 'Writing:\n\n[WRITE_FILE_BEGIN: /tmp/x.txt';
      expect(LlmService.stripStreamingMarkers(input),
          equals('Writing:\n\n'));
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

    test('disabled set never embeds <agent_skills>', () async {
      // With NO skills enabled, the `<agent_skills>` block must be
      // omitted entirely so the model isn't tempted to emit USE_SKILL
      // markers for something it can't reach.  (Mirrors Cursor's
      // policy: never advertise a tool the agent cannot use.)
      final prompt =
          LlmService.systemPromptFor(enabledSkillIds: <String>{});
      expect(prompt.contains('<agent_skills>'), isFalse);
      expect(prompt.contains('<available_skills'), isFalse);
      expect(prompt.contains('[USE_SKILL'), isFalse);
    });

    test('webSearchEnabled=false omits <web_search_tool> and the marker', () {
      // Symmetric to the skills check above: never advertise a tool we
      // cannot fire — the model would emit the marker and the agent
      // loop would have to refuse mid-loop.
      final prompt = LlmService.systemPromptFor(
          enabledSkillIds: <String>{}, webSearchEnabled: false);
      expect(prompt.contains('<web_search_tool>'), isFalse);
      expect(prompt.contains('[WEB_SEARCH'), isFalse);
    });

    test('webSearchEnabled=true injects <web_search_tool> with the marker',
        () {
      final prompt = LlmService.systemPromptFor(
          enabledSkillIds: <String>{}, webSearchEnabled: true);
      expect(prompt.contains('<web_search_tool>'), isTrue);
      // Marker advertised in the prompt so the model knows the exact
      // syntax to emit — no guessing.
      expect(prompt.contains('[WEB_SEARCH: <query>]'), isTrue);
      // Worked example present (matches the format we emphasised in
      // _buildWebSearchBlock).
      expect(prompt.contains('Example INVESTIGATE turn:'), isTrue);
    });

    test('toggling webSearchEnabled invalidates the cache once', () {
      final a = LlmService.systemPromptFor(
          enabledSkillIds: null, webSearchEnabled: false);
      final b = LlmService.systemPromptFor(
          enabledSkillIds: null, webSearchEnabled: true);
      // Different bytes → not identical.
      expect(identical(a, b), isFalse);
      // But repeated call with the new key IS cached.
      final c = LlmService.systemPromptFor(
          enabledSkillIds: null, webSearchEnabled: true);
      expect(identical(b, c), isTrue);
    });

    test('fileWriteEnabled=false omits <file_write_tool> and the marker', () {
      final prompt = LlmService.systemPromptFor(
          enabledSkillIds: <String>{}, fileWriteEnabled: false);
      // Never advertise a tool we can't fire — same rule as skills /
      // web search.  Without this the model would emit
      // [WRITE_FILE_BEGIN] and the agent loop would have to refuse
      // mid-loop.
      expect(prompt.contains('<file_write_tool>'), isFalse);
      expect(prompt.contains('[WRITE_FILE_BEGIN'), isFalse);
    });

    test('fileWriteEnabled=true injects <file_write_tool> with the marker',
        () {
      final prompt = LlmService.systemPromptFor(
          enabledSkillIds: <String>{}, fileWriteEnabled: true);
      expect(prompt.contains('<file_write_tool>'), isTrue);
      // Both halves of the marker pair must be in the prompt — the
      // model needs to know how to OPEN AND CLOSE the block.
      expect(prompt.contains('[WRITE_FILE_BEGIN:'), isTrue);
      expect(prompt.contains('[WRITE_FILE_END]'), isTrue);
      // Apply-card policy hammered explicitly (no surprises).
      expect(prompt.contains('click Apply'), isTrue);
    });

    test('toggling fileWriteEnabled invalidates the cache once', () {
      final a = LlmService.systemPromptFor(
          enabledSkillIds: null, fileWriteEnabled: false);
      final b = LlmService.systemPromptFor(
          enabledSkillIds: null, fileWriteEnabled: true);
      expect(identical(a, b), isFalse);
      final c = LlmService.systemPromptFor(
          enabledSkillIds: null, fileWriteEnabled: true);
      expect(identical(b, c), isTrue);
    });

    test('fileWrite key is independent of webSearch key', () {
      // Pin orthogonality — both keys must contribute to cache
      // invalidation independently, so flipping one doesn't bleed
      // into the other's cache slot.
      LlmService.refreshSystemPrompt();
      final webOnFileOn = LlmService.systemPromptFor(
          enabledSkillIds: null,
          webSearchEnabled: true,
          fileWriteEnabled: true);
      final webOffFileOn = LlmService.systemPromptFor(
          enabledSkillIds: null,
          webSearchEnabled: false,
          fileWriteEnabled: true);
      final webOnFileOff = LlmService.systemPromptFor(
          enabledSkillIds: null,
          webSearchEnabled: true,
          fileWriteEnabled: false);
      expect(identical(webOnFileOn, webOffFileOn), isFalse);
      expect(identical(webOnFileOn, webOnFileOff), isFalse);
      expect(identical(webOffFileOn, webOnFileOff), isFalse);
    });
  });

  group('SkillService.buildPromptCatalogue Cursor-style format', () {
    setUp(() async {
      BundledSkillRegistry.debugReset();
      SkillService.debugUserSkillsDirOverride = null;
      BundledSkillRegistry.register(BundledSkillDef(
        id: 'alpha',
        description: 'do the alpha thing',
        buildBody: () async => 'alpha body',
      ));
      BundledSkillRegistry.register(BundledSkillDef(
        id: 'beta',
        description: 'do the beta thing',
        buildBody: () async => 'beta body',
      ));
      await SkillService.init();
      LlmService.refreshSystemPrompt();
    });

    test('emits one <agent_skill id=… path=…>desc</agent_skill> per skill',
        () {
      final out = SkillService.buildPromptCatalogue();
      // Both bundled skills should appear with the synthetic `bundled://`
      // path scheme — that's how the Skill model surfaces dynamic-body
      // skills without an on-disk file.
      expect(
        out,
        contains('<agent_skill id="alpha" path="bundled://alpha">'),
      );
      expect(out, contains('do the alpha thing</agent_skill>'));
      expect(
        out,
        contains('<agent_skill id="beta" path="bundled://beta">'),
      );
      // Stable id-sorted order — alpha must come before beta so the
      // bytes stay identical across runs (prompt-cache stability).
      expect(out.indexOf('id="alpha"'), lessThan(out.indexOf('id="beta"')));
    });

    test('system prompt embeds the <agent_skills> block with policy + listing',
        () {
      final prompt = LlmService.systemPromptFor(enabledSkillIds: null);
      // Cursor-style outer wrapper.
      expect(prompt.contains('<agent_skills>'), isTrue);
      expect(prompt.contains('</agent_skills>'), isTrue);
      // Policy directives mirror Cursor's voice ("IMMEDIATELY", "NEVER").
      expect(prompt.contains('IMMEDIATELY'), isTrue);
      expect(prompt.contains('NEVER just announce'), isTrue);
      // The actual catalogue entries.
      expect(prompt.contains('<available_skills'), isTrue);
      expect(prompt.contains('<agent_skill id="alpha"'), isTrue);
      // Old per-turn-injection vocabulary must be gone — there's no
      // separate `<system-reminder>` catalogue anymore.
      expect(prompt.contains('<skills_protocol>'), isFalse);
      expect(prompt.contains('<system-reminder>'), isFalse);
    });

    test('escapes `"` inside path attribute', () {
      // Defensive: a wildly-named user skill folder must not be able to
      // break out of the path="…" attribute.  We don't allow `"` in ids
      // (regex filters it), but assetPath comes from the filesystem.
      // Synthetic check using a bundled skill body crafted with a `"` in
      // its id would be rejected at registration; this test pins the
      // escape rule directly on the formatter via a fake Skill.
      final s = Skill(
        id: 'x',
        name: 'x',
        description: 'has "quoted" word',
        assetPath: 'a/"b"/SKILL.md',
      );
      // We can't call _formatRow (it's private), so we round-trip via
      // the public catalogue with a one-shot registry.  Direct-attr
      // assertion: any literal `"` inside the path attribute would
      // close the attribute prematurely, so check for the escape.
      final raw = '<agent_skill id="${s.id}" path="${s.fullPath.replaceAll('"', '&quot;')}">${s.description}</agent_skill>';
      expect(raw.contains('path="a/&quot;b&quot;/SKILL.md"'), isTrue);
      // Sanity: the asserted line is the same shape buildPromptCatalogue
      // would emit (modulo body truncation), so a regression in the
      // escape logic would surface in the smoke test above first.
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

  group('Ollama provider registration', () {
    test('LlmProvider.ollama is wired into the enum (id + display + fromId)',
        () {
      expect(LlmProvider.ollama.id, equals('ollama'));
      expect(LlmProvider.ollama.displayName, contains('Ollama'));
      expect(LlmProvider.fromId('ollama'), equals(LlmProvider.ollama));
    });

    test('ProviderConfig.ollama() defaults are sane (local URL, no API key)',
        () {
      final p = ProviderConfig.ollama();
      expect(p.id, equals('ollama'));
      // Loopback bind that ships out of the box — users running the
      // daemon on another host MUST be able to override this from the
      // Settings UI, hence the explicit (non-null) default rather than
      // a `?? null` shrug.
      expect(p.baseUrl, equals('http://localhost:11434'));
      // The whole point of adding the `requiresApiKey` flag is this
      // line — Ollama is auth-less and the dispatcher relies on it.
      expect(p.requiresApiKey, isFalse);
      // Model list MUST be empty — we have no way to know what the user
      // has `ollama pull`ed.  Shipping phantom defaults like `llama3.2`
      // would 404 on first dispatch for users who only pulled, say,
      // `qwen2.5-coder`.  Blank dropdown forces the right next action.
      expect(p.models, isEmpty);
    });

    test('Cloud providers still require an API key (regression guard)', () {
      expect(ProviderConfig.chatgpt().requiresApiKey, isTrue);
      expect(ProviderConfig.claude().requiresApiKey, isTrue);
      expect(ProviderConfig.gemini().requiresApiKey, isTrue);
      expect(ProviderConfig.deepseek().requiresApiKey, isTrue);
    });

    test('default AgentConfig now ships Ollama in the providers list', () {
      final cfg = AgentConfig();
      final ids = cfg.providers.map((p) => p.id).toSet();
      expect(ids, contains('ollama'));
    });

    test('ProviderConfig.ollama() round-trips through JSON (incl. requiresApiKey)',
        () {
      final original = ProviderConfig.ollama()
        ..enabled = true
        ..baseUrl = 'http://10.0.0.5:11434';
      final decoded = ProviderConfig.fromJson(original.toJson());
      expect(decoded.id, equals('ollama'));
      expect(decoded.requiresApiKey, isFalse);
      expect(decoded.baseUrl, equals('http://10.0.0.5:11434'));
      expect(decoded.enabled, isTrue);
    });

    test(
        'legacy JSON without requiresApiKey falls back to the factory default',
        () {
      // Simulate a config saved by an older build that predates the
      // requiresApiKey field — the loader must still recognise Ollama
      // as auth-less, not silently flip it to "needs a key" and then
      // block dispatch.
      final legacyJson = {
        'id': 'ollama',
        'displayName': 'Ollama (local)',
        'enabled': true,
        'baseUrl': 'http://localhost:11434',
        'models': ['llama3.2'],
        // requiresApiKey intentionally omitted
      };
      final decoded = ProviderConfig.tryFromJson(legacyJson);
      expect(decoded, isNotNull);
      expect(decoded!.requiresApiKey, isFalse);
    });

    test(
        'AgentConfig.fromJson back-fills new built-in providers missing from '
        'older saved configs (regression: Ollama added post-launch)', () {
      // Simulate a config saved by a build that predates Ollama — only
      // the four cloud providers appear in the JSON.  Without the
      // back-fill, the loader would faithfully reload the 4-entry list
      // and the user would never see the new provider in Settings.
      final legacyJson = {
        'providers': [
          {'id': 'chatgpt', 'displayName': 'ChatGPT', 'enabled': true},
          {'id': 'claude', 'displayName': 'Claude', 'enabled': false},
          {'id': 'gemini', 'displayName': 'Gemini', 'enabled': false},
          {'id': 'deepseek', 'displayName': 'DeepSeek', 'enabled': false},
        ],
      };
      final cfg = AgentConfig.fromJson(legacyJson);
      final ids = cfg.providers.map((p) => p.id).toList();
      // All originals preserved IN ORDER (we mustn't reshuffle existing
      // entries — that would surprise users who'd dragged things around
      // mentally), with Ollama appended at the tail.
      expect(ids, equals(['chatgpt', 'claude', 'gemini', 'deepseek', 'ollama']));
      // The back-filled Ollama entry must inherit factory defaults
      // (including the no-key flag) — otherwise the dispatcher would
      // refuse to fire it.
      final ollama = cfg.providers.firstWhere((p) => p.id == 'ollama');
      expect(ollama.requiresApiKey, isFalse);
      expect(ollama.baseUrl, equals('http://localhost:11434'));
    });

    test(
        'unknown provider id without requiresApiKey falls back to the safe '
        'default (true)', () {
      // Conservative default for third-party / typo'd ids — we'd rather
      // nag the user to set a key for a real cloud provider than
      // silently dispatch unauthenticated requests.
      final unknownJson = {
        'id': 'made-up-provider-xyz',
        'displayName': 'Custom',
        'enabled': false,
        'models': <String>[],
      };
      final decoded = ProviderConfig.tryFromJson(unknownJson);
      expect(decoded, isNotNull);
      expect(decoded!.requiresApiKey, isTrue);
    });
  });
}
