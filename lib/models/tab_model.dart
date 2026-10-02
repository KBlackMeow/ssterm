import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../io/output_pipe.dart';
import '../services/local_shell_discovery.dart';
import '../services/port_forward_service.dart';
import '../services/rust_terminal_core.dart';
import '../services/rust_terminal_bridge.dart';
import '../views/file_editor_view.dart';
import 'ssh_host.dart';
import 'transfer_task.dart';

/// 标签内容状态机的种类，决定主视图展示终端、SSH 连接过程、错误页、
/// 设置页或远程文件编辑器。切换类型时需同步建立或释放对应资源。
enum AppTabKind { local, ssh, sshConnecting, sshError, settings, editor }

/// Best-effort SSH teardown; must not throw when the transport is already dead.
void safeSshTeardown(void Function() close) {
  try {
    close();
  } on SSHStateError {
    // Transport or channel already closed (e.g. VPN drop).
  } catch (_) {}
}

/// 单个标签的运行期模型，持有终端 pane、PTY/SSH/SFTP、输出管道、
/// 分屏和传输等状态，并负责释放自己拥有的资源。编辑器借用来源 SSH
/// 标签的 SFTP client，因此编辑器标签不能关闭该 client。
class AppTab {
  /// 当前内容类型；页面构建逻辑据此选择终端、设置、错误或编辑器界面。
  AppTabKind kind;
  /// 标签栏显示文本；SSH/本地连接可更新它，编辑器通常使用文件路径。
  String title;
  /// 本地标签启动时使用的 Shell 选项；SSH 和非终端标签为空。
  LocalShellOption? localShell;

  /// SSH 建连失败时显示的错误内容；重试前清空，连接成功后不再使用。
  String? connectionError;

  // ── Pane 0 ──────────────────────────────────────────────────────────────────
  /// 主 pane 的 xterm 状态，接收 Rust 终端核心同步后的屏幕数据。
  Terminal? terminal;
  /// 主 pane 的本地 PTY 进程句柄；SSH pane 中为空。
  Pty? pty;
  /// 主 pane 持有的 Rust 终端解析/屏幕核心实例。
  RustTerminalCore? rustTerminalCore;
  /// 将主 pane 输出、Rust 核心状态和 xterm 画面连接起来的桥接器。
  RustTerminalBridge? rustTerminalBridge;
  /// 主 pane 的 SSH 客户端；关闭时由本标签释放。
  SSHClient? sshClient;
  /// 经由跳板连接时持有的中间 SSH 客户端；直连时为空。
  SSHClient? jumpClient;
  /// 主 pane 的交互 Shell 通道；本地 PTY 标签中为空。
  SSHSession? sshSession;
  /// 主 pane 的 SFTP 通道；不支持/未建立文件传输时为空。
  SftpClient? sftp;
  /// SFTP 面板当前目录的可监听值。
  ValueNotifier<String>? remotePath;
  /// pane 0 最近一次 OSC 7 上报的远程工作目录。
  String? remoteCwdPane0;
  /// pane 1 最近一次 OSC 7 上报的远程工作目录。
  String? remoteCwdPane1;

  /// True after pane 0 has emitted an OSC-7 cwd report. Kept separately from
  /// [remoteCwdPane0] because `/` is both a valid cwd and the initial fallback.
  bool remoteCwdPane0Observed = false;
  /// 当前被视为活动 SSH pane 的索引，0 为主 pane，1 为分屏 pane。
  int activeSshPane = 0;
  /// 本地 Shell 最近上报的工作目录，供新建命令或面板使用。
  ValueNotifier<String>? localPath;
  /// 主 pane 的输出缓冲、转换和日志管道。
  OutputPipe? pipe;
  /// 绑定主 pane 终端视图的 key，用于读取或控制可见视图状态。
  final terminalViewKey = GlobalKey<TerminalViewState>();

  /// 当前 SSH 标签的端口转发资源管理器。
  PortForwardService? forwardService;
  /// 当前 SSH 连接使用的档案，供重连和设置同步使用。
  SshHost? sshProfile;
  /// 用户主动断开时置为 true，防止自动重连逻辑重新连接。
  bool manuallyDisconnected = false;
  /// 定期探测 SSH 连接健康状态的计时器。
  Timer? keepaliveTimer;

  /// True while a keepalive `client.run('true')` is still pending.  Used to
  /// suppress stacking on slow links: without the guard a 30-second periodic
  /// keepalive against a link with > 30s RTT to `true` would queue an
  /// unbounded backlog of probes and DoS the SSH channel.
  bool keepaliveInFlight = false;

