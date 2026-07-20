# AI Agent 精确文件编辑（edit_file 工具）— 设计文档

日期：2026-07-20

## 背景

ssterm 的 AI Agent 已经有一个 `write_file` 结构化工具（[lib/services/llm_service_prompts.dart:142-194](../../../lib/services/llm_service_prompts.dart)），用于整篇创建/覆写文件，配套：

- 协议层：[lib/services/llm_service.dart](../../../lib/services/llm_service.dart) 的 `ToolCall.isWriteFile`（第 69-70 行）+ `path`/`content` getter（第 84-92 行）+ `_isSupportedToolCall`（第 702-714 行）。
- 循环拦截：[lib/widgets/ai_assistant_panel_loop.dart:431-463](../../../lib/widgets/ai_assistant_panel_loop.dart) 在 shell 命令执行、`[TASK_COMPLETE]` 判断之前拦截 `writeFile`，暂停循环等用户点 Apply/Reject。
- 落盘层：[lib/services/file_write_service.dart](../../../lib/services/file_write_service.dart) 的 `FileSystemAdapter`（本地 `LocalFileSystemAdapter` / SSH `SftpFileSystemAdapter` 两个实现）+ `FileWriteService`（LLM 信封格式化）。
- 状态机 + 卡片：[lib/widgets/ai_assistant_panel_models.dart:164-231](../../../lib/widgets/ai_assistant_panel_models.dart) 的 `_WriteProposal`/`_WriteProposalState` + [ai_assistant_panel_write_card.dart](../../../lib/widgets/ai_assistant_panel_write_card.dart) 的 `_WriteProposalCard`。
- Apply/Reject 决策：[lib/widgets/ai_assistant_panel_tooling.dart:234-458](../../../lib/widgets/ai_assistant_panel_tooling.dart) 的 `_proposeFileWrite`/`_decideWriteProposal`。

**现状问题**：`write_file` 只能整篇替换。系统提示词里明确写着"narrow in-place patch of a large file … use `sed`/`awk` via bash, OR inspect the file first and propose a full new version via `write_file`"（[llm_service_prompts.dart:172](../../../lib/services/llm_service_prompts.dart)）——也就是说小范围改动目前只能靠模型自己拼 `sed` 命令（容易转义出错、无预览、无 Apply/Reject 门禁），或者整篇重写一个大文件（浪费 token、diff 不直观、mtime 冲突风险更高）。本设计新增 `edit_file`：模型提供"确认见过的原文片段 → 替换后的片段"，ssterm 本地做匹配、生成真正的行级 diff 供用户审核，Apply 后走与 `write_file` 完全相同的原子提交路径。

本设计已与用户确认两点：① Apply/Reject 卡片展示**真正的行级 diff**（非纯文本对照）；② 复用现有 "Enable file write" 开关，不新增 Settings 项。

## 设计

### 1. 协议：新增 `edit_file` 工具调用

```tool_call
{"id":"call_x","name":"edit_file","arguments":{
  "path":"<absolute-path>",
  "old_string":"<must appear verbatim in the file>",
  "new_string":"<replacement text>",
  "replace_all": false
}}
```

- `old_string`/`new_string` 必填非空字符串；`old_string == new_string` 视为无效调用（模型没有实际改动）。
- `replace_all` 可选，默认 `false`：
  - `false` → 要求 `old_string` 在文件当前内容中**恰好出现一次**，否则失败。
  - `true` → 替换所有出现处（至少一处，否则同样是 no-match 失败）。
- 与 `write_file` 一样，**一轮只允许一个 `edit_file` 调用**，且该轮 turn 不得同时携带 shell `tool_call`、`[TASK_COMPLETE]`、`[ASK_USER]`、`ask_user_question`、`use_skill`、`web_search`——循环在执行任何动作前就拦截 edit_file，组合写法会静默丢弃其余内容，沿用 `write_file`/`web_search`/`use_skill` 已有的 "turn-shape rules" 表述。
- 门控：复用 `config.fileWriteEnabled`（不新增字段），系统提示词里的 `<file_edit_tool>` 块与 `<file_write_tool>` 用同一个 `fileWriteEnabled` 布尔一起出现/消失。

