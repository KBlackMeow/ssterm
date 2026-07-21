# 文件编辑器语法高亮 — 设计文档

日期：2026-07-21

## 背景

ssterm 的 SFTP 文件编辑器（[lib/views/file_editor_view.dart](../../../lib/views/file_editor_view.dart)，`FileEditorView`/`FileEditorViewState`，上一个迭代刚完成并合并）目前是一个纯 `TextField`：无语法高亮、无行号。这在原设计文档（[2026-07-20-sftp-file-editor-design.md](2026-07-20-sftp-file-editor-design.md)）里是明确的 MVP 范围声明，其"不在本次范围内"一节写着"语法高亮、行号……——纯文本 `TextField`，MVP"，实现计划的 post-plan notes 也留了话："如果未来想要语法高亮，需要一个独立的 spec"。本文档就是那个后续 spec。

现状（读代码确认）：

- `FileEditorViewState`（`file_editor_view.dart:60-320`）用一个普通 `TextEditingController`（`_controller`，第 61 行）驱动 `TextField`（第 233-248 行），脏状态检测靠 `_controller.text != _originalContent`（第 84 行的 `_onTextChanged`）。
- `save()`（第 96-140 行）、`_resolveConflict()`（第 142-174 行）、`_reload()`（第 176-192 行）都是读/写 `_controller.text`。
- `pubspec.yaml` 里没有任何编辑器/语法高亮相关依赖。