  /// Number of consecutive reconnect attempts since the last successful
  /// connection.  Reset to 0 on success.  Drives exponential backoff and
  /// the hard retry ceiling in `_reconnectTab`.
  int reconnectAttempt = 0;
  /// 当前标签是否显示 SFTP 面板。
  bool sftpPanelVisible = false;

  /// 当前标签是否显示 Agent 面板。
  bool agentPanelVisible = false;
  /// Agent 后台命令的工作目录；成功命令返回的新 cwd 会更新此值。
  String? agentCwd;
  /// 当前标签的 Agent 命令是否已被取消；取消后不再采纳迟到的 cwd 结果。
  bool _agentExecutionCancelled = false;

  bool get isAgentExecutionCancelled => _agentExecutionCancelled;

  void applyAgentCommandResult(CommandResult result) {
    final cwd = result.effectiveCwd;
    if (_agentExecutionCancelled ||
        result.cancelled ||
        result.exitCode != 0 ||
        cwd == null ||
        cwd.isEmpty) {
      return;
    }
    agentCwd = cwd;
  }

  /// 当前 SSH 标签的上传/下载队列；本地或轻量标签中为空。
  TransferManager? transferManager;

  // ── Editor-tab-only state (AppTabKind.editor) ────────────────────────────
  // Populated only when `kind == AppTabKind.editor`. Kept as a separate,
  // clearly-labelled group rather than mixed into the pane-0 fields above
  // because an editor tab has no terminal/PTY/split state at all — it's a
  // lightweight tab like `settings`, not a terminal session.

  /// Remote absolute path this tab is editing.
  String? editorPath;

  /// SFTP client BORROWED from the source SSH tab at open time — this tab
  /// does not own it and must never close it. If the source SSH tab
  /// reconnects (getting a new client) or disconnects (closing this one),
  /// this reference goes stale; `FileEditorView` surfaces that as an
  /// ordinary save error rather than trying to follow the reconnect.
  SftpClient? editorSftp;

  /// Display label for the source SSH tab, e.g. "ssh: prod-db" — shown in
  /// error messages so the user knows which connection is involved.
  String? editorLabel;

  /// mtime captured at open time (or the most recent successful
  /// save/reload) — passed to `FileSystemAdapter.commit` as the
  /// concurrency token.
  DateTime? editorMtime;

  /// Content read by the SFTP panel at open time. Consumed EXACTLY ONCE
  /// by `FileEditorView.initState` (via `_buildPrimaryContent`'s
  /// construction in `main_views.dart`, Task 4) to seed its
  /// `TextEditingController` — `_buildPrimaryContent` runs on every
  /// rebuild, but `initState` only runs once per widget lifetime, so
  /// after the first build this field is stale/unused and the
  /// widget's own controller is the sole source of truth.
  String? editorInitialContent;

  /// True while the editor's buffer differs from the last-saved/loaded
  /// content. Written by `FileEditorView`, read by the tab-close
  /// confirmation gate — kept on `AppTab` (not buried inside the widget's
  /// State) so the close handler can check it even before/without
  /// querying the widget itself.
  final ValueNotifier<bool> editorDirty = ValueNotifier(false);

  /// Reach-into-the-widget handle, same pattern as [terminalViewKey]
  /// below — lets the tab-close confirmation flow (which runs outside
  /// `FileEditorView`'s own widget tree) call `.save()` on the live
  /// editor state when the user chooses "Save" from the close dialog.
  final editorViewKey = GlobalKey<FileEditorViewState>();

  // ── Pane 1 ──────────────────────────────────────────────────────────────────
  /// 分屏 pane 的 xterm 状态；为空表示当前没有第二个 pane。
  Terminal? splitTerminal;
  /// 分屏 pane 的 SSH Shell 通道，本地分屏时为空。
  SSHSession? splitSshSession;
  /// 分屏 pane 的本地 PTY 句柄，SSH 分屏时为空。
  Pty? splitPty;
  /// 分屏 pane 的 Rust 终端解析和屏幕状态。
  RustTerminalCore? splitRustTerminalCore;
  /// 分屏 pane 的 Rust 核心到 xterm 的状态桥接器。
  RustTerminalBridge? splitRustTerminalBridge;
  /// 分屏 pane 的输出缓冲、转换和日志管道。
  OutputPipe? splitPipe;
  /// 绑定分屏 pane 终端视图的 key。
  final splitViewKey = GlobalKey<TerminalViewState>();
  /// 分屏方向；horizontal 表示左右排列，vertical 表示上下排列。
  Axis splitAxis = Axis.horizontal;

