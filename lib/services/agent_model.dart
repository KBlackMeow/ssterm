import '../models/agent_config.dart';
import 'agent_stream_client_session.dart';
import 'agent_tool_contract.dart';
import 'llm_service.dart';

/// Model transport used by the runner. It has no dependency on a chat widget.
abstract interface class AgentModel {
  Stream<LlmStreamEvent> stream(List<AgentConversationItem> messages);
  Future<String?> summarize(String prompt);
  void reset();
  void close();
}

/// Keeps one HTTP pool across model turns, including approval pauses.
class LlmAgentModel implements AgentModel {
  LlmAgentModel(this.config, {AgentStreamClientSession? session})
    : _session = session ?? AgentStreamClientSession();

  final AgentConfig config;
  final AgentStreamClientSession _session;
  void Function()? _cancel;

  @override
  Stream<LlmStreamEvent> stream(List<AgentConversationItem> messages) async* {
    final request = LlmService.chatStream(
      config: config,
      messages: messages,
      session: _session,
    );
    _cancel = request.cancel;
    try {
      yield* request.stream;
    } finally {
      if (identical(_cancel, request.cancel)) _cancel = null;
    }
  }

  @override
  Future<String?> summarize(String prompt) =>
      LlmService.compactConversation(config: config, prompt: prompt);

  @override
  void reset() => _session.reset();

  @override
  void close() {
    _cancel?.call();
    _cancel = null;
    _session.close(force: true);
  }
}