**`llm_service.dart` 改动**（紧邻 `isWriteFile` 之后）：
```dart
bool get isEditFile => name == 'edit_file' || name == 'file_edit' || name == 'fs.edit';
String? get oldString => arguments['old_string'] as String?; // 允许空串？不允许，见下
String? get newString { ... }
bool get replaceAll => arguments['replace_all'] == true;
```
- `oldString`/`newString`：非空字符串校验（trim 后非空），写法同 `path`/`content` getter。**不 trim 存储值本身**——`old_string` 的前导/尾随空白可能就是匹配所需要的（比如要精确替换一行末尾的空格）,只在"是否为空"判断时 trim，返回值保持原样。
- `_isSupportedToolCall` 新增分支：
  ```dart
  if (call.isEditFile) {
    return call.path != null && call.oldString != null && call.newString != null
        && call.oldString != call.newString;
  }
  ```
- `_dedupeToolCalls` 的 key 表新增一行：`'edit_file' || 'file_edit' || 'fs.edit' => '${call.name}\n${call.path}\n${call.oldString}\n${call.newString}\n${call.replaceAll}'`。

**`llm_service_prompts.dart` 改动**：新增 `_buildFileEditBlock()`，写法参照 `_buildFileWriteBlock`（第 142-194 行），要点：
- 何时用 `edit_file`：已知文件里的小范围精确改动（几行到几十行），且模型**已经通过 `cat`/`sed -n` 等方式看到过要替换的原文**。
- 何时用 `write_file`：新建文件、或改动占比接近整篇重写。
- 何时都不用、退回 shell：`fileWriteEnabled` 为 false 时（此时 `<file_edit_tool>` 块本身就不会出现在提示词里，模型看不到这个工具，自然退回 `sed`）。
- **强调 `old_string` 绝不能凭记忆/训练数据臆造**——必须是本轮对话里实际观察到的原文，否则几乎必然 no-match。
- 结果信封三种形状（成功/no-match/ambiguous-match，见第 3 节），要求模型据此决定下一步（no-match → 重新 `cat` 确认；ambiguous → 加更多上下文或传 `replace_all: true`）。
- 加入 `<turn_protocol>` 的 "MUST NOT combine" 黑名单（`_buildFileWriteBlock`/`_buildWebSearchBlock`/`_buildSkillsBlock` 里各自重复的那句话，这次连 `write_file`/`edit_file` 互斥也要写清楚：一轮不能同时提出两种文件操作）。

`_buildSystemPrompt`（第 13-25 行）里跟 `_buildFileWriteBlock` 一起受 `fileWriteEnabled` 门控：
```dart
if (fileWriteEnabled) { parts.add(_buildFileWriteBlock()); parts.add(_buildFileEditBlock()); }
```

### 2. `FileSystemAdapter` 新增 `readContent`

现有 `FileSystemAdapter`（[file_write_service.dart:132-188](../../../lib/services/file_write_service.dart)）只有 `preview`（元数据：是否存在/大小/mtime/行数）和 `commit`（整篇写入），没有"取出当前完整内容"的方法——`preview` 里虽然本地 adapter 会 `readAsLines()` 来数行数，但那段结果没有对外暴露。edit_file 必须拿到真实字节才能做字符串匹配、生成 `newContent`、算 diff。