  /// 主 pane 的键盘输入和选择控制器。
  final terminalController = TerminalController();
  /// 分屏 pane 的键盘输入和选择控制器。
  final splitTerminalController = TerminalController();

  /// 主 pane 会话是否已结束，用于视图显示退出状态并防止重复清理。
  bool primarySessionEnded = false;
  /// 分屏 pane 会话是否已结束。
  bool splitSessionEnded = false;

  bool get isSplit => splitTerminal != null;

  // ── Private constructor + named factories ────────────────────────────────────

  AppTab._({
    required this.kind,
    required this.title,
    this.localShell,
    this.sshProfile,
  });

  factory AppTab.settings() =>
      AppTab._(kind: AppTabKind.settings, title: 'Settings');

  factory AppTab.connecting(SshHost profile) => AppTab._(
    kind: AppTabKind.sshConnecting,
    title: profile.alias,
    sshProfile: profile,
  );

  /// Convenience factory used in tests and local-tab creation.
  factory AppTab.local({required String title, LocalShellOption? shell}) =>
      AppTab._(kind: AppTabKind.local, title: title, localShell: shell);

  /// Convenience factory used in tests and SSH-tab creation.
  factory AppTab.ssh({required String title, SshHost? profile}) =>
      AppTab._(kind: AppTabKind.ssh, title: title, sshProfile: profile);

  /// Convenience factory used in tests and when the user opens a remote
  /// file from the SFTP panel. [title] is the path itself — editor tabs
  /// don't have a separate short display name, the full path IS the
  /// identity of the tab.
  factory AppTab.editor({
    required String path,
    required SftpClient sftp,
    required String label,
    required DateTime? mtime,
    required String initialContent,
  }) => AppTab._(kind: AppTabKind.editor, title: path)
    ..editorPath = path
    ..editorSftp = sftp
    ..editorLabel = label
    ..editorMtime = mtime
    ..editorInitialContent = initialContent;

  // ── Pane lifecycle ───────────────────────────────────────────────────────────

  /// Ends pane 1 and returns to single-pane mode.
  void clearSplit() {
    splitPipe?.dispose();
    splitSshSession?.close();
    splitPty?.kill();
    splitPty?.dispose();
    splitRustTerminalBridge?.close();
    splitRustTerminalCore?.close();
    splitTerminal = null;
    splitSshSession = null;
    splitPty = null;
    splitRustTerminalBridge = null;
    splitRustTerminalCore = null;
    splitPipe = null;
    splitSessionEnded = false;
    remoteCwdPane1 = null;
    if (activeSshPane == 1) activeSshPane = 0;
    syncRemotePathToActivePane();
  }

  void syncRemotePathToActivePane() {
    if (manuallyDisconnected) return;
    final cwd = activeSshPane == 1 && isSplit
        ? (remoteCwdPane1 ?? remoteCwdPane0)
        : remoteCwdPane0;
    if (cwd != null && cwd.isNotEmpty) {
      _applyActiveRemoteCwd(cwd);
    }
  }

  /// Records an OSC-7 cwd report from an SSH terminal pane. The active pane
  /// is the shared location context: SFTP, Agent commands, and the Agent's
  /// initial session context must all agree on it.
  void noteRemoteCwd({required int pane, required String cwd}) {
    if (manuallyDisconnected || cwd.isEmpty) return;
    // After retainPane1 the surviving shell still reports as pane 1; map it
    // to pane 0 storage after the split has collapsed.
    final storagePane = !isSplit && pane == 1 ? 0 : pane;
    if (storagePane == 0) {
      remoteCwdPane0 = cwd;
      remoteCwdPane0Observed = true;
    } else {
      remoteCwdPane1 = cwd;
    }
    if (!isSplit || activeSshPane == storagePane) {
      _applyActiveRemoteCwd(cwd);
    }
  }

  void _applyActiveRemoteCwd(String cwd) {
    remotePath?.value = cwd;
    agentCwd = cwd;
  }

