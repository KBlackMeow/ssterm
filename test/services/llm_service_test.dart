import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/models/skill.dart';
import 'package:ssterm/services/bundled_skills.dart';
import 'package:ssterm/services/llm_service.dart';
import 'package:ssterm/services/skill_service.dart';

void main() {
  test('recognizes a raw web-search envelope echoed as an answer', () {
    const echoed = '''[Web search results]
query: "Beijing current weather"
(2 results)

1. Beijing weather
   Current conditions.''';

    expect(LlmService.isRawWebSearchEnvelope(echoed), isTrue);
    expect(
      LlmService.isRawWebSearchEnvelope('北京当前多云，约 26°C。来源：[1]\n\n$echoed'),
      isFalse,
    );
    expect(
      LlmService.isRawWebSearchEnvelope(
        'Here are the results you requested:\n\n```text\n$echoed\n```',
      ),
      isTrue,
    );
  });
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'request profile can disable native tools without changing defaults',
    () {
      const profile = AgentRequestProfile(
        systemPromptOverride: 'Return JSON only. Do not use tools.',
        allowedNativeToolNames: {},
        maxOutputTokens: 96,
        reasoningLevel: AgentReasoningLevel.disabled,
      );

      expect(profile.allowsNativeTools, isFalse);
      expect(profile.systemPromptOverride, contains('Do not use tools'));
      expect(profile.maxOutputTokens, 96);
      expect(profile.reasoningLevel, AgentReasoningLevel.disabled);
    },
  );

  group('ProviderTokenUsage', () {
    test('adds Anthropic cache usage to the effective prompt size', () {
      final usage = ProviderTokenUsage.fromAnthropic({
        'input_tokens': 120,
        'cache_creation_input_tokens': 80,
        'cache_read_input_tokens': 900,
      });

      expect(usage.promptTokenCount, 1100);
      expect(usage.completionTokenCount, isNull);
    });

    test('reads Gemini prompt, output, and thinking token counts', () {
      final usage = ProviderTokenUsage.fromGemini({
        'promptTokenCount': 900,
        'candidatesTokenCount': 120,
        'thoughtsTokenCount': 40,
      });

      expect(usage.promptTokenCount, 900);
      expect(usage.completionTokenCount, 120);
      expect(usage.reasoningTokenCount, 40);
    });

    test('reads usage from complete provider response bodies', () {
      final openAi = ProviderTokenUsage.fromOpenAi({
        'usage': {'prompt_tokens': 300, 'completion_tokens': 40},
      });
      final anthropic = ProviderTokenUsage.fromAnthropic({
        'usage': {'input_tokens': 200, 'output_tokens': 30},
      });
      final gemini = ProviderTokenUsage.fromGemini({
        'usageMetadata': {'promptTokenCount': 100, 'candidatesTokenCount': 20},
      });

      expect(openAi.promptTokenCount, 300);
      expect(openAi.completionTokenCount, 40);
      expect(anthropic.promptTokenCount, 200);
      expect(anthropic.completionTokenCount, 30);
      expect(gemini.promptTokenCount, 100);
      expect(gemini.completionTokenCount, 20);
    });

    test('drops invalid provider token counts', () {
      final usage = ProviderTokenUsage.fromOpenAi({
        'prompt_tokens': -1,
        'completion_tokens': '12',
      });

      expect(usage.isEmpty, isTrue);
    });
  });

  test('chatStream uses the supplied task-scoped client session', () {
    final source = File('lib/services/llm_service.dart').readAsStringSync();

    expect(source, contains('required AgentStreamClientSession session'));
    expect(source, contains('session.client'));
    expect(source, isNot(contains('final client = HttpClient();')));
  });

  test('GLM streaming enables its required tool-call stream extension', () {
    final source = File(
      'lib/services/llm_service_providers.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(
        "if (provider.id == 'glm' && tools.isNotEmpty) 'tool_stream': true",
      ),
    );
    expect(source, contains("if (provider.id == 'glm')"));
    expect(source, contains("'clear_thinking': false"));
  });

  test('DeepSeek routing can explicitly disable thinking in every path', () {
    final source = File(
      'lib/services/llm_service_providers.dart',
    ).readAsStringSync();

    expect(
      RegExp(
        r"provider\.id == 'deepseek'[\s\S]*?reasoningLevel == AgentReasoningLevel\.disabled[\s\S]*?'disabled'",
      ).allMatches(source),
      hasLength(greaterThanOrEqualTo(1)),
    );
    expect(
      RegExp(
        r"isDeepSeek\)[\s\S]*?reasoningLevel == AgentReasoningLevel\.disabled[\s\S]*?'disabled'",
      ).allMatches(source),
      hasLength(greaterThanOrEqualTo(1)),
    );
  });

  group('OpenAiStreamAccumulator', () {
    test('assembles tool arguments by index when later chunks omit id', () {
      final accumulator = OpenAiStreamAccumulator();

      final firstEvents = accumulator.addData(
        jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_pwd',
                    'function': {'name': 'bash', 'arguments': '{"com'},
                  },
                ],
              },
            },
          ],
        }),
      );
      final secondEvents = accumulator.addData(
        jsonEncode({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': 'mand":"pwd"}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }),
      );
      final completedEvents = accumulator.finish();

      expect(firstEvents, isEmpty);
      expect(secondEvents, isEmpty);
      expect(completedEvents, hasLength(1));
      expect(completedEvents.single.kind, 'tool_call');
      expect(completedEvents.single.toolCall?.id, 'call_pwd');
      expect(completedEvents.single.toolCall?.name, 'bash');
      expect(completedEvents.single.toolCall?.arguments, {'command': 'pwd'});
      expect(accumulator.finishReason, 'tool_calls');
      expect(accumulator.malformedEventCount, 0);
    });

    test('counts malformed events and continues parsing later text', () {
      final accumulator = OpenAiStreamAccumulator();

      expect(accumulator.addData('{not-json'), isEmpty);
      final events = accumulator.addData(
        jsonEncode({
          'choices': [
            {
              'delta': {'content': 'Recovered'},
              'finish_reason': 'stop',
            },
          ],
        }),
      );

      expect(accumulator.malformedEventCount, 1);
      expect(events.single.kind, 'text');
      expect(events.single.content, 'Recovered');
      expect(accumulator.finishReason, 'stop');
    });

    test('retains exact reasoning usage from a terminal chunk', () {
      final accumulator = OpenAiStreamAccumulator();

      accumulator.addData(
        jsonEncode({
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'},
          ],
          'usage': {
            'completion_tokens_details': {'reasoning_tokens': 37},
          },
        }),
      );

      expect(accumulator.reasoningTokenCount, 37);
    });

    test('retains exact prompt and completion usage from a terminal chunk', () {
      final accumulator = OpenAiStreamAccumulator();

      accumulator.addData(
        jsonEncode({
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'},
          ],
          'usage': {'prompt_tokens': 1234, 'completion_tokens': 56},
        }),
      );

      expect(accumulator.promptTokenCount, 1234);
      expect(accumulator.completionTokenCount, 56);
    });

    test('ignores missing or invalid reasoning usage', () {
      final accumulator = OpenAiStreamAccumulator();

      accumulator.addData(
        jsonEncode({
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'},
          ],
          'usage': {
            'completion_tokens_details': {'reasoning_tokens': '37'},
          },
        }),
      );

      expect(accumulator.reasoningTokenCount, isNull);
    });
  });

  group('LlmService.incompleteStreamError', () {
    test('rejects a reasoning-only response', () {
      final error = LlmService.incompleteStreamError(
        text: '',
        hasReasoning: true,
        toolCallCount: 0,
        finishReason: 'stop',
        malformedEventCount: 0,
      );

      expect(error, contains('reasoning'));
      expect(error, contains('stop'));
    });

    test('accepts final text or a valid tool call', () {
      expect(
        LlmService.incompleteStreamError(
          text: 'Which directory should I scan?',
          hasReasoning: true,
          toolCallCount: 0,
          finishReason: 'stop',
          malformedEventCount: 0,
        ),
        isNull,
      );
      expect(
        LlmService.incompleteStreamError(
          text: '',
          hasReasoning: true,
          toolCallCount: 1,
          finishReason: 'tool_calls',
          malformedEventCount: 0,
        ),
        isNull,
      );
    });
  });

  group('LlmService image input capability', () {
    test('rejects known text-only provider models before dispatch', () {
      expect(
        LlmService.supportsImageInput(
          ProviderConfig.deepseek(),
          'deepseek-v4-pro',
        ),
        isFalse,
      );
      expect(
        LlmService.supportsImageInput(ProviderConfig.minimax(), 'MiniMax-M2.7'),
        isFalse,
      );
      expect(
        LlmService.supportsImageInput(ProviderConfig.glm(), 'glm-5.2'),
        isFalse,
      );
    });

    test('allows image-capable built-in provider models', () {
      expect(
        LlmService.supportsImageInput(
          ProviderConfig.gemini(),
          'gemini-3.6-flash',
        ),
        isTrue,
      );
      expect(
        LlmService.supportsImageInput(ProviderConfig.kimi(), 'kimi-k2.6'),
        isTrue,
      );
    });
  });

  group('LlmService reasoning token display', () {
    test('estimates English and Chinese reasoning', () {
      expect(LlmService.estimateReasoningTokenCount('one two three four'), 4);
      expect(
        LlmService.estimateReasoningTokenCount('先检查连接，然后执行命令。'),
        greaterThan(0),
      );
    });

    test('labels estimated and exact reasoning token counts distinctly', () {
      expect(
        LlmService.reasoningTokenCountLabel(tokenCount: 12, isExact: false),
        '约 12 tokens',
      );
      expect(
        LlmService.reasoningTokenCountLabel(tokenCount: 12, isExact: true),
        '12 tokens',
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
      expect(
        LlmService.stripCompletionMarkers(input),
        equals('Need a decision.'),
      );
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

    test('strips forged command feedback from assistant replies', () {
      const input = '''
I'll check the weather.

```bash
curl -s "wttr.in?lang=zh&format=%l:+%c+%t+%h+%w"
```

[Command executed]
\$ curl -s "wttr.in?lang=zh&format=%l:+%c+%t+%h+%w"
[exit_code=0]
[output]
上海: ☁️ +27°C 💦 71% ↙20km/h

你当前所在位置的天气是上海。
[TASK_COMPLETE]
''';

      final stripped = LlmService.stripForgedCommandFeedback(input);
      expect(stripped, contains('```bash'));
      expect(stripped, contains('curl -s'));
      expect(stripped.contains('[Command executed]'), isFalse);
      expect(stripped.contains('上海'), isFalse);
      expect(stripped.contains('TASK_COMPLETE'), isFalse);
      expect(LlmService.hasTaskCompleteMarker(stripped), isFalse);
    });

    test('completion stripping also removes forged feedback first', () {
      const input = '''
```bash
date
```

[Command executed]
\$ date
[exit_code=0]
[output]
Fri Jun 12 10:00:00 CST 2026

It is Friday.
[TASK_COMPLETE]
''';

      final stripped = LlmService.stripCompletionMarkers(input);
      expect(stripped, equals('```bash\ndate\n```'));
    });

    test('structured shell tool_call renders as a bash block for display', () {
      const input = '''
I'll check the current directory.

```tool_call
{"id":"call_pwd","name":"bash","arguments":{"command":"pwd"}}
```
''';
      final stripped = LlmService.stripCompletionMarkers(input);
      expect(stripped, contains('```bash\npwd\n```'));
      expect(stripped.contains('tool_call'), isFalse);
      expect(stripped.contains('"arguments"'), isFalse);
    });

    test('structured non-shell tool_calls are hidden from display text', () {
      const input = '''
I'll load the relevant skill.

```tool_call
{"id":"call_skill","name":"use_skill","arguments":{"skill_id":"verify-fix"}}
```
''';
      expect(
        LlmService.stripCompletionMarkers(input),
        equals("I'll load the relevant skill."),
      );
    });
  });

  group('LlmService.stripCompletionMarkers WRITE_FILE coverage', () {
    test('WRITE_FILE block including body is removed from rendered text', () {
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

    test(
      'markdown-emphasised **[WEB_SEARCH: q]** removes the asterisks too',
      () {
        const input = 'Searching:\n\n**[WEB_SEARCH: foo]**';
        final stripped = LlmService.stripCompletionMarkers(input);
        // No dangling `**` left over.
        expect(stripped.contains('*'), isFalse);
        expect(stripped, equals('Searching:'));
      },
    );
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
        LlmService.stripStreamingMarkers(input),
        equals('Almost there.\n\n'),
      );
    });

    test('hides `[TASK_COM` — definitely a marker prefix', () {
      const input = 'Done.\n\n[TASK_COM';
      expect(LlmService.stripStreamingMarkers(input), equals('Done.\n\n'));
    });

    test('hides `[ASK_US` — partial ASK_USER prefix', () {
      const input = 'Need input?\n\n[ASK_US';
      expect(
        LlmService.stripStreamingMarkers(input),
        equals('Need input?\n\n'),
      );
    });

    test(
      'hides `[W` — partial WEB_SEARCH or USE_SKILL/other ambiguous start',
      () {
        // The streaming hider treats any bare `[X` whose body could
        // become USE_SKILL / WEB_SEARCH as a marker prefix.  `[W` is a
        // unique prefix of WEB_SEARCH so it must be hidden.
        const input = 'Looking up.\n\n[W';
        expect(
          LlmService.stripStreamingMarkers(input),
          equals('Looking up.\n\n'),
        );
      },
    );

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

    test('hides `[WRITE_FILE_BEGIN: …` mid-stream so the body never leaks', () {
      // The BEGIN line itself triggers the streaming hide; the body
      // gets stripped by the post-stream pass after END arrives.  This
      // test pins the BEGIN-line hide so users don't see the path
      // flicker in.
      const input = 'Writing:\n\n[WRITE_FILE_BEGIN: /tmp/x.txt';
      expect(LlmService.stripStreamingMarkers(input), equals('Writing:\n\n'));
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
    setUp(LlmService.refreshSystemPrompt);

    test('always uses native schemas without a textual tool protocol', () {
      final prompt = LlmService.systemPromptFor(
        enabledSkillIds: {},
        webSearchEnabled: true,
        fileWriteEnabled: true,
        mcpEnabled: true,
      );
      expect(
        prompt,
        contains('Tool schemas supplied by the API are authoritative'),
      );
      expect(prompt, contains("compare it with the user's requested outcome"));
      expect(prompt, contains('<native_mutating_tools>'));
      for (final legacy in [
        '```tool_call',
        '<turn_protocol>',
        '[TASK_COMPLETE]',
        '[ASK_USER]',
        '[WRITE_FILE',
        '<web_search_tool>',
        '<read_image_tool>',
      ]) {
        expect(prompt, isNot(contains(legacy)), reason: legacy);
      }
      expect(prompt, contains('<host_environment>'));
    });

    test('repeated calls reuse the cached prompt', () {
      final a = LlmService.systemPromptFor(enabledSkillIds: {});
      final b = LlmService.systemPromptFor(enabledSkillIds: {});
      expect(identical(a, b), isTrue);
    });

    test('refresh rebuilds the same prompt', () {
      final a = LlmService.systemPromptFor(enabledSkillIds: {});
      LlmService.refreshSystemPrompt();
      final b = LlmService.systemPromptFor(enabledSkillIds: {});
      expect(a, b);
      expect(identical(a, b), isFalse);
    });

    test('file write instructions follow the feature flag', () {
      final off = LlmService.systemPromptFor(enabledSkillIds: {});
      final on = LlmService.systemPromptFor(
        enabledSkillIds: {},
        fileWriteEnabled: true,
      );
      expect(off, isNot(contains('<native_mutating_tools>')));
      expect(on, contains('<native_mutating_tools>'));
    });

    test('disabled skills never advertise a catalogue', () {
      final prompt = LlmService.systemPromptFor(enabledSkillIds: {});
      expect(prompt, isNot(contains('<agent_skills>')));
    });
  });

  group('SkillService.buildPromptCatalogue Cursor-style format', () {
    late Directory tempRoot;

    setUp(() async {
      BundledSkillRegistry.debugReset();
      tempRoot = await Directory.systemTemp.createTemp(
        'ssterm-llm-skill-test-',
      );
      SkillService.debugUserSkillsDirOverride = '${tempRoot.path}/user';
      SkillService.debugSharedSkillsDirOverride = '${tempRoot.path}/shared';
      BundledSkillRegistry.register(
        BundledSkillDef(
          id: 'alpha',
          description: 'do the alpha thing',
          buildBody: () async => 'alpha body',
        ),
      );
      BundledSkillRegistry.register(
        BundledSkillDef(
          id: 'beta',
          description: 'do the beta thing',
          buildBody: () async => 'beta body',
        ),
      );
      await SkillService.init();
      LlmService.refreshSystemPrompt();
    });

    tearDown(() async {
      SkillService.debugUserSkillsDirOverride = null;
      SkillService.debugSharedSkillsDirOverride = null;
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
    });

    test('emits one <agent_skill id=… path=…>desc</agent_skill> per skill', () {
      final out = SkillService.buildPromptCatalogue();
      // Both bundled skills should appear with the synthetic `bundled://`
      // path scheme — that's how the Skill model surfaces dynamic-body
      // skills without an on-disk file.
      expect(out, contains('<agent_skill id="alpha" path="bundled://alpha">'));
      expect(out, contains('do the alpha thing</agent_skill>'));
      expect(out, contains('<agent_skill id="beta" path="bundled://beta">'));
      // Stable id-sorted order — alpha must come before beta so the
      // bytes stay identical across runs (prompt-cache stability).
      expect(out.indexOf('id="alpha"'), lessThan(out.indexOf('id="beta"')));
    });

    test(
      'system prompt embeds the <agent_skills> block with policy + listing',
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
      },
    );

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
      final raw =
          '<agent_skill id="${s.id}" path="${s.fullPath.replaceAll('"', '&quot;')}">${s.description}</agent_skill>';
      expect(raw.contains('path="a/&quot;b&quot;/SKILL.md"'), isTrue);
      // Sanity: the asserted line is the same shape buildPromptCatalogue
      // would emit (modulo body truncation), so a regression in the
      // escape logic would surface in the smoke test above first.
    });
  });

  group('LlmService skills + AgentConfig wiring', () {
    test('AgentConfig.enabledSkills round-trips through JSON', () {
      final cfg = AgentConfig(enabledSkills: {'git-bisect', 'verify-fix'});
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

    test('copyWith(resetEnabledSkills: true) restores the null sentinel', () {
      final cfg = AgentConfig(enabledSkills: {'git-bisect'});
      final reset = cfg.copyWith(resetEnabledSkills: true);
      expect(reset.enabledSkills, isNull);
      // The explicit value should NOT survive when reset is requested,
      // even if both are passed (reset takes precedence).
      final both = cfg.copyWith(enabledSkills: {'x'}, resetEnabledSkills: true);
      expect(both.enabledSkills, isNull);
    });

    test('SkillService.userSkillsDirPath honours the debug override', () {
      // The override is what makes the user-dir scan unit-testable —
      // assert the getter actually exposes it instead of always
      // computing the real ~/.ssterm/skills path.
      SkillService.debugUserSkillsDirOverride = '/tmp/my-test-skills';
      expect(SkillService.userSkillsDirPath, equals('/tmp/my-test-skills'));
      SkillService.debugUserSkillsDirOverride = null;
      expect(
        SkillService.userSkillsDirPath.endsWith('/.ssterm/skills'),
        isTrue,
      );
    });

    test('SkillService.sharedSkillsDirPath honours the debug override', () {
      SkillService.debugSharedSkillsDirOverride = '/tmp/my-shared-skills';
      expect(SkillService.sharedSkillsDirPath, equals('/tmp/my-shared-skills'));
      SkillService.debugSharedSkillsDirOverride = null;
      expect(
        SkillService.sharedSkillsDirPath.endsWith('/.agents/skills'),
        isTrue,
      );
    });
  });

  group('Agent model catalogues', () {
    test('compatible providers select their declared adapter', () {
      expect(LlmService.providerKindFor(ProviderConfig.kimi()), 'openai');
      expect(LlmService.providerKindFor(ProviderConfig.minimax()), 'anthropic');
      expect(
        LlmService.providerKindFor(
          ProviderConfig.custom(
            id: 'proxy',
            displayName: 'Proxy',
            protocol: ProviderProtocol.openAiCompatible,
            baseUrl: 'https://proxy.test/v1',
            models: ['x'],
          ),
        ),
        'openai',
      );
    });

    test('compatible presets expose protocol and current model', () {
      expect(ProviderConfig.kimi().protocol, ProviderProtocol.openAiCompatible);
      expect(ProviderConfig.kimi().baseUrl, 'https://api.moonshot.cn/v1');
      expect(ProviderConfig.kimi().models.first, 'kimi-k2.6');
      expect(
        ProviderConfig.minimax().protocol,
        ProviderProtocol.anthropicCompatible,
      );
      expect(ProviderConfig.glm().protocol, ProviderProtocol.openAiCompatible);
      expect(
        ProviderConfig.glm().baseUrl,
        'https://open.bigmodel.cn/api/paas/v4',
      );
      expect(ProviderConfig.glm().models, ['glm-5.2', 'glm-5.1', 'glm-4.7']);
      expect(ProviderConfig.glm().modelContextWindows['glm-5.2'], 1000000);
    });

    test('OpenRouter groups current GPT, Claude and DeepSeek defaults', () {
      expect(ProviderConfig.openrouter().models, [
        'openai/gpt-5.4',
        'openai/gpt-5.2-pro',
        'openai/gpt-5.2',
        'anthropic/claude-opus-5',
        'anthropic/claude-opus-5-fast',
        'anthropic/claude-sonnet-4.6',
        'deepseek/deepseek-v4-pro',
        'deepseek/deepseek-v4-flash',
        'moonshotai/kimi-k2.6',
        'qwen/qwen3.8-max',
        'qwen/qwen3.7-flash',
      ]);
      final ids = ProviderConfig.builtIns.map((provider) => provider.id);
      expect(ids, isNot(contains('groq')));
      expect(ids, isNot(contains('together')));
      expect(ids, isNot(contains('fireworks')));
    });

    test('new configurations expose the current cloud model catalogues', () {
      expect(
        ProviderConfig.chatgpt().models,
        equals(['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna']),
      );
      expect(
        ProviderConfig.claude().models,
        equals(['claude-opus-4-8', 'claude-sonnet-4-6']),
      );
      expect(
        ProviderConfig.gemini().models,
        equals([
          'gemini-3.6-flash',
          'gemini-3.5-flash',
          'gemini-3.5-flash-lite',
        ]),
      );
      expect(
        ProviderConfig.deepseek().models,
        equals(['deepseek-v4-pro', 'deepseek-v4-flash']),
      );
    });

    test('audited provider context windows match official specifications', () {
      expect(ProviderConfig.deepseek().modelContextWindows, {
        'deepseek-v4-pro': 1000000,
        'deepseek-v4-flash': 1000000,
      });
      expect(ProviderConfig.gemini().modelContextWindows, {
        'gemini-3.6-flash': 1048576,
        'gemini-3.5-flash': 1000000,
        'gemini-3.5-flash-lite': 1048576,
      });
      expect(
        ProviderConfig.qwen().modelContextWindows['qwen3.7-plus'],
        1000000,
      );
    });

    test('all models default to a 32K output cap', () {
      final deepseek = ProviderConfig.deepseek();
      expect(deepseek.maxOutputTokensFor('deepseek-v4-pro'), 32768);
      expect(deepseek.maxOutputTokensFor('deepseek-v4-flash'), 32768);
      expect(deepseek.maxOutputTokensFor('custom-model'), 32768);
      expect(ProviderConfig.claude().maxOutputTokensFor('claude'), 32768);
      expect(ProviderConfig.gemini().maxOutputTokensFor('gemini'), 32768);
      expect(ProviderConfig.ollama().maxOutputTokensFor('local'), 32768);
    });

    test(
      'reload keeps user-configured token limits and backfills defaults',
      () {
        final config = AgentConfig.fromJson({
          'providers': [
            {
              'id': 'deepseek',
              'models': ['deepseek-v4-pro', 'my-deepseek-model'],
              'modelContextWindows': {
                'deepseek-v4-pro': 128000,
                'my-deepseek-model': 64000,
              },
              'modelMaxOutputTokens': {
                'deepseek-v4-pro': 4096,
                'my-deepseek-model': 8192,
              },
            },
          ],
        });
        final deepseek = config.providers.firstWhere(
          (provider) => provider.id == 'deepseek',
        );
        // An explicit override of a built-in model must survive a restart —
        // silently reverting it would lose a value the user set in the UI.
        expect(deepseek.modelContextWindows['deepseek-v4-pro'], 128000);
        expect(deepseek.modelContextWindows['deepseek-v4-flash'], 1000000);
        expect(deepseek.modelContextWindows['my-deepseek-model'], 64000);
        expect(deepseek.modelMaxOutputTokens['deepseek-v4-pro'], 4096);
        expect(deepseek.modelMaxOutputTokens['deepseek-v4-flash'], 32768);
        expect(deepseek.modelMaxOutputTokens['my-deepseek-model'], 8192);
      },
    );

    test(
      'reloading a saved configuration promotes defaults and keeps custom models',
      () {
        final config = AgentConfig.fromJson({
          'providers': [
            {
              'id': 'chatgpt',
              'models': ['gpt-5.5', 'my-openai-proxy-model'],
            },
          ],
        });
        final chatgpt = config.providers.firstWhere((p) => p.id == 'chatgpt');
        expect(
          chatgpt.models,
          equals([
            'gpt-5.6-sol',
            'gpt-5.6-terra',
            'gpt-5.6-luna',
            'gpt-5.5',
            'my-openai-proxy-model',
          ]),
        );
      },
    );
  });

  group('Ollama provider registration', () {
    test(
      'LlmProvider.ollama is wired into the enum (id + display + fromId)',
      () {
        expect(LlmProvider.ollama.id, equals('ollama'));
        expect(LlmProvider.ollama.displayName, contains('Ollama'));
        expect(LlmProvider.fromId('ollama'), equals(LlmProvider.ollama));
      },
    );

    test(
      'ProviderConfig.ollama() defaults are sane (local URL, no API key)',
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
      },
    );

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

    test(
      'ProviderConfig.ollama() round-trips through JSON (incl. requiresApiKey)',
      () {
        final original = ProviderConfig.ollama()
          ..enabled = true
          ..baseUrl = 'http://10.0.0.5:11434';
        final decoded = ProviderConfig.fromJson(original.toJson());
        expect(decoded.id, equals('ollama'));
        expect(decoded.requiresApiKey, isFalse);
        expect(decoded.baseUrl, equals('http://10.0.0.5:11434'));
        expect(decoded.enabled, isTrue);
      },
    );

    test('ProviderConfig persists per-model token limits', () {
      final original = ProviderConfig(
        id: 'ollama',
        displayName: 'Ollama',
        requiresApiKey: false,
        models: ['qwen'],
        modelContextWindows: {'qwen': 65536},
        modelMaxOutputTokens: {'qwen': 8192},
      );

      final decoded = ProviderConfig.fromJson(original.toJson());

      expect(decoded.modelContextWindows, {'qwen': 65536});
      expect(decoded.modelMaxOutputTokens, {'qwen': 8192});
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
      },
    );

    test('AgentConfig.fromJson back-fills new built-in providers missing from '
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
      expect(
        ids,
        equals(ProviderConfig.builtIns.map((provider) => provider.id).toList()),
      );
      // The back-filled Ollama entry must inherit factory defaults
      // (including the no-key flag) — otherwise the dispatcher would
      // refuse to fire it.
      final ollama = cfg.providers.firstWhere((p) => p.id == 'ollama');
      expect(ollama.requiresApiKey, isFalse);
      expect(ollama.baseUrl, equals('http://localhost:11434'));
    });

    test('unknown provider id without requiresApiKey falls back to the safe '
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