新增抽象方法：
```dart
/// Read the full current content of [path] as UTF-8 text. Throws
/// [FileWriteException] with:
///   - notSupported: adapter unavailable (mirrors preview/commit)
///   - parentMissing/invalidPath: same path-resolution failures as preview
///   - io: file doesn't exist, isn't valid UTF-8, or exceeds [_maxEditableSize]
Future<String> readContent(String path);
```
- 新增 `FileWriteErrorKind.tooLarge`（现有 6 个 kind 之外新增一个），复用现有 4MB 阈值常量（当前分散写在 `preview` 里的 `4 * 1024 * 1024`，本次顺手提成一个共享的 `_maxEditableSize` 常量,两处实现都引用它）。
- `LocalFileSystemAdapter.readContent`：解析路径（复用 `_resolvePath`）→ `File(resolved).stat()` 检查大小 → 超限抛 `tooLarge` → `readAsString()`，解码失败（二进制文件）包一层 `io` kind 说明"文件不是合法 UTF-8 文本，无法编辑，请改用 write_file 整篇重写或 shell 处理"。
- `SftpFileSystemAdapter.readContent`：解析路径（复用 `_resolveRemotePath`）→ `stat` 检查大小 → 超限抛 `tooLarge` → `client.open` + `readBytes()` + `utf8.decode`,失败同上归为 `io`。
- `FileWriteService.formatErrorForLlm` 的 `switch` 新增 `tooLarge` 分支的 recovery 文案："File too large to edit in-place (> 4 MB). Use `sed`/`awk` via bash for large files, or read a smaller slice with `head`/`grep -n`/`sed -n` to confirm the exact old_string before retrying with a NARROWER match."

### 3. 匹配 + 生成新内容（新文件 `lib/services/file_edit_service.dart`）

Stateless 帮助类，仿照 `FileWriteService` 的组织方式（纯函数 + LLM 信封 formatter，方便单测）：

```dart
enum EditMatchErrorKind { noMatch, ambiguousMatch }

class EditMatchException implements Exception {
  final EditMatchErrorKind kind;
  final int matchCount; // 0 for noMatch, N>=2 for ambiguousMatch
}

class EditMatchResult {
  final String newContent;
  final int matchCount; // how many replacements were made (1, or N for replace_all)
}

class FileEditService {
  /// Pure function: locate [oldString] in [current], replace per
  /// [replaceAll], return the new full content. Throws
  /// [EditMatchException] on 0 or >1 (non-replace_all) matches.
  static EditMatchResult applyEdit({
    required String current,
    required String oldString,
    required String newString,
    required bool replaceAll,
  });

  static String formatNoMatchForLlm(String path, String oldString);
  static String formatAmbiguousForLlm(String path, String oldString, int count);
  static String formatSuccessForLlm(String path, int matchCount, FileWriteResult r);
  static String formatRejectionForLlm(String path, {String? reason});
}
```

- 匹配用普通的 `String.indexOf` 循环数出现次数（不需要正则——`old_string` 是字面量，不是 pattern）。`replace_all` 用 `current.replaceAll(oldString, newString)`（Dart 内置，非重叠语义,与"数出现次数"用同一套 `indexOf` 循环保持结果一致，避免重叠匹配导致计数和实际替换对不上）。
- `noMatch`/`ambiguousMatch` 信封分别对应第 1 节里提到的两种失败恢复路径。

### 4. Loop 集成 —— 预览阶段就完成匹配校验

与用户确认的方案一致：**匹配校验发生在展示卡片之前**，不是等用户点 Apply 才发现"这处替换有歧义"。具体流程（`ai_assistant_panel_tooling.dart` 新增 `_proposeFileEdit`，仿照 `_proposeFileWrite` 第 234-341 行的结构）：