  /// Pane 0 exited while split — move pane 1 into the single-pane slot.
  void retainPane1() {
    if (splitTerminal == null) return;

    remoteCwdPane0 = remoteCwdPane1 ?? remoteCwdPane0;
    remoteCwdPane1 = null;
    activeSshPane = 0;
    syncRemotePathToActivePane();

    pipe?.dispose();
    pipe = null;
    pty?.kill();
    pty?.dispose();
    rustTerminalBridge?.close();
    rustTerminalBridge = null;
    rustTerminalCore?.close();
    rustTerminalCore = null;
    pty = null;
    sshSession?.close();
    sshSession = null;

    terminal = splitTerminal;
    splitTerminal = null;
    pty = splitPty;
    splitPty = null;
    rustTerminalBridge = splitRustTerminalBridge;
    splitRustTerminalBridge = null;
    rustTerminalCore = splitRustTerminalCore;
    splitRustTerminalCore = null;
    sshSession = splitSshSession;
    splitSshSession = null;
    pipe = splitPipe;
    splitPipe = null;
    primarySessionEnded = false;
    splitSessionEnded = false;
  }

  /// Closes SSH objects whose transport can no longer accept new sessions
  /// (e.g. after VPN switch). Keeps [sshProfile] so a full reconnect can run.
  void clearDeadSshTransport() {
    keepaliveTimer?.cancel();
    keepaliveTimer = null;
    forwardService?.stopAll();
    forwardService = null;

    // Stop resize callbacks from touching a dead session channel.
    terminal?.onResize = null;
    splitTerminal?.onResize = null;

    pipe?.dispose();
    pipe = null;
    splitPipe?.dispose();
    splitPipe = null;
    splitRustTerminalBridge?.close();
    splitRustTerminalBridge = null;
    splitRustTerminalCore?.close();
    splitRustTerminalCore = null;

    rustTerminalBridge?.close();
    rustTerminalBridge = null;
    rustTerminalCore?.close();
    rustTerminalCore = null;

    final splitSession = splitSshSession;
    if (splitSession != null) safeSshTeardown(() => splitSession.close());
    splitSshSession = null;

    final session = sshSession;
    if (session != null) safeSshTeardown(() => session.close());
    sshSession = null;

    final sftpClient = sftp;
    if (sftpClient != null) safeSshTeardown(() => sftpClient.close());
    sftp = null;

    final client = sshClient;
    if (client != null) safeSshTeardown(() => client.close());
    sshClient = null;

    final jump = jumpClient;
    if (jump != null) safeSshTeardown(() => jump.close());
    jumpClient = null;
  }

  /// Detach live I/O callbacks before the tab widget is removed from the tree.
  /// PTY/SSH teardown still happens in [dispose], which is deferred so the
  /// surviving tab can reclaim keyboard focus first (critical on Windows).
  void prepareForRemoval() {
    manuallyDisconnected = true;
    _agentExecutionCancelled = true;
    keepaliveTimer?.cancel();
    keepaliveTimer = null;
    terminal?.onOutput = null;
    terminal?.onResize = null;
    splitTerminal?.onOutput = null;
    splitTerminal?.onResize = null;
    pipe?.dispose();
    pipe = null;
    splitPipe?.dispose();
    splitPipe = null;
  }

  void dispose() {
    // NOTE: editorViewKey needs no explicit cleanup here — a GlobalKey
    // has no disposable resource of its own. editorDirty IS disposed,
    // just further down alongside the other ValueNotifier/Controller
    // .dispose() calls, not here at the top. editorSftp is a BORROWED
    // reference (see its doc comment above) and must NOT be closed
    // here — that would tear down the source SSH tab's live connection
    // out from under it.
    manuallyDisconnected = true;
    _agentExecutionCancelled = true;
    keepaliveTimer?.cancel();
    keepaliveTimer = null;
    clearSplit();
    pipe?.dispose();
    remotePath?.dispose();
    localPath?.dispose();
    forwardService?.stopAll();
    pty?.kill();
    pty?.dispose();
    rustTerminalBridge?.close();
    rustTerminalBridge = null;
    rustTerminalCore?.close();
    rustTerminalCore = null;
    final session = sshSession;
    if (session != null) safeSshTeardown(() => session.close());
    sshSession = null;
    final client = sshClient;
    if (client != null) safeSshTeardown(() => client.close());
    sshClient = null;
    final jump = jumpClient;
    if (jump != null) safeSshTeardown(() => jump.close());
    jumpClient = null;
    terminalController.dispose();
    splitTerminalController.dispose();
    transferManager?.dispose();
    editorDirty.dispose();
  }

  IconData get icon => switch (kind) {
    AppTabKind.local => Icons.terminal,
    AppTabKind.ssh => Icons.lock_outline,
    AppTabKind.sshConnecting => Icons.lock_outline,
    AppTabKind.sshError => Icons.error_outline,
    AppTabKind.settings => Icons.settings_outlined,
    AppTabKind.editor => Icons.edit_note,
  };
}
