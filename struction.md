# SSTerm 代码架构

> 本文按仓库当前代码整理，描述现有结构和主要运行链路。SSTerm 是基于 Flutter 的跨平台终端应用，核心功能包括本地 Shell、SSH/SFTP、分屏与标签、远程文件编辑，以及内置 AI Agent。

## 1. 总体分层

```text
Flutter 平台入口（macOS / Windows / Linux / iOS / Android）
                 │
                 ▼
        lib/main.dart + lib/app/*
  应用启动、标签状态、会话编排、主界面
       │            │             │
       ▼            ▼             ▼
   widgets/       views/       dialogs/
  终端和面板    SSH/SFTP/设置    连接及确认交互
       │            │             │
       └────────────┴──────┬──────┘
                           ▼
                services/ + models/
       SSH、PTY、Agent、持久化、执行与安全策略
                 │                  │
                 ▼                  ▼
       packages/ 本地 Dart 包    native/ Rust 核心
       xterm / flutter_pty       PTY / terminal_core
```

界面主要由 Flutter 实现。终端显示、键鼠交互由 vendored `xterm` 提供；高频终端解析和屏幕状态由 Rust `terminal_core` 处理。PTY 进程生命周期由 `flutter_pty` 接口桥接，桌面平台默认使用 Rust `pty_core`。SSH/SFTP 协议由本地 vendored `dartssh2` 包提供。

## 2. 仓库目录

| 路径 | 职责 |
|---|---|
| `lib/main.dart` | Flutter 启动入口、应用根组件、主状态类与共享导入；声明 `app/` 的 Dart part 文件。 |
| `lib/app/` | 主窗口与移动端界面、标签栏、终端主页、SSH/本地 Shell 生命周期及页面构建逻辑。文件通过 `part of '../main.dart'` 共享库作用域。 |
| `lib/models/` | 标签、SSH 主机、连接结果、应用及终端设置、Agent 配置、MCP 配置、命令和传输任务等数据模型/存储模型。 |
| `lib/services/` | 可复用的业务和系统能力：SSH、PTY、SFTP 周边、Agent/LLM/MCP、技能、命令安全、密钥、日志、Shell 环境、文件操作等。 |
| `lib/io/` | PTY/SSH 输出进入终端的缓冲、转换、日志及输出指标。 |
| `lib/views/` | 主要功能页面：SSH 会话、SFTP 文件浏览、远程文件编辑和设置页。 |
| `lib/views/settings/` | 设置控制台及 Agent、命令、安全、Shell 集成等设置分区。 |
| `lib/widgets/` | 可组合 UI：终端 Surface、分屏、Agent 面板、传输面板、命令选择器、壁纸与玻璃效果。 |
| `lib/dialogs/` | SSH 连接/编辑、主机密钥和密码确认等对话框及表单部件。 |
| `lib/utils/` | 文件目录、文件描述符限制、差异、SSH 指纹和错误格式化等通用工具。 |
| `packages/xterm/` | 项目内维护的 Dart/Flutter 终端仿真器与绘制/输入组件。 |
| `packages/flutter_pty/` | 项目内维护的 Flutter PTY Dart 接口和原生绑定。 |
| `packages/dartssh2/` | 项目内维护的 SSH/SFTP Dart 实现。 |
| `native/pty_core/` | Rust PTY 核心，负责进程启动、读写、resize、退出观察和终止；Windows 使用 ConPTY。 |
| `native/terminal_core/` | Rust 终端热路径，负责输入字节解析、屏幕单元格和滚屏历史状态，并通过 C ABI 批量返回屏幕数据。 |
| `windows/conpty/` | Windows ConPTY sidecar 二进制及说明。 |
| `assets/` | 字体、图标、内置 Agent 技能和其他静态资源。 |
| `test/` | 按 app、models、services、views、widgets 等目录组织的 Dart 测试。 |
| `tool/` | 构建、测试或开发辅助脚本。 |
| `docs/` | 设计说明、实现计划、性能和兼容性文档。 |
| `android/`、`ios/`、`macos/`、`linux/`、`windows/`、`web/` | Flutter 各目标平台的 Runner、插件注册和平台工程文件。 |

## 3. 应用启动与主界面

启动入口在 `lib/main.dart` 的 `main()`：初始化 Flutter binding，设置文件描述符限制，注册并加载内置技能；桌面平台初始化窗口管理器后运行 `SsTermApp`。根组件使用深色 Material 主题并进入 `TerminalHome`。

主窗口的状态和页面目前由 `TerminalHome` / `_TerminalHomeState` 统筹。为了把大文件按职责拆开，`main.dart` 引入了 `lib/app/` 下的 part 文件：

- `main_local.dart`：本地 Shell/PTY 创建、环境构建与终端接线。
- `main_ssh.dart`：SSH 建连、会话配置、重连和 SSH 分屏。
- `main_chrome.dart`：标签栏、标签操作及窗口顶部控件。
- `main_desktop_home.dart`、`main_mobile.dart`、`main_mobile_nav.dart`、`main_mobile_connections.dart`：桌面和移动端主页/导航差异。
- `main_views.dart`：主界面各类 tab、终端和分屏内容的构建。

这些文件使用 Dart `part`，仍属于同一个 library：私有成员可以跨 part 访问，但模块之间没有独立的类型/依赖边界。`AppTab` 位于独立的 `models/tab_model.dart`，承载标签类型和当前会话资源。

## 4. 关键模块

### 标签与会话状态

