# SSTerm — Modularization SPEC

Generated: 2026-05-27  
Scope: files currently exceeding 1000 lines

---

## 超1000行文件现状

| 文件 | 当前行数 | 角色 |
|---|---|---|
| `lib/main.dart` | 2642 | App 入口 + 全部状态逻辑 + 所有 UI 组件 |
| `lib/dialogs/connect_dialog.dart` | 1103 | SSH 连接对话框 + 子对话框 + 通用输入组件 |
| `packages/xterm/lib/src/core/escape/parser.dart` | 1176 | VT/ANSI 转义序列解析器 |

---

## 一、lib/main.dart — 当前架构

### 顶层导入
- `dartssh2`, `flutter/material`, `xterm`, `flutter_pty`
- 本地: `connect_dialog`, `app_config`, `saved_hosts_store`, `ssh_host`, `host_key_verifier`, `local_shell_discovery`, `port_forward_service`, `remote_cwd_parser`, `remote_home`, `session_logger`, `ssh_connection`, `wallpaper_storage`, `fd_limit`, `settings_sheet`, `cmd_picker_button`, `frosted_glass`, `split_view`, `terminal_surface`, `transfer_task`, `ssh_session_view`, `transfer_panel`, `wallpaper_background`

### 类/函数清单

#### `_OutputPipe` (L66–120) — I/O 桥接
- **功能**: 将 `Stream<List<int>>` 数据缓冲后写入 `Terminal`，支持 transform 和 session log
- **输入**: `Terminal`, 可选 `transform: List<int> Function(List<int>)`, `SessionLogger?`
- **输出**: 调用 `terminal.write()`; 写入 `SessionLogger`
- **关键字段**: `_buf BytesBuilder`, `_kMaxBytesPerWrite=65536`, `_kFlushInterval=16ms`
- **方法**: `bind(stream)`, `_onChunk()`, `_flush()`, `dispose()`

#### `_TabKind` (L123) — Tab 类型枚举
- `local`, `ssh`, `sshConnecting`, `sshError`, `settings`

#### `_Tab` (L125–282) — Tab 数据模型 + 生命周期
- **功能**: 单 Tab 的全部状态（local/SSH/分屏）
- **输入**: `kind`, `title`, `localShell`, `terminal`, `sshProfile` 等
- **输出**: 自管理资源 dispose
- **关键方法**:
  - `clearSplit()` — 关闭 pane 1
  - `syncRemotePathToActivePane()` — 同步 SFTP 路径到活跃 pane
  - `retainPane1()` — pane 0 退出后将 pane 1 提升为 pane 0
  - `dispose()` — 释放全部资源
- **引用**: `Terminal`, `Pty`, `SSHClient`, `SSHSession`, `SftpClient`, `PortForwardService`, `TransferManager`, `_OutputPipe`

#### `TerminalHome` / `_TerminalHomeState` (L285–1870) — **核心状态类 (1585 行)**

包含 **6 个职责域**（目前全部塞在一个 State 里）：

**1. 本地 PTY 管理 (L363–993)**
- `_createTerminal()` — 创建 Terminal 实例
- `_environmentForLocalShell()` — 构建 shell 环境变量
- `_wslEnvironment()` — WSL 专用环境
- `_gitBashEnvironment()` — Git Bash 专用环境
- `_spawnLocalPty(tab, terminal, shell, columns, rows, ...)` — 启动本地 PTY
- `_wireDeferredLocalPty(...)` — 在首次 resize 时延迟启动 PTY
- `_interactiveLocalShellWrapperCommand()` — 生成 zsh/bash 包装脚本（inline heredoc）

**2. SSH 连接管理 (L1020–1465)**
- `_showConnectDialog()` → `showConnectDialog()` → 返回 `SshHost?`
- `_openConnectingTab(profile)` — 插入 sshConnecting 占位 tab
- `_runConnectionForTab(tab)` — 后台执行 SSH 握手（`connectSshHost`）
- `_materializeSshTab(tab, ConnectResult)` — 握手完成后填充 tab
- `_reconnectTab(tab)` — 自动重连
- `_restartSshShell(tab, terminal, pane)` — 重新打开 SSH shell 会话
- `_handleSshSessionDone(tab, terminal)` — 会话结束处理（含自动重连逻辑）
- `_wireSshSession(tab, session, terminal, pipe)` — 绑定输入/resize 回调
- `_friendlyConnectError(e)` — 错误消息人性化

