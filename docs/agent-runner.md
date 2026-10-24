# Agent execution and UI integration

`AgentRunner` owns one user task independently of Flutter widgets. The design
uses the same separation as Pi's [Agent Core](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md)
and [SDK](https://pi.dev/docs/latest/sdk): model/tool execution produces events;
a renderer subscribes to them. SSTerm keeps its own provider adapters, skill
loader, local/SSH execution and approval cards.

## Responsibilities

- `services/agent_runner.dart`: model/tool loop, native batch validation,
  transcript pairing, skill loading, context compaction, stream retry,
  execution budgets, cancellation and pause/resume.
- `services/agent_model.dart`: injectable model transport. `LlmAgentModel`
  adapts the existing LLM client and reuses one HTTP pool for the entire task.
- `services/agent_runner_events.dart`: immutable model snapshots and lifecycle,
  status, skill and tool events.
- `widgets/ai_assistant_panel_loop.dart`: builds task context, subscribes to
  runner events, throttles rendering to frames, saves idle session snapshots
  and drains queued user input.
- `widgets/ai_assistant_panel_execution.dart`: host tool adapter for filesystem,
  MCP and command operations, command approval, output cards and artifacts.
- `widgets/ai_assistant_panel_tooling.dart`: file previews and approval decisions,
  question/command decisions, web search and silent-command assessment.

## Task lifecycle

Construct a runner with a transcript, model transport, tool registry and tool
executor. Subscribe before calling `run()`. A runner accepts exactly one task;
create another runner for the next user message.

A tool executor returns `AgentToolExecution.completed(result)`, `.paused()` or
`.stopped(result)`. A stopped outcome terminates the task without another model
request. Batches contain up to eight calls and execute serially in the exact
order returned by the model, including mixed tool types. The batch cursor and
completed results survive any number of approval pauses. Return an approval or
execution failure through `resume(AgentToolResult(...))` using `pendingTool.id`;
remaining calls execute before another model request or compaction. Reject with
`resume(result, stop: true)` to stop the task and mark remaining calls skipped.
Wrong or repeated resumes are rejected. Every decision answers the original call.
The model, iteration counter and execution budget survive the pause.

All batch arguments must be known before execution. A call that needs an earlier
result belongs in the next model response. `use_skill` must be issued alone so
its instructions can guide the next plan. Batch validation still rejects invalid
arguments, unknown tools, duplicate IDs, truncated calls and more than eight
calls before any side effect starts.

`run()` and `resume()` settle when the runner completes, stops, fails, is
cancelled or pauses. `AgentRunEnded.state` distinguishes these outcomes; a
paused outcome retains its model transport. Subscribers are synchronous and
should only observe events or request cancellation, not throw or mutate the
transcript while execution is running. Model request snapshots are read-only.

`cancel()` invalidates the task synchronously, closes its model transport and
pairs outstanding calls with explicit interruption errors. It preserves results
already produced in a batch. Pending model, compaction, tool, skill and backoff
futures cannot append late results or schedule another turn. Host adapters must
also check cancellation before starting side effects and after awaits before
updating their UI. Cancellation does not undo a side effect already started.
Clearing the chat, switching sessions and disposing the panel also cancel paused
tasks. Queued input remains owned by the UI and runs as a new task.

Skills remain lazy: only enabled skill descriptions are advertised; `use_skill`
returns the body as a native tool result before the next model request. The
summary catalogue budget remains 16K characters. OpenAI-compatible and Anthropic
requests no longer force single-call generation; execution remains serial in the
host. Providers may still choose to return just one call.

## Verification

- `test/services/agent_runner_test.dart`: headless task behavior, skill ordering,
  validation, approval resume, rejection, cancellation, retry and compaction.
- `test/widgets/ai_assistant_panel_stream_follow_test.dart`: real panel wiring,
  approvals, question answers, mixed tools, stale previews and rendering.
- `test/services/llm_service_batch_request_test.dart`: streamed and non-streamed
  OpenAI/Anthropic requests permit multiple calls and preserve their order.
- `test/services/agent_runner_http_test.dart`: actual HTTP transport, a 429 retry
  and ordered mixed tool-result replay. The optional Postman test exercises the same
  runner through the repository's existing Ollama contract simulation.

Run the normal suite with `flutter test --no-pub`. To exercise the existing
Postman simulation, follow `postman/README.md` and run:

```sh
flutter test --no-pub \
  --dart-define=OLLAMA_TEST_BASE_URL=http://127.0.0.1:4962/ollama \
  test/services/agent_runner_http_test.dart \
  test/services/agent_ollama_tools_test.dart
```

These checks establish local orchestration and protocol behavior, not real-model
quality or live SSH/provider availability.
