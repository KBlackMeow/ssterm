# SFTP 面板内文件编辑器 — 设计文档

日期：2026-07-20

## 背景

ssterm 的 SFTP 浏览面板（[lib/views/sftp_view.dart](../../../lib/views/sftp_view.dart)，配套 [sftp_view_menus.dart](../../../lib/views/sftp_view_menus.dart)/[sftp_view_widgets.dart](../../../lib/views/sftp_view_widgets.dart)/[sftp_view_mobile.dart](../../../lib/views/sftp_view_mobile.dart)）目前只有文件**管理**类操作：浏览目录（`_listDir`）、上传/下载（`_upload`/`_download`）、重命名（`_rename`）、删除（`_delete`）、新建文件夹（`_mkdir`）——没有"打开一个远程文件、在界面里改内容、保存回去"的编辑器功能。

同一个 session 里刚做完的 AI Agent `edit_file`/`write_file` 工具已经把远程文件读写的底层管道搭好了：`SftpFileSystemAdapter`（[lib/services/file_write_service.dart](../../../lib/services/file_write_service.dart)）封装了 `readContent`（4MB 大小上限、非 UTF-8 拒绝）和 `commit`（原子写入 + `expectedMtime` 并发冲突检测）。本设计**只复用这两个底层 I/O 方法**，不涉及 `ToolCall`/agent loop/对话历史——这是一个纯粹由用户在 SFTP 面板里手动触发的功能，跟 AI Agent 是否配置、是否运行完全无关。

本设计已与用户确认的关键决策：
- 触发方式：双击文件行 **+** 右键菜单加一项 "Edit"，两者等价。
- 范围仅限 **SSH/SFTP 远程文件**，不做本地文件编辑（没有本地文件浏览器入口，是独立功能，本次不做）。
- 关闭有未保存改动的编辑器标签页时，**弹确认对话框**（保存 / 不保存 / 取消）。
- 保存时遇到 mtime 冲突，**提示用户选择**：强制覆盖，或放弃本地改动重新加载。
- 错误提示是**面向人类用户的文案**，不是 AI 工具那套面向模型的信封格式（`FileWriteErrorKind` 枚举复用，但文案自己写）。
- **仅桌面端**：移动端的 SFTP 面板复用同一个 `SftpView`/`_SftpMenusMixin`，但标签页/会话导航是完全不同的 UI（[lib/app/main_mobile.dart](../../../lib/app/main_mobile.dart) 的会话列表，不是桌面的 `_TabBar`）。本次只接桌面的 `_TabBar`/`AppTab` 体系，移动端作为后续独立工作。

## 设计

### 1. 触发入口（`sftp_view.dart` / `sftp_view_menus.dart`）

文件行的 `InkWell`（`sftp_view.dart:871` 附近，桌面渲染路径）新增 `onDoubleTap`；`_SftpMenusMixin`（`sftp_view_menus.dart`）新增一个 "Edit" 菜单项，与 Rename/Download/Delete 并列。两者都调用 `SftpViewState._openInEditor(SftpName entry)`（新方法，仿照 `_delete`/`_rename` 的实现位置：在 `sftp_view.dart` 里实现，在 `_SftpMenusMixin` 里声明为 abstract 供菜单调用）。

目录 / 指向目录的符号链接不触发（复用 `_navigateEntry` 已有的判断逻辑，`sftp_view.dart:415-434`）。

`_openInEditor` 的打开前校验（失败时用 `SnackBar` 报错，**不**创建编辑器标签页）：
1. 构造 `SftpFileSystemAdapter(sftp: widget.sftp, label: ...)`，调用 `.preview(path)`——一次拿到 size 和 mtime，不再单独调 `stat`。size 超过 `4 * 1024 * 1024`（与 `FileSystemAdapter._maxEditableSize` 同一个阈值）→ "文件太大，无法在应用内编辑（超过 4MB）"，到此为止，不再往下读内容。
2. size 校验通过后调用 `.readContent(path)` 拿内容。抛出的 `FileWriteException`：
   - `FileWriteErrorKind.io`（非 UTF-8 二进制内容命中此分支）→ "不是文本文件，无法编辑"。
   - `permission`/其它 → 对应的人类可读文案（不复用 `FileWriteService.formatErrorForLlm` 的模型导向措辞，自己写）。

