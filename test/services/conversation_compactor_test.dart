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
}
