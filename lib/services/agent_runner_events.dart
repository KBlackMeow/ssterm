part of 'agent_runner.dart';

/// Immutable snapshots let renderers throttle updates without retaining a
/// mutable stream accumulator or modifying model history.
class AgentModelReply {
  const AgentModelReply({
    this.text = '',
    this.reasoning = '',
    this.thinkingBlocks = const [],
    this.toolCalls = const [],
    this.finishReason,
    this.malformedEventCount = 0,
    this.promptTokenCount,
    this.completionTokenCount,
    this.reasoningTokenCount,
  });

  final String text;
  final String reasoning;
  final List<AgentThinkingBlock> thinkingBlocks;
  final List<AgentToolCall> toolCalls;
  final String? finishReason;
  final int malformedEventCount;
  final int? promptTokenCount;
  final int? completionTokenCount;
  final int? reasoningTokenCount;

  AgentModelReply add(LlmStreamEvent event) => AgentModelReply(
    text: event.kind == 'text' ? text + event.content : text,
    reasoning: event.kind == 'reasoning'
        ? reasoning + event.content
        : reasoning,
    thinkingBlocks: event.thinkingBlock == null
        ? thinkingBlocks
        : List.unmodifiable([...thinkingBlocks, event.thinkingBlock!]),
    toolCalls: event.toolCall == null
        ? toolCalls
        : List.unmodifiable([...toolCalls, event.toolCall!]),
    finishReason: event.finishReason ?? finishReason,
    malformedEventCount: malformedEventCount + event.malformedEventCount,
    promptTokenCount: event.promptTokenCount ?? promptTokenCount,
    completionTokenCount: event.completionTokenCount ?? completionTokenCount,
    reasoningTokenCount: event.reasoningTokenCount ?? reasoningTokenCount,
  );
}

sealed class AgentRunnerEvent {
  const AgentRunnerEvent();
}

final class AgentRunStarted extends AgentRunnerEvent {
  const AgentRunStarted();
}

final class AgentRunEnded extends AgentRunnerEvent {
  const AgentRunEnded(this.state);
  final AgentRunState state;
}

final class AgentResponseStarted extends AgentRunnerEvent {
  const AgentResponseStarted();
}

final class AgentResponseUpdated extends AgentRunnerEvent {
  const AgentResponseUpdated(this.reply);
  final AgentModelReply reply;
}

final class AgentResponseCompleted extends AgentRunnerEvent {
  const AgentResponseCompleted(this.reply, this.displayText);
  final AgentModelReply reply;
  final String displayText;
}

final class AgentResponseDiscarded extends AgentRunnerEvent {
  const AgentResponseDiscarded();
}

final class AgentToolStarted extends AgentRunnerEvent {
  const AgentToolStarted(this.call);
  final AgentToolCall call;
}

final class AgentToolCompleted extends AgentRunnerEvent {
  const AgentToolCompleted(this.result);
  final AgentToolResult result;
}

final class AgentStatusChanged extends AgentRunnerEvent {
  const AgentStatusChanged(this.text);
  final String? text;
}

final class AgentNotice extends AgentRunnerEvent {
  const AgentNotice(this.text);
  final String text;
}

final class AgentRunFailed extends AgentRunnerEvent {
  const AgentRunFailed(this.message);
  final String message;
}

final class AgentSkillLoaded extends AgentRunnerEvent {
  const AgentSkillLoaded(this.id, this.description, this.loaded);
  final String id;
  final String description;
  final bool loaded;
}
