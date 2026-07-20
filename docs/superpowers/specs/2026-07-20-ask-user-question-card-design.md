# AI Agent 问题选择框（ask_user_question 工具）— 设计文档

日期：2026-07-20

## 背景

ssterm 的 AI Agent 面板（[lib/widgets/ai_assistant_panel.dart](../../../lib/widgets/ai_assistant_panel.dart) 及其 `part` 文件）已经有一套成熟的"结构化工具调用"协议：

- 协议层：[lib/services/llm_service.dart](../../../lib/services/llm_service.dart) 的 `ToolCall` 类（第 38-93 行）+ `extractToolCalls`/`_isSupportedToolCall`（第 640-669 行），解析模型输出的 fenced ` ```tool_call ` JSON 块。已支持 `bash`/`use_skill`/`web_search`/`write_file` 四种工具，每种都有 `isXxx` getter + 专属参数 getter。
- 系统提示词：[lib/services/llm_service_prompts.dart](../../../lib/services/llm_service_prompts.dart) 里 `_buildWebSearchBlock`/`_buildFileWriteBlock`/`_buildSkillsBlock` 三个 builder，以及描述"每轮只能是 INVESTIGATE/ANSWER/ASK 三选一"的 `<turn_protocol>`（第 343-419 行）。
- 循环层：[lib/widgets/ai_assistant_panel_loop.dart](../../../lib/widgets/ai_assistant_panel_loop.dart) 的 `_continueAgentLoopBody`，在每轮 LLM 回复后按优先级拦截 `use_skill` → `web_search` → `write_file` → shell 命令。
- 卡片 UI + 状态机模式：[lib/widgets/ai_assistant_panel_models.dart](../../../lib/widgets/ai_assistant_panel_models.dart) 的 `_WriteProposal`/`_DangerProposal`（`pending → 终态` 的 mutable 状态机，配 `Completer` 或"卡片显示→用户点击→resume loop"两种恢复方式），配套 UI 见 [ai_assistant_panel_danger_card.dart](../../../lib/widgets/ai_assistant_panel_danger_card.dart)。

**现状问题**：模型想向用户提问时只有裸 `[ASK_USER]` 标记（`_askUserRe`，llm_service.dart 第 114-117 行）——纯自由文本，循环里直接 `break`（ai_assistant_panel_loop.dart 第 464 行），用户必须手动打字回复，没有"点选项按钮"的路径。本设计参考 Claude 自身的 `AskUserQuestion` 工具，新增一个可以带选项的结构化提问工具，供模型在"有具体候选答案"时使用；开放式问题继续用旧的 `[ASK_USER]`，两者并存。

## 设计

### 1. 协议：新增 `ask_user_question` 工具调用

与 `web_search`/`write_file` 同款 JSON `tool_call` 信封，不扩展 bracket marker：

```tool_call
{"id":"call_x","name":"ask_user_question","arguments":{
  "question":"<一句具体问题>",
  "header":"<≤12字短标签，如\"认证方式\">",
  "options":[
    {"label":"<短标题>","description":"<一句解释>"},
    {"label":"<短标题>","description":"<一句解释>"}
  ]
}}
```

- `options` 长度必须在 2–6 之间（含），每项必须同时有非空 `label` 和 `description`。
- UI 侧自动在选项列表末尾追加一个"其他"行（不由模型生成，见第 3 节）。
- 无 Settings 开关——提问没有副作用，和 `[ASK_USER]`/`[TASK_COMPLETE]` 同属"始终可用"的类别，不像 `web_search`/`write_file` 需要 `config.xxxEnabled` 门控。
- `<turn_protocol>` 的"三选一"改为在 ASK 分支下分裂出两种子形态：
  - 3a. 开放式问题 → 仍然是纯 prose + `[ASK_USER]`。
  - 3b. 有具体候选项 → 一句引导语 + `ask_user_question` 的 `tool_call`，STOP。
  - "MUST NOT combine" 的黑名单（各 `_buildXxxBlock` 里重复出现的那句话，如 prompts.dart 第 71/134/207 行）加入 `ask_user_question`。

**`llm_service.dart` 改动**：
- `ToolCall` 新增 `isAskUserQuestion` getter（匹配 `name == 'ask_user_question'`）。
- 新增 `question`/`header` 字符串 getter（同 `query`/`path` 的写法：非空字符串校验 + trim）。
- 新增 `options` getter：解析 `arguments['options']`（`List`），每项转成 `({String label, String description})` record，过滤掉 label 或 description 为空的项。
- `_isSupportedToolCall`（第 663 行）新增分支：`if (call.isAskUserQuestion) return call.question != null && call.header != null && call.options.length >= 2 && call.options.length <= 6;`

**`llm_service_prompts.dart` 改动**：新增 `_buildAskUserQuestionBlock()`，写法仿照 `_buildWebSearchBlock`（结构说明 + 何时用/何时不用 + turn-shape 规则 + 一个 worked example），在 `_buildSystemPrompt`（第 13-25 行）里无条件 `parts.add(...)`（不受任何 `enabled` 布尔控制）。

### 2. 数据模型（`ai_assistant_panel_models.dart`）

新增，写法与 `_WriteProposal`/`_DangerProposal` 一致：

```dart
class _QuestionOption {
  final String label;
  final String description;
}

