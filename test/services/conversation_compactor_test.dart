import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/conversation_compactor.dart';

void main() {
  test(
    'prompt marks transcript data as untrusted and asks for remaining work',
    () {
      final prompt = ConversationCompactor.buildPrompt(
        existingSummary: 'Changed lib/a.dart.',
        items: const [
          AgentConversationItem.text(role: 'user', content: 'Do work'),
        ],
      );

      expect(prompt, contains('untrusted transcript data'));
      expect(prompt, contains('Remaining work'));
    },
  );

  test(
    'replacement preserves pinned and recent items without splitting tools',
    () {
      final call = AgentToolCall.fromRaw(
        id: 'call_1',
        name: 'bash',
        arguments: const {'command': 'pwd'},
      )!;
      final history = AgentConversationHistory()
        ..add(const {'role': 'user', 'content': 'goal'})
        ..add(AgentConversationItem.assistantToolCalls([call]))
        ..add(
          AgentConversationItem.toolResults(const [
            AgentToolResult(toolCallId: 'call_1', content: '/tmp'),
          ]),
        )
        ..add(const {'role': 'assistant', 'content': 'done'})
        ..add(const {'role': 'user', 'content': 'next'});

      final changed = history.replaceWithSummary(
        summary: 'Ran pwd.',
        pinnedItemCount: 1,
        recentItemCount: 2,
      );

      expect(changed, isTrue);
      expect(history[0].content, 'goal');
      expect(history[1].content, contains('<conversation_summary>'));
      expect(history.any((item) => item.toolCalls.isNotEmpty), isFalse);
      expect(history.any((item) => item.toolResults.isNotEmpty), isFalse);
      expect(history.last.content, 'next');
    },
  );

  test(
    'pinned boundary never splits tool_calls from its tool_results',
    () {
      final call = AgentToolCall.fromRaw(
        id: 'call_1',
        name: 'bash',
        arguments: const {'command': 'pwd'},
      )!;
      // The tool_calls is inside the pinned head, its tool_results is not.
      final history = AgentConversationHistory()
        ..add(const {'role': 'user', 'content': 'goal'})
        ..add(AgentConversationItem.assistantToolCalls([call]))
        ..add(
          AgentConversationItem.toolResults(const [
            AgentToolResult(toolCallId: 'call_1', content: '/tmp'),
          ]),
        )
        ..add(const {'role': 'assistant', 'content': 'done'})
        ..add(const {'role': 'user', 'content': 'next'});

      // pinnedItemCount=2 means [goal, tool_calls] are pinned.
      // Without the fix, tool_results at index 2 would be compacted
      // while tool_calls at index 1 stays pinned — breaking the API protocol.
      final changed = history.replaceWithSummary(
        summary: 'Ran pwd.',
        pinnedItemCount: 2,
        recentItemCount: 2,
      );

      expect(changed, isTrue);
      // After fix: tool_calls must not survive orphaned — either both
      // tool_calls and tool_results survive, or neither does.
      final hasToolCalls = history.any((item) => item.toolCalls.isNotEmpty);
      final hasToolResults = history.any((item) => item.toolResults.isNotEmpty);
      if (hasToolCalls) {
        expect(hasToolResults, isTrue,
            reason: 'tool_calls without tool_results breaks the API');
      }
      if (hasToolResults) {
        expect(hasToolCalls, isTrue,
            reason: 'tool_results without tool_calls is orphaned data');
      }
    },
  );
}