**3. 分屏管理 (L1263–1352)**
- `_splitCurrentTab(axis)` — 分屏入口
- `_openSshSplitPane(tab, axis)` — SSH 分屏（新建 session）
- `_openLocalSplitPane(tab, axis)` — 本地分屏（新建 PTY）
- `_collapseSplitAfterExit(tab, paneIndex)` — 分屏 pane 退出后合并
- `_rewirePane0AfterCollapse(tab)` — 合并后重新绑定 pane 0 I/O

**4. Tab 管理 (L1467–1520)**
- `_closeTab(i)`, `_selectTab(i)`, `_activateTab(i)`, `_openSettings()`
- `_syncAllTerminals()`, `_insertCommand(cmd)`

**5. Build 方法 (L1522–1869)**
- `_buildChrome()` — 顶层 Scaffold
- `_buildBody()` — IndexedStack
- `_buildTabBody(tab)` — 含分屏/SFTP 叠加
- `_buildPrimaryContent(tab)` — switch 路由
- `_buildTerminalView(terminal, viewKey)` — 单个终端 surface
- `_buildConnectingBody(tab)` — 连接中指示器
- `_buildErrorBody(tab)` — 连接失败提示

**6. 辅助**
- `_sshOutputTransform(tab, pane, parser)` — 包装 OSC7 CWD 解析
- `_noteRemoteCwd(tab, pane, cwd)` — 更新 remotePath
- `_activateSshPaneForSftp(tab, pane)` — SFTP 跟随活跃 pane
- `_paneIndexOf(tab, terminal)` — terminal → pane index 反查

#### Tab bar 组件 (L1872–2642)
- `_TabBar` (L1873–2039) — 标签栏整体，含 LayoutBuilder 响应式排列
- `_SftpButton` (L2042–2067) — SFTP 面板切换按钮
- `_TransferButton` (L2070–2146) — 传输队列按钮（带 badge）
- `_SplitButton` (L2149–2248) — 分屏菜单按钮
- `_TabChip` / `_TabChipState` (L2251–2348) — 单个 Tab 标签
- `_CloseBtn` / `_CloseBtnState` (L2350–2388) — Tab 关闭按钮
- `_PlusMenu` (L2391–2634) — 新建 Tab 下拉菜单（shells + saved hosts + SSH）
- `_OpenSettingsIntent`, `_CloseTabIntent` (L2636–2642) — 快捷键 Intent

---

## 二、lib/dialogs/connect_dialog.dart — 当前架构

### 顶层导入
- `flutter/material`, `models/port_forward_rule`, `models/ssh_host`, `models/connect_result`

### 类/函数清单

#### `showConnectDialog` / `showEditHostDialog` (L14–34) — 对话框入口
- **输入**: `BuildContext`, `SshHost? initialHost`, `bool editOnly`
- **输出**: `Future<SshHost?>` — 用户填写的连接配置

#### `_ConnectDialog` / `_ConnectDialogState` (L48–450) — 主对话框
- **功能**: 填写 SSH 连接信息（基本信息 + 跳板机 + 端口转发 + 高级选项）
- **关键问题**: `_save()` (L169–211) 和 `_create()` (L216–258) 几乎完全重复（~40 行重复代码）
- **方法**:
  - `_applyHost(h)` — 从 SshHost 填充表单
  - `_buildJumpHost()` → `SshHost?` — 构建跳板机配置
  - `_save()` / `_create()` — 表单验证 + pop(SshHost) **（重复代码）**
  - `_buildScrollable()` — 主布局
  - `_buildJumpFields()` — 跳板机字段布局
  - `_buildAuthToggle()` — 密码/密钥切换 SegmentedButton