成功后，`SftpView` 通过新增的构造参数回调通知宿主创建标签页：

```dart
final void Function({
  required String path,
  required String initialContent,
  required DateTime? mtime,
}) onOpenEditorTab;
```

### 2. Tab 模型（`lib/models/tab_model.dart`）

`AppTabKind` 新增 `editor`。`AppTab` 新增一组编辑器专用字段（仿照 `settings` kind 的轻量写法，不碰终端/SSH/PTY 那堆状态）：

```dart
String? editorPath;              // 远程绝对路径，展示 + 保存用
SftpClient? editorSftp;          // 打开时捕获的 SFTP client 引用
String? editorLabel;             // 来源 SSH tab 的标题，如 "ssh: prod-db"
DateTime? editorMtime;           // 打开时（或最近一次成功保存/重新加载时）的 mtime，作并发 token
final ValueNotifier<bool> editorDirty = ValueNotifier(false);
```

新增 `factory AppTab.editor({required String path, required SftpClient sftp, required String label, required DateTime? mtime})`。**不带 `initialContent` 参数**——`AppTab` 只存"这个 tab 是什么、指向哪个文件、并发 token 是什么"这类持久状态；文件的实际文本内容只活在 `FileEditorView` 自己的 `TextEditingController` 里，`initialContent` 作为 `FileEditorView` 的构造参数直接传入（第 3 节），不落在 `AppTab` 上，避免两处状态不同步。`icon` getter（`tab_model.dart:257-263`）新增 `AppTabKind.editor => Icons.edit_note` 分支——这是个 exhaustive switch，编译期会强制处理新增枚举值，不会漏掉调用点。

`AppTab.dispose()`（`tab_model.dart:231-255`）不需要特殊处理：`editorSftp` 只是借用来源 SSH tab 的 client 引用，不归编辑器 tab 所有，不应该在编辑器 tab 关闭时被 close——它的生命周期跟着来源 SSH tab 走。

### 3. 新增 tab 的插入位置

宿主侧新方法 `_openEditorTab({required path, required initialContent, required mtime})`（加在 SSH 相关的 mixin 里，紧邻 `_newLocalTab` 这类方法），插入方式跟 `_newLocalTab`（`main_local.dart:637-639`）一致：

```dart
setState(() {
  _tabs.add(AppTab.editor(path: path, sftp: sourceTab.sftp!, label: 'ssh: ${sourceTab.title}', mtime: mtime));
  _active = _tabs.length - 1;
});
```

`initialContent` 不落在 `AppTab` 上（见第 2 节）：`_openEditorTab` 把它连同 `path`/`mtime` 一起，通过 `_buildPrimaryContent`（`main_views.dart:457-488`）新增的 `AppTabKind.editor` 分支直接构造 `FileEditorView(initialContent: ..., path: tab.editorPath!, sftp: tab.editorSftp!, ...)`。`FileEditorView` 只在 `initState` 里用这个值初始化 `TextEditingController` 一次，之后的一切读写都通过 controller，`initialContent` 参数本身用完即弃。

### 4. 编辑器 Widget（新文件 `lib/views/file_editor_view.dart`）

`FileEditorView extends StatefulWidget`，接管 `_buildPrimaryContent`（`main_views.dart:457-488`）里新增的 `AppTabKind.editor` 分支。

State 内部：
- `TextEditingController`，初始值 = 打开时读到的内容；同时存一份 `_originalContent` 快照。
- `controller.addListener` 里比较 `controller.text != _originalContent`，写入 `tab.editorDirty.value`（避免每帧重建都重新 diff；只在真正变化时才写，`ValueNotifier` 自身也会跳过相同值的重复通知）。
- 顶部工具条：文件路径（过长省略号，`TextOverflow.ellipsis`）、脏状态指示（小圆点，参照 `_WriteProposalCard` 的状态徽标视觉语言但用中性配色，不是 Apply/Reject 那种）、Save 按钮、Reload 按钮（丢弃本地改动，重新 `readContent`）。
- 主体：`Expanded(child: TextField(controller: _controller, maxLines: null, expands: true, textAlignVertical: TextAlignVertical.top, decoration: InputDecoration.collapsed(hintText: null)))`——`expands: true` 让 `TextField` 自己撑满 `Expanded` 分配的空间并内置滚动，不需要额外套 `SingleChildScrollView`。等宽字体沿用项目里已经在用的 `fontFamily: 'JetBrainsMono'`（如 [ai_assistant_panel_write_card.dart:97](../../../lib/widgets/ai_assistant_panel_write_card.dart)）。
- 快捷键：`Cmd/Ctrl+S` 触发保存，用 `Shortcuts`/`CallbackShortcuts` 包一层，作用域限定在这个 widget 子树，不影响其它 tab。
- **本版不做**：语法高亮、行号、多光标、查找替换——纯 `TextField`，MVP。