`AppTab` 表示一个标签，可为本地终端、SSH 终端、连接中/连接错误、设置或文件编辑器。终端标签持有 pane 0/1 的终端、PTY 或 SSH session、输出管道、终端核心桥接、SFTP 与传输等资源；标签负责清理其拥有的资源。编辑器标签会借用来源 SSH 标签的 SFTP client，不负责关闭该 client。

`TerminalHome` 管理标签列表和选中态，并编排创建/关闭 tab、连接、重连、分屏和布局。它是目前跨功能的主要协调点；业务服务与 UI widget/view 提供具体能力。

### 终端数据路径

```text
本地进程 / SSH channel
        │ bytes
        ▼
    OutputPipe（缓冲、节流、日志/转换）
        │
        ▼
 RustTerminalBridge → RustTerminalCore（解析和屏幕状态）
        │ packed screen / history / modes
        ▼
 xterm Terminal 状态 → TerminalSurface（绘制、选择、键鼠输入）
```

PTY 和 SSH 的输出都会进入终端处理路径。`terminal_core` 的 C ABI 按批次接收 PTY 数据；Flutter 侧桥接器同步屏幕、滚屏历史和模式到 xterm。Flutter/xterm 仍负责绘制、选择和输入编码。Dart 终端解析器可作为诊断路径选择，具体开关见 `native/terminal_core/README.md`。

### 本地 Shell / PTY

`LocalShellDiscovery` 发现可用 Shell；环境构建与登录 Shell 包装分别由 `login_shell_environment.dart`、`local_shell_wrapper.dart`、平台相关 wrapper 等服务支持。`LocalPtyService` 和 `flutter_pty` 创建进程会话，`pty_core` 在原生端管理 PTY/ConPTY 生命周期。OSC 7 工作目录报告经 `RemoteCwdParser` 等逻辑更新 tab 路径上下文。

### SSH、SFTP 与文件编辑

`connect_dialog.dart` 收集连接配置并交由 `ssh_connection.dart` 建立连接。连接结果包含会话所需资源；主状态将它们装配到 SSH tab，并处理会话输入输出、Keepalive、断线重连和端口转发。`host_key_verifier.dart`、`trusted_host_keys.dart` 和相关模型负责主机密钥校验。

`SftpView` 提供远程目录浏览和文件操作，下载/传输任务与队列由服务、模型和 `TransferPanel` 配合。远程文件可打开为编辑器 tab，由 `FileEditorView` 编辑，再通过文件编辑服务写回 SFTP。

### AI Agent

Agent UI 在 `widgets/ai_assistant_panel*`，应用配置和提供方配置在 `models/agent_config.dart`。`llm_service*` 负责模型提供方和流式交互；`agent_tool_registry.dart`、`agent_provider_tools.dart`、`agent_tool_contract.dart`、`mcp_service.dart` 组织可用工具和 MCP；`background_command_executor.dart` 执行 Agent 命令。命令风险/确认策略、文件写入提案、上下文预算、会话注册和持久化由独立服务协作。`assets/skills/`、`bundled_skills.dart` 和 `skill_service.dart` 提供技能目录。

### 配置与持久化

`AppConfig` 汇总应用配置，并与主界面初始化和设置页面协作。`TerminalSettings`、主题 preset/codec 维护终端外观设置；SSH 主机、命令、已知主机、Agent/MCP、技能等数据分别有模型/存储实现。凭据经 `credential_storage.dart`、`api_key_storage.dart` 及加密辅助服务接入平台安全存储。

## 5. 依赖方向与边界

当前主要依赖关系可概括为：

1. `app/` 编排 `models/`、`services/`、`views/`、`widgets/` 与 `dialogs/`。
2. `views/` 和 `widgets/` 通过回调、模型或服务完成交互，不负责底层 PTY/SSH 原生实现。
3. `services/` 封装外部协议、执行策略、持久化和原生桥接；`models/` 表达配置/状态数据。
4. `packages/` 是本地 Dart 包；`native/` 提供 Rust 能力并通过 FFI/C ABI 与 Dart 接口连接。
5. Flutter 平台目录负责 Runner、插件与平台构建集成，不承载主要跨平台业务逻辑。

需要注意：上述目录表达的是当前代码的组织意图，不等同于严格分层架构。`main.dart` 与 `app/` part 共享 library 和私有状态，主状态依然承担多个功能域的协调；`AppTab` 也保有运行期资源引用。这些是理解代码时的重要入口和边界事实。

## 6. 常用阅读入口

| 想了解 | 建议从这里开始 |
|---|---|
| 应用启动和整体编排 | `lib/main.dart`、`lib/app/main_desktop_home.dart` |
| 标签资源与生命周期 | `lib/models/tab_model.dart` |
| 本地 Shell 启动 | `lib/app/main_local.dart`、`lib/services/local_pty_service.dart` |
| SSH 建连和重连 | `lib/app/main_ssh.dart`、`lib/services/ssh_connection.dart` |
| 终端输出处理 | `lib/io/output_pipe.dart`、`lib/services/rust_terminal_bridge.dart`、`native/terminal_core/README.md` |
| 终端绘制与输入 | `lib/widgets/terminal_surface.dart`、`packages/xterm/lib/src/terminal_view.dart` |
| SFTP 与编辑器 | `lib/views/sftp_view.dart`、`lib/views/file_editor_view.dart` |
| Agent 工具与执行 | `lib/widgets/ai_assistant_panel.dart`、`lib/services/agent_tool_registry.dart`、`lib/services/background_command_executor.dart` |
| 设置与配置 | `lib/views/settings/settings_sheet.dart`、`lib/models/app_config.dart` |
| Rust PTY 生命周期 | `native/pty_core/README.md`、`packages/flutter_pty/` |