#### `_Section` (L452–532) — 可折叠/可启用的 Section 容器
- **输入**: `title`, `enabled`, `onToggle`, `child`
- **功能**: 带开关的可展开容器，供跳板机使用

#### `_ForwardSection` (L535–657) — 端口转发规则列表
- **输入**: `List<PortForwardRule> rules`, `onChanged`
- **功能**: 展示 + 增删转发规则
- **引用**: `_RuleRow`, `_AddRuleDialog`

#### `_RuleRow` (L659–703) — 单条转发规则行
- **输入**: `PortForwardRule`, `onDelete`, `onToggle`

#### `_AddRuleDialog` / `_AddRuleDialogState` (L706–881) — 添加转发规则子对话框
- **输入**: 无
- **输出**: `PortForwardRule?`
- **引用**: `_Field`, `_inputDecoration`

#### `_AdvancedSection` (L883–1027) — 高级选项折叠区
- **输入**: `keepaliveInterval`, `autoReconnect`, `sessionLog` + 对应回调
- **功能**: keepalive 下拉 + 自动重连开关 + 会话日志开关

#### `_Field` (L1051–1103) — 通用文本输入框组件
- **输入**: `label`, `ctrl`, `hint?`, `obscure`, `inputType?`
- **注意**: 与 `_inputDecoration` (L1030–1049) 有重复的边框样式代码

---

## 三、packages/xterm/lib/src/core/escape/parser.dart — 当前架构

### 顶层导入
- `xterm/src/core/color`, `mouse/mode`, `escape/handler`, `utils/ascii`, `utils/byte_consumer`, `utils/char_code`, `utils/lookup_table`

### 类/函数清单

#### `EscapeParser` (L15–1148) — 主解析器类
- **设计目标**: 零内存分配、无内部状态（同输入→同输出）
- **输入**: `String chunk` via `write()`
- **输出**: 回调 `EscapeHandler` 接口方法
- **内部依赖**: `ByteConsumer _queue`, `_Csi _csi` (可变单例), `List<String> _osc`

**调度层**:
- `write(chunk)` — 入口，调用 `_process()`
- `_process()` — 主循环，dispatch ESC 或普通字符
- `_processChar(char)` — SBC（单字节控制符）dispatch via `_sbcHandlers`
- `_processEscape()` — ESC 序列 dispatch via `_escHandlers`
- `_escHandleCSI()` — `ESC [` → 解析 CSI 并 dispatch

**SBC 处理器映射** (L82–92): BEL, BS, TAB, LF, CR, SI, SO

**ESC 简单处理器** (L114–190): SaveCursor, RestoreCursor, Index, NextLine, TabSet, ReverseIndex, DesignateCharset0/1, AppKeypadMode

**CSI 解析** (L213–268):
- `_consumeCsi()` — 解析 CSI 参数到 `_csi` 单例（prefix + params[] + finalByte）

**CSI 处理器映射** (L270–300): 30+ 个 handler 方法

**CSI 处理器** (L316–942):
- `_csiHandleRepeatPreviousCharacter()`, `_csiHandleSendDeviceAttributes()`
- `_csiHandleLinePositionAbsolute()`, `_csiHandleCursorPosition()`
- `_csiHandelClearTabStop()`, `_csiHandleMode()`
- `_csiHandleSgr()` (L410–620) **~210 行** — SGR 属性设置（颜色、字体样式）
- `_csiHandleDeviceStatusReport()`, `_csiHandleSetMargins()`
- `_csiWindowManipulation()` (L659–710) — 窗口操作
- `_csiHandleCursor{Up,Down,Forward,Backward,NextLine,PrecedingLine,HorizontalAbsolute}()`
- `_csiHandleErase{Display,Line,Characters}()`
- `_csiHandleInsert{Lines,BlankCharacters}()`, `_csiHandleDelete{Lines}()`, `_csiHandleDelete()`
- `_csiHandleScroll{Up,Down}()`

**模式处理器** (L944–1067):
- `_setMode(mode, enabled)` — SM/RM (insert, line feed)
- `_setDecMode(mode, enabled)` (L955–1067) **~113 行** — DEC 私有模式（光标、鼠标、缓冲区切换等）