1. `fileWriteEnabled` 为 false → 与 `_proposeFileWrite` 一致，直接注入禁用信封，`injectedAndContinue`。
2. adapter 缺失/不可用 → 同上，`notSupported` 信封。
3. `adapter.preview(path)` 拿 `mtime`（复用现有逻辑，用作后续 `commit` 的并发 token）。
4. `adapter.readContent(path)` 拿当前内容——若抛 `FileWriteException`（含新增的 `tooLarge`），格式化后注入历史，`injectedAndContinue`（这一步失败不应该弹卡片，因为连"改成什么样"都算不出来）。
5. `FileEditService.applyEdit(...)`——若抛 `EditMatchException`：格式化 `noMatch`/`ambiguousMatch` 信封注入历史，`injectedAndContinue`（同样不弹卡片：让模型先把 `old_string` 定位对，再重新提议，不该在 UI 上摆一张"注定失败"的卡片让用户去点）。
6. 匹配成功 → 构造 `_EditProposal`（第 5 节），`setState` 追加卡片，`agentLoopStatus` 更新为 "Awaiting Apply for edit to <path>"，返回 `waitingForUser`——循环在此暂停,与 `write_file` 完全一致的"返回上层、finally 解锁终端"路径。

`_decideEditProposal`（仿照 `_decideWriteProposal` 第 343-458 行）：
- Reject → `FileEditService.formatRejectionForLlm`，注入历史，continue 循环。
- Apply → `adapter.commit(path, proposal.newContent, expectedMtime: proposal.mtime)`，成功用 `formatSuccessForLlm`（沿用 `FileWriteService.formatSuccessForLlm` 的 `[File written]` 信封格式,但加一行 `edits: N`），mtime 冲突/IO 失败复用 `FileWriteService.formatErrorForLlm` 的错误分支（`commit` 抛出的仍是 `FileWriteException`，与 write_file 同源）。
- 同样有"过期检测"（`proposal.agentGeneration != _generation` → 标记 stale，不碰新对话历史），与 `_decideWriteProposal`/`_decideDangerProposal`/`_decideQuestionProposal` 三者一致的模式。

`ai_assistant_panel_loop.dart` 的 `_continueAgentLoopBody` 里，`editFileTool` 的提取、拦截位置紧邻 `writeFileTool` 之后（在 `askUserQuestionTool` 之前，taskComplete/askUser 的 `break` 之前）——沿用现有"结构化工具都排在裸标记判断前面"的顺序；`markerLabel` 的日志三元链新增 `edit_file:<path>` 一档。

### 5. 数据模型（`ai_assistant_panel_models.dart`）

```dart
enum _EditProposalOutcome { injectedAndContinue, waitingForUser } // 复用 _WriteProposalOutcome 语义，独立枚举避免跨类型误用

enum _EditProposalState { pending, applying, applied, rejected, failed } // 与 _WriteProposalState 一一对应

class _EditProposal {
  final String requestedPath;
  final String resolvedPath;
  final String oldString;
  final String newString;
  final String currentContent;   // 编辑前的完整内容 — 供 diff 计算
  final String newContent;       // FileEditService.applyEdit 算好的结果
  final int matchCount;          // 1，或 replace_all 时的实际替换次数
  final DateTime? mtime;         // preview 阶段拿到的并发 token
  final int agentGeneration;

  _EditProposalState state = _EditProposalState.pending;
  String? outcomeMessage;
  FileWriteResult? result;
}
```

`_ChatMessage` 新增 `editProposal` 字段 + `_ChatMessage.editProposal(proposal)` 工厂，规则同 `writeProposal`（nullable，兼容热重载——参照 [ai_assistant_panel_models.dart:70-75](../../../lib/widgets/ai_assistant_panel_models.dart) 的注释）。

### 6. 行级 diff 工具（新文件 `lib/utils/line_diff.dart`）

不引入新依赖（`pubspec.yaml` 里没有任何 diff 相关包，符合项目"依赖精简"的现状）。实现一个约 80 行的最长公共子序列（LCS）行级 diff：

```dart
enum DiffLineKind { equal, added, removed }
class DiffLine {
  final DiffLineKind kind;
  final String text;
  final int? oldLineNo; // null for added
  final int? newLineNo; // null for removed
}
List<DiffLine> computeLineDiff(String oldText, String newText);
```

