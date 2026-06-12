import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:window_manager/window_manager.dart';

import 'dialogs/connect_dialog.dart';
import 'dialogs/password_prompt_dialog.dart';
import 'io/output_pipe.dart';
import 'services/shell_integration.dart' show stripAnsi;
import 'services/command_safety.dart';
import 'services/credential_storage.dart';
import 'models/app_config.dart';
import 'models/command.dart';
import 'models/commands_store.dart';
import 'models/agent_config.dart';
import 'models/tab_model.dart';
import 'models/terminal_settings.dart';
import 'models/saved_hosts_store.dart';
import 'models/ssh_config.dart';
import 'models/ssh_host.dart';
import 'services/host_key_verifier.dart';
import 'services/bundled_skills.dart';
import 'services/file_write_service.dart';
import 'services/local_pty_service.dart';
import 'services/local_shell_discovery.dart';
import 'services/local_shell_wrapper.dart';
import 'services/port_forward_service.dart';
import 'services/remote_cwd_parser.dart';
import 'services/remote_home.dart';
import 'services/session_logger.dart';
import 'services/skill_service.dart';
import 'services/ssh_connection.dart';
import 'services/wallpaper_storage.dart';
import 'utils/app_dir.dart';
import 'utils/fd_limit.dart';
import 'utils/ssh_error_messages.dart';
import 'views/settings/settings_sheet.dart' show SettingsPage;
import 'widgets/cmd_picker_button.dart';
import 'widgets/ai_assistant_panel.dart';
import 'widgets/ai_assistant_button.dart';
import 'widgets/frosted_glass.dart';
import 'widgets/split_view.dart';
import 'widgets/terminal_surface.dart'
    show TerminalSurface, TerminalContextMenuConfig;
import 'models/transfer_task.dart';
import 'views/sftp_view.dart' show SftpView, SftpViewState;
import 'views/ssh_session_view.dart';
import 'widgets/transfer_panel.dart';
import 'widgets/wallpaper_background.dart';

part 'app/main_local.dart';
part 'app/main_ssh.dart';
part 'app/main_chrome.dart';
part 'app/main_desktop_home.dart';
part 'app/main_mobile.dart';
part 'app/main_mobile_nav.dart';
part 'app/main_mobile_connections.dart';
part 'app/main_views.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Must run before the first Pty.start: spawned shells inherit RLIMIT_NOFILE
  // from this process, and macOS's default 256 is too low for plugin-heavy
  // zsh setups.
  raiseFileDescriptorLimit();

  // Register bundled DYNAMIC skills (Dart functions that produce SKILL.md
  // content with live runtime data — see services/bundled_skills.dart)
  // BEFORE SkillService.init() so they're merged into the catalogue on
  // the very first sweep.  Order matters: registration is sync + cheap,
  // init() is async + reads the asset manifest.
  registerDefaultBundledSkills();

  // Discover bundled Skills (assets/skills/*/SKILL.md PLUS the dynamic
  // ones above) BEFORE runApp so the first LLM call already sees the
  // catalogue when the agent loop announces it.  init() is fast (a few
  // small text files) and fail-safe: a malformed SKILL.md is logged and
  // skipped, never throws.
  await SkillService.init();

  // Custom title bar: hide the OS-drawn caption strip and let the tab bar take
  // its place (Chrome / Edge / Windows Terminal style). On macOS the native
  // traffic-light buttons stay visible; on Windows/Linux we draw our own
  // min/max/close controls inside the tab bar.
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    // Pin a default size and `center: true` here on purpose:
    //   • macOS's `applicationSupportsSecureRestorableState = true` (see
    //     AppDelegate.swift) makes the OS restore the previous frame on
    //     launch, which clobbers the `center()` call we make in
    //     MainFlutterWindow.swift's awakeFromNib.  Without `size:` +
    //     `center: true` here, `window_manager`'s ready-to-show hook
    //     also leaves the OS-restored frame untouched and the window
    //     ends up wherever it was last closed (commonly the lower-left
    //     after some accidental resize during dev).
    //   • Setting both anchors EVERY launch to a known-good frame.  We
    //     can layer in per-user window-state persistence later via
    //     `windowManager.getBounds()` + SharedPreferences if needed;
    //     the predictable default beats inheriting a random frame.
    //   • Same 960×720 default as `MainFlutterWindow.defaultContentSize`
    //     so the Swift and Dart hints don't fight each other.
    const windowOptions = WindowOptions(
      size: Size(960, 720),
      minimumSize: Size(640, 480),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: true,
      backgroundColor: Color(0xFF1E1E1E),
    );
    if (Platform.isMacOS) {
      await windowManager.setBrightness(Brightness.dark);
    }
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const SsTermApp());
}

class SsTermApp extends StatelessWidget {
  const SsTermApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSTerm',
      debugShowCheckedModeBanner: false,
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.dark,
      home: const TerminalHome(),
    );
  }
}

// Chrome palette — foreground; backgrounds come from [TerminalSettings].
const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);
const _kTabRadius = 6.0;

// ── Tab model ────────────────────────────────────────────────────────────────
typedef _Tab = AppTab;
typedef _TabKind = AppTabKind;

// ── Home ──────────────────────────────────────────────────────────────────────
class TerminalHome extends StatefulWidget {
  const TerminalHome({super.key});

  @override
  State<TerminalHome> createState() => _TerminalHomeState();
}

// ─────────────────────────────────────────────────────────────────────────────
// Lifecycle only — state init, disposal, and top-level build dispatch.
// All business logic lives in _TerminalHomeLocalMethods / _TerminalHomeSshMethods.
// All UI building lives in _TerminalHomeViewMethods.
// ─────────────────────────────────────────────────────────────────────────────
class _TerminalHomeState extends _TerminalHomeViewMethods {

  @override
  void initState() {
    super.initState();
    // iOS sandbox forbids forkpty(); local shell is unavailable on iOS/iPadOS.
    // Start with an SSH connect dialog instead of a doomed local tab.
    if (!Platform.isIOS) {
      _newLocalTab(LocalShellDiscovery.defaultShell(_localShells));
    }
    _loadSshHosts();
    AppConfig.load().then((c) {
      if (!mounted) return;
      setState(() {
        _config = c;
        // Prefer the persisted list (includes WSL distros on Windows) over the
        // boot-time sync discovery. Falls back to the sync result when the
        // config has nothing yet (first launch).
        if (c.cachedShells.isNotEmpty) _localShells = c.cachedShells;
      });
      // Background diff: only setState + save when the discovered list
      // actually differs from what we just restored. This keeps subsequent
      // `+` clicks free of any discovery cost and avoids gratuitous rebuilds
      // of the chrome (which would otherwise thrash the paragraph caches of
      // every open terminal).
      unawaited(_refreshLocalShellsIfChanged());
    });
  }

  @override
  void dispose() {
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(extensions: {
        AppColors.fromBackground(_config.terminal.chromeTabSelected),
      }),
      child: Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.comma):
            const _OpenSettingsIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyW):
            const _CloseTabIntent(),
      },
      child: Actions(
        actions: {
          _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
            onInvoke: (_) {
              _openSettings();
              return null;
            },
          ),
          _CloseTabIntent: CallbackAction<_CloseTabIntent>(
            onInvoke: (_) {
              _closeTab(_active);
              return null;
            },
          ),
        },
        child: (Platform.isIOS || Platform.isAndroid)
            ? _buildMobileChrome()
            : _buildChrome(),
      ),
    ),   // Theme
    );
  }
}