**OSC 处理** (L1069–1147):
- `_escHandleOSC()` — dispatch OSC 0/1/2 和私有扩展
- `_consumeOsc()` — 解析 OSC 参数列表（BEL 或 ST 终止）

**辅助数据结构**:
- `_Csi` (L1150–1168) — 可变单例，存储已解析 CSI 的 prefix/params/finalByte
- `_EscHandler`, `_SbcHandler`, `_CsiHandler` typedef

---

## 重构目标

### main.dart → 拆分为 7 个文件

| 目标文件 | 内容 | 预估行数 |
|---|---|---|
| `lib/main.dart` | `main()` + `SsTermApp` | ~45 |
| `lib/models/tab_model.dart` | `_TabKind`, `_Tab` (数据+生命周期) | ~160 |
| `lib/io/output_pipe.dart` | `_OutputPipe` | ~65 |
| `lib/services/local_pty_service.dart` | 本地 PTY 启动、环境变量、shell 包装脚本 | ~280 |
| `lib/services/ssh_session_service.dart` | SSH 连接、重连、materialize、会话管理 | ~380 |
| `lib/screens/terminal_home.dart` | `TerminalHome` + `_TerminalHomeState`（纯编排） | ~450 |
| `lib/widgets/tab_bar_widget.dart` | `_TabBar`, `_TabChip`, `_CloseBtn`, `_PlusMenu`, 工具栏按钮 | ~550 |

### connect_dialog.dart → 拆分为 3 个文件

| 目标文件 | 内容 | 预估行数 |
|---|---|---|
| `lib/dialogs/connect_dialog.dart` | `showConnectDialog`, `showEditHostDialog`, `_ConnectDialog`（合并 `_save`/`_create` 重复代码） | ~320 |
| `lib/dialogs/connect_sections.dart` | `_Section`, `_ForwardSection`, `_RuleRow`, `_AdvancedSection` | ~430 |
| `lib/dialogs/form_widgets.dart` | `_AddRuleDialog`, `_Field`, `_inputDecoration` | ~230 |

**消除重复**: `_save()` 和 `_create()` 合并为一个 `_buildResult()` 私有方法，避免 ~40 行重复验证+构建逻辑。

### parser.dart → 拆分为 3 个文件（使用 Dart mixin）

| 目标文件 | 内容 | 预估行数 |
|---|---|---|
| `packages/xterm/lib/src/core/escape/parser.dart` | `EscapeParser` 主体（调度层 + CSI 解析 + OSC + 简单 ESC） | ~500 |
| `packages/xterm/lib/src/core/escape/sgr_handler.dart` | `_SgrHandlerMixin`（`_csiHandleSgr` + 全部颜色/样式 case） | ~220 |
| `packages/xterm/lib/src/core/escape/dec_mode_handler.dart` | `_DecModeHandlerMixin`（`_setDecMode` + `_setMode`） | ~140 |

**约束**: `EscapeParser` 使用 `with _SgrHandlerMixin, _DecModeHandlerMixin`，三个 mixin 共享 `_csi`/`_queue` 通过 abstract getter 访问，保持零分配设计。

---

## 重复代码清单（重构时消除）

1. **`connect_dialog.dart` L169–258**: `_save()` 和 `_create()` 几乎完全相同，差异仅在 `user` nullable → 合并为 `_buildResult({bool editMode})`
2. **`connect_dialog.dart` `_Field` vs `_inputDecoration`**: 两处 `OutlineInputBorder` + `fillColor` 样式完全相同 → 统一到 `_inputDecoration`
3. **`main.dart` `_materializeSshTab` 和 `_reconnectTab`**: 端口转发启动、keepalive timer 启动逻辑各写一遍 → 提取 `_setupSshPostConnect(tab, client, profile)` 私有方法
4. **`main.dart` `_openSshSplitPane` 和 `_restartSshShell`**: SSH session 启动 + pipe 绑定流程重复 → 提取 `_launchSshShell(client, terminal, ...)→ (session, pipe)` 方法
