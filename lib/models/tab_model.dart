import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../io/output_pipe.dart';
import '../services/local_shell_discovery.dart';
import '../services/port_forward_service.dart';
import 'ssh_host.dart';
import 'transfer_task.dart';

enum AppTabKind { local, ssh, sshConnecting, sshError, settings }

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
  bool sftpPanelVisible = false;
  TransferManager? transferManager;

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
    this.terminal,
    this.localPath,
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

  // ── Pane lifecycle ───────────────────────────────────────────────────────────

  /// Ends pane 1 and returns to single-pane mode.
  void clearSplit() {
    splitPipe?.dispose();
    splitSshSession?.close();
    splitPty?.kill();
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
    if (remotePath == null) return;
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

  void dispose() {
    manuallyDisconnected = true;
    keepaliveTimer?.cancel();
    keepaliveTimer = null;
    clearSplit();
    pipe?.dispose();
    remotePath?.dispose();
    localPath?.dispose();
    forwardService?.stopAll();
    pty?.kill();
    sshSession?.close();
    sshClient?.close();
    jumpClient?.close();
    terminalController.dispose();
    splitTerminalController.dispose();
    transferManager?.dispose();
  }

  IconData get icon => switch (kind) {
    AppTabKind.local => Icons.terminal,
    AppTabKind.ssh => Icons.lock_outline,
    AppTabKind.sshConnecting => Icons.lock_outline,
    AppTabKind.sshError => Icons.error_outline,
    AppTabKind.settings => Icons.settings_outlined,
  };
}