### 5. 保存流程

`_save()`：
1. 构造 `SftpFileSystemAdapter(sftp: tab.editorSftp, label: tab.editorLabel)`。
2. `await adapter.commit(tab.editorPath, controller.text, expectedMtime: tab.editorMtime)`。
3. 成功 → `_originalContent = controller.text`，`tab.editorMtime = result.mtime`，`tab.editorDirty.value = false`，用 `SnackBar` 提示"已保存"（跟第 1 节的打开前校验错误走同一种反馈机制，风格统一）。
4. 抛 `FileWriteException(kind: mtimeMismatch)` → 弹 `showDialog<bool>`（样式仿照 `_delete` 的确认框，`sftp_view.dart:329`），文案类似"该文件在你编辑期间被修改过"，两个按钮：
   - **强制覆盖**：不带 `expectedMtime` 重新调用一次 `commit`（等价于用户主动放弃并发检测）。
   - **重新加载**：`adapter.readContent(path)` + `adapter.preview(path)` 拿最新内容和 mtime，替换 `controller.text`、`_originalContent`、`tab.editorMtime`，`tab.editorDirty.value = false`（本地改动被丢弃）。
5. 其它 `FileWriteException`（权限、IO、`notSupported`——比如底层 SSH 会话已断开重连导致 `editorSftp` 失效）→ 工具条内联展示一条人类可读的错误文案（复用 `e.kind` 分类，文案自己写，不调 `FileWriteService.formatErrorForLlm`）。不做自动重连兜底，跟 AI 工具现有行为一致——`FileSystemAdapter.isAvailable` 为 false 时保存失败即可，用户可以手动关闭标签页重新从 SFTP 面板打开。

### 6. 关闭确认

现状：`_TabBar.onClose` 是 `ValueChanged<int>`（`main_chrome.dart:41`），在 `main_chrome.dart:175` 同步调用 `widget.onClose(i)`；宿主侧 `main_views.dart:44` 直接把它接到 `_closeTab`（`main_ssh.dart:581`，同步、无确认）。

**不改 `_TabBar` 的 widget API**（`onClose` 签名维持 `ValueChanged<int>` 不变，`_TabBar` 内部逻辑零改动）——只改宿主侧传入的闭包：

```dart
onClose: (i) => _requestCloseTab(i),   // 替换原来的 onClose: _closeTab
```

新增 `Future<void> _requestCloseTab(int i) async`：
- 非 `editor` kind，或 `editor` 但 `editorDirty.value == false` → 直接 `_closeTab(i)`，行为与现状完全一致。
- `editor` 且 `editorDirty.value == true` → 弹三按钮确认框（"未保存的改动" / 保存 / 不保存 / 取消）：
  - **保存**：调 `_save()`（复用第 5 节逻辑），成功后 `_closeTab(i)`；失败则不关闭，把错误展示给用户（同第 5 节的错误路径）。
  - **不保存**：直接 `_closeTab(i)`。
  - **取消**：什么都不做。

移动端的 `main_mobile.dart`/`main_mobile_connections.dart` 里 `onCloseSession`/`onClose` 同样是同步 `ValueChanged<int>`——按第 6 节末尾的范围声明，本次不改移动端，这些调用点保持原样。

### 7. 会话失效场景