- 按 `\n` 切行（不含末尾换行的空尾行处理与 `extractWriteFile` 现有的"去掉一个首尾换行"约定保持一致的直觉,细节在实现阶段处理）。
- 经典 DP：`lcs[i][j]` 表格 + 回溯生成 equal/added/removed 序列。文件按 4MB 阈值已经在 `readContent` 处截断，单次 diff 的行数量级可控（典型编辑场景是几百到几千行），O(n·m) 的朴素 LCS 在这个量级下足够快，不需要 Myers O(ND) 优化。
- 纯函数，独立于 Flutter，方便单测。

### 7. Diff 卡片 UI（新文件 `ai_assistant_panel_edit_card.dart`，`_EditProposalCard`）

视觉结构参照 `_WriteProposalCard`（容器/配色/状态徽标/Apply-Reject 按钮布局），核心区别在"预览"部分：

- Header：路径 + 状态徽标。`matchCount > 1` 时徽标显示 "EDIT ×N"，否则 "EDIT"。
- **默认展开**（不同于 `_WriteProposalCard` 默认折叠——改动通常只有几行，折叠反而多一次点击）。
- 用 `computeLineDiff(proposal.currentContent, proposal.newContent)` 算出的 `List<DiffLine>` 渲染：
  - `removed` 行：红色系背景 + 删除线，行首 `-`。
  - `added` 行：绿色系背景，行首 `+`。
  - `equal` 行：正常前景色，行首空格,用于上下文。
  - **上下文折叠**：连续 `equal` 行超过 6 行时,只显示改动点前后各 3 行,中间折叠成一行可点击的 "… N 行未变，点击展开 …"（点击后 `setState` 展开该折叠段,状态存在 card 的 `State` 里,不影响 `_EditProposal` 本身）。
  - 行号：左侧一列等宽字体行号（`removed` 显示旧行号，`added` 显示新行号,`equal` 两列都显示，仿 GitHub diff 视觉但简化为单列——旧/新行号在等宽字体里对齐显示，具体到实现阶段再定字符宽度）。
- Apply/Reject 按钮行为、Reject 理由输入框、`applying` 时的按钮禁用/spinner，直接照抄 `_WriteProposalCard` 对应部分（[ai_assistant_panel_write_card.dart:184-246](../../../lib/widgets/ai_assistant_panel_write_card.dart)）。

`_buildAgentMessage`（`ai_assistant_panel.dart` 里根据 `_ChatMessage` 字段分派到具体卡片 widget 的地方）新增一个 `if (msg.editProposal != null) return _EditProposalCard(...)` 分支,顺序上放在 `writeProposal` 判断附近。

### 8. 设置项

不新增字段。[settings_sheet_agent.dart:313-343](../../../lib/views/settings/settings_sheet_agent.dart) 的 `_buildFileWriteSection` 文案更新：
- 标题："Enable file write" → "Enable file write & edit"。
- 说明文字补一句："… lets the agent also propose targeted `edit_file` search/replace edits, shown as a line-level diff card with the same Apply/Reject gate."

## 不在本次范围内

- 不支持一轮多个 `edit_file`（不做 Claude Code 的 `MultiEdit`）——需要连续编辑同一文件多处时,模型分多轮各自 `cat` 确认后再编辑。
- 不支持正则/模糊匹配——`old_string` 必须字面量精确匹配，与 Claude Code 的 `Edit` 工具语义一致。
- 不新增 Settings 开关，不新增 `AgentConfig` 字段。
- 不对超过 4MB 的文件做流式/分块编辑——直接拒绝，退回 `sed`/`awk`。
- 不做跨 turn 的"批量编辑计划"（Plan 模式）——这是另一个更大的功能，不在本次范围。
- 不新增 loop/widget 级别的自动化测试基础设施（沿用现有项目现状：`ai_assistant_panel_loop.dart` 目前没有测试文件，本次也不补;新增的纯函数部分——`FileEditService`/`computeLineDiff`——会有单测,见下）。

## 影响文件