enum _QuestionProposalState { pending, answered }

class _QuestionProposal {
  final String question;
  final String header;
  final List<_QuestionOption> options;   // 不含"其他"，那是 UI 追加的
  final int agentGeneration;
  _QuestionProposalState state = _QuestionProposalState.pending;
  String? answerText;                    // 定案后：选中的 label，或用户在"其他"里打的字
  final Completer<String?> decision = Completer<String?>();  // null = 被取消/过期
}
```

`_ChatMessage` 新增 `questionProposal` 字段 + `_ChatMessage.questionProposal(proposal)` 工厂，规则同 `writeProposal`/`dangerProposal`（nullable，兼容热重载）。

### 3. 循环集成（`ai_assistant_panel_loop.dart`）—— 原地暂停，不是新起一轮

和真实 Claude 的 `AskUserQuestion` 行为对齐：工具调用**暂停在当前 turn 内**，不结束整个循环。具体做法仿照 `_DangerProposal` 已经在用的"`await` 一个 `Completer`，暂停在同一次 `while` 循环迭代里"模式（loop.dart 第 546 行 `approved = await proposal.decision.future;`），而不是像裸 `[ASK_USER]` 那样 `break` 退出。

在 `_continueAgentLoopBody` 里，与 `useSkillTool`/`webSearchTool`/`writeFileTool` 并列提取 `askUserQuestionTool`，拦截位置紧跟在 `writeFile` 拦截块之后、`taskComplete`/裸 `askUser` 的 `break` 判断之前（`<turn_protocol>` 已保证模型不会在同一轮里混用两种 ASK 形态，所以这里的先后顺序不影响正确性，只是代码组织上延续"结构化工具都排在裸标记判断前面"的既有顺序）：

1. 构造 `_QuestionProposal`，`setState` 把它作为新的 `_ChatMessage` 追加到 `_messages`（AI 的引导语文本仍走原来的 `aiMsg` 气泡，问题卡片是紧随其后的独立消息，和 write/danger 卡片的追加方式一致）。
2. `_pendingQuestionProposal = proposal;` 记录到 state 字段（供 `_send()`/`_cancelAgent()` 的"其他"钩子使用，见第 4 节）。
3. `final answer = await proposal.decision.future;`——`_agentBusy` 全程保持 `true`，终端保持锁定，不经过 `_continueAgentLoop` 的 `finally`。
4. 若 `gen != _generation`（等待期间用户开了新对话）：`return`，与 write/danger 卡片的过期检查一致。
5. 若 `answer == null`（被取消，见第 4 节）：`return`。
6. 否则：`setState` 把 `_ChatMessage.user(answer)` 追加到 `_messages`（视觉上就像用户亲口打字回复一样），`_conversationHistory.add({'role': 'user', 'content': answer})`（不加信封前后缀——这是一句正常的用户话，不是"成功/失败"结果上报），`_pendingQuestionProposal = null;`，`continue;` 回到 `while` 顶部——同一个 `turnId` 内让循环立刻发起下一次 LLM 调用，不需要用户再按一次 Send。

### 4. UI 卡片 + "其他"选项的发送钩子

**卡片**（新文件 `ai_assistant_panel_question_card.dart`，`_QuestionProposalCard`，视觉上参照 `_DangerProposalCard` 的容器/配色/状态徽标写法）：
- 顶部一个小 chip 显示 `header`。
- `question` 文本。
- `options` 渲染成竖排整行可点击列表（不用 `ChoiceChip`——label+description 两行信息横向 chip 装不下），每行粗体 label + 灰色小字 description。
- 列表最后固定追加一行"其他"（UI 生成，不来自模型），description 留空或写"手动输入"。
- 点击普通选项：卡片状态切到 `answered`，高亮选中行，调用共享的 `_decideQuestionProposal(proposal, answer: option.label)`。
- 点击"其他"：卡片进入"等待下方输入"提示态（不锁定到 `answered`，仅禁用其余按钮避免重复点击），把焦点交给主聊天输入框，**不**立即 complete Completer。

**`_decideQuestionProposal` helper**（loop.dart 或 tooling.dart，仿照 `_decideDangerProposal`）：
- 若 `proposal.agentGeneration != _generation`（过期）：直接把卡片标成 answered/灰态，`decision.complete(null)`，不触碰当前新对话。
- 否则：`setState` 记录 `answerText`、切状态、清空 `_pendingQuestionProposal`，`decision.complete(answer)`。

**主聊天 Send 钩子**（`ai_assistant_panel.dart` 的 `_send()`，第 276-303 行）：在最顶部加一段——若 `_pendingQuestionProposal != null && _pendingQuestionProposal!.state == pending`，说明用户是在回答"其他"，调用 `_decideQuestionProposal(_pendingQuestionProposal!, answer: text)` 并 `return`，**跳过**现有的 `if (_agentBusy) _cancelAgent();` 分支（否则会把自己正在等待的循环打断）和 `_agentRespond(text)` 调用。

**输入框可用性**：当前 `_agentBusy == true` 时主输入框预期是禁用的（与 danger/write 卡片仅靠自己的按钮交互一致）。需要新增一个"存在待回答的问题卡片时，输入框特例保持可用"的条件，与 danger/write 卡片"忙碌时仍可点自己的 Approve/Reject 按钮"是同一类特例，只是这次特例对象是主输入框而不是卡片按钮。

**取消处理**（`_cancelAgent()`，第 265-274 行）：若 `_pendingQuestionProposal` 非空且仍是 `pending`，在其递增 `_generation` 之后，顺带把该 proposal 标记为过期（沿用第 3 步"过期"视觉状态）并 `decision.complete(null)`，避免循环里的 `await` 变成永久挂起的孤儿 Future。

## 不在本次范围内

- 不支持一次多个问题（不做 `List<question>`）、不支持每题多选（`multiSelect`）——按用户确认，保持"一次一问、单选"的最小范围。
- 不改变裸 `[ASK_USER]` 的现有行为（继续 `break` 退出循环，继续用于开放式问题）。
- 不新增 Settings 开关。
- 不新增 loop/widget 级别的自动化测试基础设施（本项目目前没有 `ai_assistant_panel_loop.dart` 的测试文件，本次也不补）。

## 影响文件

- `lib/services/llm_service.dart`：`ToolCall` 新增 getter，`_isSupportedToolCall` 新增分支。
- `lib/services/llm_service_prompts.dart`：新增 `_buildAskUserQuestionBlock`，`_buildSystemPrompt` 无条件加入，`<turn_protocol>` 增补 ASK 分支说明与"禁止混用"清单。
- `lib/widgets/ai_assistant_panel_models.dart`：新增 `_QuestionOption`/`_QuestionProposalState`/`_QuestionProposal`，`_ChatMessage` 新增字段+工厂。
- `lib/widgets/ai_assistant_panel_loop.dart`：`_continueAgentLoopBody` 拦截 `ask_user_question`；新增 `_decideQuestionProposal`。
- `lib/widgets/ai_assistant_panel_question_card.dart`（新文件）：`_QuestionProposalCard`。
- `lib/widgets/ai_assistant_panel.dart`：`_send()` 顶部的"其他"钩子；`_cancelAgent()` 的过期处理；新增 `_pendingQuestionProposal` state 字段；输入框可用性条件。

## 测试计划

- `test/services/llm_service_test.dart`：新增 `ask_user_question` 解析测试组——合法 2/6 个选项通过，1 个或 7 个选项被拒绝（`extractToolCalls` 返回空/跳过该项），缺 `question`/`header`，或某个选项缺 `label`/`description` 时被拒绝，`isAskUserQuestion` getter 命中。
- 手动验证：让模型触发一次 `ask_user_question`，确认卡片正确渲染 header/问题/选项+"其他"行；点击普通选项后卡片锁定、下方出现用户回复气泡、循环在同一 turnId 下自动继续（日志里 `t=N` 不变）；点击"其他"后主输入框获得焦点且可输入，发送后同样正确注入并继续；在卡片等待期间发一条新消息触发取消，确认旧卡片正确显示过期态且没有报错。