若承载编辑器 tab 的来源 SSH tab 断开重连（`AppTab.clearDeadSshTransport()`，`tab_model.dart:178-212`，会把 `sftp` 置 null 并 close 掉旧 client），`editor` tab 手上持有的 `editorSftp` 是打开时的**快照引用**，不会跟着更新——旧 client 已被关闭，后续 `commit`/`readContent` 调用会直接失败（`isAvailable` 为 false 或抛 `notSupported`），走第 5 节步骤 5 的错误展示路径。不做"跟随来源 tab 自动换新 client"的重连兜底——这是本次明确排除的复杂度，用户可以关闭编辑器 tab 重新从 SFTP 面板打开。

## 不在本次范围内

- 语法高亮、行号、查找替换、多光标——纯文本 `TextField`，MVP。
- 本地文件编辑——没有本地文件浏览器入口，是独立功能。
- 移动端（`main_mobile.dart`）——标签页/会话导航是完全不同的 UI 范式，留作后续。
- 编辑器 tab 断开后自动跟随来源 SSH tab 重连换新 SFTP client——保存/重新加载失败时用户手动重开。
- 关闭编辑器 tab 后在来源 SSH tab 标题栏留"最近编辑过"提示——用户已确认不需要。
- 自动保存 / 定时保存。
- 新增 Settings 开关——这个功能没有可关闭的必要（不像 AI 工具那样有风险需要开关控制，纯粹是用户主动点出来的手动操作）。
- 多个编辑器 tab 同时打开同一个文件时的相互感知/锁定——mtime 冲突检测已经能兜住"内容不一致就拒绝保存"这个核心风险，不做更复杂的多编辑器协调。

## 影响文件

- `lib/models/tab_model.dart`：`AppTabKind` 新增 `editor`；`AppTab` 新增 `editorPath`/`editorSftp`/`editorLabel`/`editorMtime`/`editorDirty` 字段 + `AppTab.editor(...)` 工厂；`icon` getter 新增分支。
- `lib/views/file_editor_view.dart`（新文件）：`FileEditorView` widget + 保存/重新加载/mtime 冲突处理逻辑。
- `lib/views/sftp_view.dart`：文件行 `onDoubleTap`；新增 `_openInEditor`；`SftpView` 构造参数新增 `onOpenEditorTab` 回调。
- `lib/views/sftp_view_menus.dart`：右键菜单新增 "Edit" 项；`_SftpMenusMixin` 新增 `_openInEditor` 的 abstract 声明。
- `lib/app/main_views.dart`：`_buildPrimaryContent` 的 switch 新增 `AppTabKind.editor` 分支；`SftpView` 构造处接入 `onOpenEditorTab`；`_TabBar` 的 `onClose` 传参改为 `_requestCloseTab`。
- `lib/app/main_ssh.dart`（或就近的 SSH 相关 mixin 文件）：新增 `_openEditorTab`、`_requestCloseTab`。

## 测试计划

- 新增 widget/逻辑目前没有自动化测试基础设施可复用（`FileEditorView`、tab 关闭确认流程都是纯 UI 交互，项目里同类型的 chat-card widget 和 agent loop 也一贯没有自动化测试——沿用现状，不新增）。
- 手动验证：
  1. 双击一个远程文本文件 → 弹出编辑器 tab，内容正确，标题/路径显示正确。
  2. 右键菜单点 "Edit" → 同上效果。
  3. 双击一个 >4MB 的文件 → 不开 tab，报错文案清晰。
  4. 双击一个二进制文件 → 不开 tab，报错"不是文本文件"。
  5. 编辑内容 → 脏状态指示出现 → Cmd/Ctrl+S 保存 → 脏状态消失，远程文件确认已更新（另开一个终端 `cat` 验证）。
  6. 编辑后不保存直接点关闭按钮 → 弹确认框；分别测试"保存"/"不保存"/"取消"三个分支行为符合预期。
  7. 编辑期间从另一个终端/另一台机器改同一个文件 → 保存时命中 mtime 冲突弹窗 → 分别测试"强制覆盖"和"重新加载"两个分支。
  8. 编辑期间断开来源 SSH 连接（如拔网线/杀 SSH 进程）→ 保存报错，文案合理，不崩溃。
  9. 目录行 / 指向目录的符号链接双击 → 保持原有的"进入目录"行为，不触发编辑器。