- `lib/services/llm_service.dart`：`ToolCall` 新增 `isEditFile`/`oldString`/`newString`/`replaceAll` getter，`_isSupportedToolCall`、`_dedupeToolCalls` 新增分支。
- `lib/services/llm_service_prompts.dart`：新增 `_buildFileEditBlock`，`_buildSystemPrompt` 与 `fileWriteEnabled` 一起门控，`<turn_protocol>` 补充 write_file/edit_file 互斥说明。
- `lib/services/file_write_service.dart`：`FileSystemAdapter` 新增 `readContent`；`FileWriteErrorKind` 新增 `tooLarge`；两个 adapter 实现；`FileWriteService.formatErrorForLlm` 新增 `tooLarge` 分支；提取共享的 `_maxEditableSize` 常量。
- `lib/services/file_edit_service.dart`（新文件）：`FileEditService`、`EditMatchException`、`EditMatchResult`。
- `lib/utils/line_diff.dart`（新文件）：`computeLineDiff`、`DiffLine`、`DiffLineKind`。
- `lib/widgets/ai_assistant_panel_models.dart`：新增 `_EditProposalOutcome`/`_EditProposalState`/`_EditProposal`，`_ChatMessage` 新增字段+工厂。
- `lib/widgets/ai_assistant_panel_loop.dart`：`_continueAgentLoopBody` 提取并拦截 `edit_file`（紧邻 `write_file` 拦截块之后）。
- `lib/widgets/ai_assistant_panel_tooling.dart`：新增 `_proposeFileEdit`/`_decideEditProposal`。
- `lib/widgets/ai_assistant_panel_edit_card.dart`（新文件）：`_EditProposalCard`。
- `lib/widgets/ai_assistant_panel.dart`：`_buildAgentMessage` 新增 `editProposal` 分派分支。
- `lib/views/settings/settings_sheet_agent.dart`：`_buildFileWriteSection` 文案更新。

## 测试计划

- `test/utils/line_diff_test.dart`（新）：纯插入/纯删除/纯替换/无变化/首尾行变化等基础用例；确认 `oldLineNo`/`newLineNo` 编号正确。
- `test/services/file_edit_service_test.dart`（新）：唯一匹配成功；0 次匹配抛 `noMatch`；多次匹配且 `replace_all=false` 抛 `ambiguousMatch`（附正确 `matchCount`）；`replace_all=true` 替换全部出现；`old_string == new_string` 场景（虽然协议层会先拦截，但服务层也应有对应行为的单测覆盖）。
- `test/services/llm_service_test.dart`：新增 `edit_file` 解析测试组——合法调用通过；缺 `old_string`/`new_string`/`path` 被拒绝；`old_string == new_string` 被拒绝；`isEditFile`/`replaceAll` getter 命中；同一轮 `write_file` + `edit_file` 同时出现时的去重/互斥行为（若适用）。
- `test/services/file_write_service_test.dart`（若存在，否则新增用例文件）：`readContent` 本地 adapter 的正常读取/超限/二进制文件失败路径。
- 手动验证：
  1. 唯一匹配 → 卡片默认展开、diff 正确高亮、Apply 后文件确实被改、`[File edit failed]`/成功信封格式正确、mtime 并发冲突时正确报错（编辑窗口期间手动改一下文件）。
  2. 0 次匹配 → 不弹卡片，模型收到 `no_match` 信封并在下一轮重新 `cat` 确认。
  3. 多次匹配未传 `replace_all` → 不弹卡片，模型收到 `ambiguous_match` 信封（含出现次数）。
  4. `replace_all: true` 命中多处 → 卡片徽标显示 "EDIT ×N"，diff 里所有命中点都正确高亮。
  5. 大文件（>4MB）→ `readContent` 直接拒绝，模型被引导退回 `sed`。
  6. 关闭 "Enable file write & edit" 开关 → 系统提示词里两个 block 都消失，模型改用 shell 命令。