本设计已与用户确认的关键决策：
- **引入现成包**，不手写多语言词法分析——手写 diff 算法（edit_file 功能里做过）和手写多语言语法高亮不是一个量级的工作量，前者是一个自包含的 ~150 行算法，后者是开放式的、每种语言都要维护语法规则的长期工程。
- 选型：[`flutter_code_editor`](https://pub.dev/packages/flutter_code_editor)（MIT，基于 `package:highlight`，100+ 语言，代码折叠/自动补全等功能自带）。核心原因：它的 `CodeController` **直接继承自 `TextEditingController`**（`Object → ChangeNotifier → ValueNotifier<TextEditingValue> → TextEditingController → CodeController`），可以整体替换 `_controller` 的类型而不用重写脏检测/保存逻辑的调用形状。
- 行号：加上（`flutter_code_editor` 自带 gutter/行号支持，是同一个包白送的能力，不单独做取舍）。
- 代码折叠：见下方"正确性风险"一节——功能上不主动关闭，但保存/脏检测的读取方式要能在折叠状态下依然正确，不能丢内容。
- 语言识别：只按文件扩展名映射，不做基于内容的探测。
- 高亮主题：跟随现有深色终端主题选一个固定的 `highlight` 主题，不做主题可配置项。

## 设计

### 1. 依赖新增

`pubspec.yaml` 新增：
```yaml
flutter_code_editor: ^<latest stable>
```
（具体版本号在实现阶段跑 `flutter pub add flutter_code_editor` 由 pub 解析，不在 spec 里写死一个可能很快过期的版本号。）该包依赖 `package:highlight`（语言语法）和 `package:flutter_highlight`（主题色板），会作为传递依赖一起拉入，不需要单独声明。

### 2. 正确性风险：折叠状态下 `.text` vs `.fullText`

`CodeController` 折叠代码块后，内置的 `.text`/`.value` 只反映**可见**文本；真实的完整内容（含折叠掉的部分）要读 `.fullText`。如果 `save()`/`_onTextChanged`/`_reload()` 继续用 `.text`，一旦用户折叠了一段代码再保存，折叠掉的内容会被**悄悄从文件里丢掉**——这是数据丢失风险。

处理方式：**`FileEditorViewState` 里所有读取当前编辑内容的地方（脏检测比较、`save()`/`_resolveConflict()` 传给 `adapter.commit()` 的内容参数），统一改用 `_controller.fullText` 而不是 `_controller.text`**。这个改动本身很小（把几处 `_controller.text` 换成 `_controller.fullText`），但必须做到——不依赖"默认没开折叠功能所以用 `.text` 也凑合"这种脆弱假设，因为折叠 UI 的具体默认行为要到实现阶段读包源码/文档才能 100% 确认。用 `.fullText` 是无论折叠功能最终暴露成什么样都成立的安全选择。

`_reload()`/`initState()` 里给 controller 赋新内容时（`_controller.text = content` 这类），保持不变——赋值走的是标准 `TextEditingController` 接口，`CodeController` 重写后自己会正确处理成"全新的、未折叠的内容"。

### 3. 语言识别（新增一个纯函数，可单测）

新增文件级私有函数（或小型静态类）：

```dart
Mode? _languageForPath(String path) {
  final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'dart' => dartLang,
    'py' => pythonLang,
    'js' || 'mjs' || 'cjs' => javascriptLang,
    'ts' => typescriptLang,
    'json' => jsonLang,
    'yaml' || 'yml' => yamlLang,
    'sh' || 'bash' || 'zsh' => bashLang,
    'md' || 'markdown' => markdownLang,
    'html' || 'htm' => xmlLang, // highlight 用 xml 语法处理 html
    'css' => cssLang,
    'sql' => sqlLang,
    'toml' => iniLang, // toml 没有专门语法时退回 ini，足够应付 key=value 场景
    'conf' || 'ini' || 'cfg' => iniLang,
    'xml' => xmlLang,
    'go' => goLang,
    'rs' => rustLang,
    'java' => javaLang,
    'c' || 'h' => cLang,
    'cpp' || 'cc' || 'hpp' => cppLang,
    _ => null, // 未知扩展名 → 不高亮，退回纯文本
  };
}
```
（具体语言标识符的确切导入名以 `package:flutter_code_editor`/`package:highlight` 实际暴露的 API 为准，实现阶段核对；上面列的是要�covering 的扩展名集合，不是精确到字面量的最终代码。）

返回 `null` 时，`CodeController` 不设置 `language`（或者干脆不用 `CodeField`/`CodeTheme` 包裹，退回原来的纯 `TextField`）——两种都能接受，实现阶段选更省代码的一种；用户能感知到的行为是"没识别出的文件类型看起来就是纯文本编辑器，没有报错、没有异常"。

### 4. Widget 改动

`FileEditorViewState`：
- `TextEditingController _controller` → `CodeController _controller`。
- `initState()`（第 68-74 行）：`CodeController(text: widget.initialContent, language: _languageForPath(widget.path))`，其余（`_originalContent`/`_mtime`/`addListener`）不变。
- `_onTextChanged`（第 83-86 行）：`_controller.text` → `_controller.fullText`。
- `save()`（第 103-106 行 `_adapter.commit(widget.path, _controller.text, ...)`）→ 改用 `_controller.fullText`。
- `_resolveConflict()`（第 155 行同样的 `commit` 调用）→ 同上。
- `build()`（第 233-248 行的 `TextField(...)`）→ 换成 `CodeTheme(data: CodeThemeData(styles: <选定主题>), child: CodeField(controller: _controller, textStyle: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, height: 1.4), gutterStyle: GutterStyle(...)))`，字体/字号延续现状，颜色由主题接管（不再用 `TextStyle(color: fg, ...)` 手动指定文字颜色）。
- 顶部工具条（`_buildToolbar`，第 258-310 行）不变——路径、脏状态点、Reload/Save 按钮跟高亮无关。
- Cmd/Ctrl+S 快捷键（`CallbackShortcuts`，第 213-221 行）不变。
- mtime 冲突弹窗（`_ConflictDialog`，第 322-387 行）不变。

### 5. 主题选择

用 `flutter_code_editor` 重新导出的 `flutter_highlight` 主题里一个偏深色、跟 ssterm 终端配色（JetBrains Mono、深色背景）视觉上不违和的现成主题（比如 `atomOneDarkTheme` 或 `monokaiSublimeTheme`，实现阶段挑一个跑起来看着顺眼的，不引入自定义主题机制）。不做用户可配置项——这不是这次范围。

## 不在本次范围内

- 代码折叠 UI 本身的开关/优化——不主动关闭,但通过第 2 节的 `.fullText` 读取方式确保就算折叠了也不会丢内容。折叠交互体验好不好用是另一个话题,不在这次评估范围。
- 自动补全、查找替换、多光标——`flutter_code_editor` 可能自带一部分,但这次不特意启用/调优,有什么默认行为就是什么行为,只要不影响保存正确性。
- 基于文件内容(而非扩展名)的语言探测。
- 高亮主题可配置化。
- 语言映射表覆盖所有可能的扩展名——先覆盖运维/开发场景常见的一批,未识别的退回纯文本,不算功能缺陷。

## 影响文件

- `pubspec.yaml`:新增 `flutter_code_editor` 依赖。
- `lib/views/file_editor_view.dart`:`TextEditingController` → `CodeController`;新增 `_languageForPath` 语言映射函数;`.text` → `.fullText` 的三处改动(脏检测、`save()`、`_resolveConflict()`);`TextField` → `CodeTheme(CodeField(...))`。

## 测试计划

- `test/views/file_editor_language_test.dart`(新):`_languageForPath` 是纯函数,可以直接单测——覆盖已列出的每个扩展名分支、大小写不敏感(`.PY` 和 `.py` 应该给出同一个结果)、无扩展名、未知扩展名(应返回 `null`)。这是这次改动里唯一有自动化测试基础设施覆盖的部分(项目里 widget 层一贯没有自动化测试,`FileEditorView` 本体延续这个现状)。
- 手动验证:
  1. 打开一个 `.py`/`.yaml`/`.sh` 等常见类型文件 → 关键字/字符串/注释应该有颜色区分,行号在左侧显示。
  2. 打开一个未知扩展名(比如 `.foobar`)的文本文件 → 能正常编辑,没有报错,只是没有颜色。
  3. 编辑、保存、mtime 冲突、Cmd+S、未保存关闭确认——把上一版已经验证过的手动 QA 场景（[2026-07-20-sftp-file-editor.md](../plans/2026-07-20-sftp-file-editor.md) 的 Task 4 Step 7）**重新跑一遍**,确认高亮改动没有破坏这些已有功能。
  4. 如果折叠功能默认可用:折叠一段代码后保存 → 用另一个终端 `cat` 确认文件内容完整(没有丢掉被折叠的部分)。
