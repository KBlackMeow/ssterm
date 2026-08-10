import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../io/output_pipe.dart';
import '../services/local_shell_discovery.dart';
import '../services/port_forward_service.dart';
import '../views/file_editor_view.dart';
import 'ssh_host.dart';
import 'transfer_task.dart';

enum AppTabKind { local, ssh, sshConnecting, sshError, settings, editor }

/// Best-effort SSH teardown; must not throw when the transport is already dead.
void safeSshTeardown(void Function() close) {
  try {
    close();
  } on SSHStateError {
    // Transport or channel already closed (e.g. VPN drop).
  } catch (_) {}
}

class AppTab {
  AppTabKind kind;
  String title;
  LocalShellOption? localShell;

  /// Populated while [kind] is [AppTabKind.sshError]; cleared on retry.
  String? connectionError;

  // ── Pane 0 ──────────────────────────────────────────────────────────────────
  Terminal? terminal;
  Pty? pty;
  SSHClient? sshClient;
  SSHClient? jumpClient;
  SSHSession? sshSession;
  SftpClient? sftp;
  ValueNotifier<String>? remotePath;
  String? remoteCwdPane0;
  String? remoteCwdPane1;
  int activeSshPane = 0;
  ValueNotifier<String>? localPath;
  OutputPipe? pipe;
  final terminalViewKey = GlobalKey<TerminalViewState>();

  PortForwardService? forwardService;
  SshHost? sshProfile;
  bool manuallyDisconnected = false;
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
  bool sftpPanelVisible = false;
  bool aiPanelVisible = false;

  /// The agent is a separate host from the visible terminal. Its cwd never
  /// follows OSC-7 updates from the visible terminal.
  bool agentPanelVisible = false;
  String? agentCwd;
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
  Terminal? splitTerminal;
  SSHSession? splitSshSession;
  Pty? splitPty;
  OutputPipe? splitPipe;
  final splitViewKey = GlobalKey<TerminalViewState>();
  Axis splitAxis = Axis.horizontal;

  final terminalController = TerminalController();
  final splitTerminalController = TerminalController();

  bool primarySessionEnded = false;
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
    splitTerminal = null;
    splitSshSession = null;
    splitPty = null;
    splitPipe = null;
    splitSessionEnded = false;
    remoteCwdPane1 = null;
    if (activeSshPane == 1) activeSshPane = 0;
    syncRemotePathToActivePane();
  }

  void syncRemotePathToActivePane() {
    if (remotePath == null || manuallyDisconnected) return;
    final cwd = activeSshPane == 1 && isSplit
        ? (remoteCwdPane1 ?? remoteCwdPane0)
        : remoteCwdPane0;
    if (cwd != null && cwd.isNotEmpty) {
      remotePath!.value = cwd;
    }
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
    pty = null;
    sshSession?.close();
    sshSession = null;

    terminal = splitTerminal;
    splitTerminal = null;
    pty = splitPty;
    splitPty = null;
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
    keepaliveTimer?.cancel();
    keepaliveTimer = null;
    clearSplit();
    pipe?.dispose();
    remotePath?.dispose();
    localPath?.dispose();
    forwardService?.stopAll();
    pty?.kill();
    pty?.dispose();
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
