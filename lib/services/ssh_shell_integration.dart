import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Requests the same login shell as command-line SSH, then attaches cwd hooks
/// to that shell. An exec request would suppress sshd's login messages/MOTD.
Future<SSHSession> openSshLoginShell(
  SSHClient client, {
  int width = 80,
  int height = 24,
}) async {
  await client.authenticated;
  if (client.remoteVersion?.contains('OpenSSH_for_Windows') ?? false) {
    // Windows' native shell has its own startup/console behavior and cannot
    // run POSIX cwd hooks. Do not send stty or bash syntax to it.
    return client.shell(
      pty: SSHPtyConfig(width: width, height: height),
    );
  }
  final integration = SshShellIntegration();
  // This must be the first session channel. On PAM servers an earlier exec
  // probe can consume the login messages before the visible shell sees them.
  final session = await client.shell(
    pty: SSHPtyConfig(
      width: width,
      height: height,
      // RFC 4254: ECHO=0, ECHONL=0, TTY_OP_END. Prevent input queued during
      // login from echoing ahead of the MOTD; initialization restores echo.
      terminalModes: Uint8List.fromList([53, 0, 0, 0, 0, 56, 0, 0, 0, 0, 0]),
    ),
    stdoutTransformer: integration.outputTransformer,
  );
  // Probe only after opening the visible login shell. Other POSIX shells keep
  // their native prompt; only bash/zsh receive the cwd hook.
  SSHSession? probe;
  var supported = false;
  try {
    probe = await client.execute(r'''printf '%s' "$SHELL"''');
    final name = utf8
        .decode(
          await probe.stdout
              .fold<BytesBuilder>(
                BytesBuilder(),
                (buffer, bytes) => buffer..add(bytes),
              )
              .then((buffer) => buffer.takeBytes())
              .timeout(const Duration(seconds: 5)),
          allowMalformed: true,
        )
        .trim()
        .split('/')
        .last;
    supported = name == 'bash' || name == 'zsh';
  } on Exception {
    // Shell access need not imply permission to run a separate command.
  } finally {
    probe?.close();
  }

  session.write(utf8.encode(integration.command(trackCwd: supported)));
  return session;
}

/// Per-session startup framing. Bash respects the initial no-echo mode; zsh's
/// line editor may still echo input. Strip only our framed initialization,
/// preserving all earlier server/login output and all later terminal bytes.
class SshShellIntegration {
  SshShellIntegration({String? token})
    : token =
          token ??
          List.generate(
            12,
            (_) => Random.secure().nextInt(16).toRadixString(16),
          ).join();

  final String token;

  String get _echoPrefix => ' : $token;';
  String get _start => '\x1b]777;ssterm-start;$token;prompt\x07';
  String get _emptyPromptStart => '\x1b]777;ssterm-start;$token;\x07';
  String get _end => '\x1b]777;ssterm-end;$token\x07';

  String command({bool trackCwd = true}) {
    // A single input line avoids secondary prompts and canonical-input limits.
    // Leading space respects the usual ignorespace/ignoreboth history policy.
    final script =
        '''
__ssterm_cwd() { printf '\\033]7;file://%s\\033\\\\' "\$PWD"; };
if [ -n "\${ZSH_VERSION-}" ]; then
  case " \${precmd_functions[*]} " in
    *" __ssterm_cwd "*) : ;;
    *) precmd_functions+=(__ssterm_cwd) ;;
  esac;
elif [ -n "\${BASH_VERSION-}" ]; then
  case "\$(declare -p PROMPT_COMMAND 2>/dev/null)" in
    'declare -a'*)
      case " \${PROMPT_COMMAND[*]} " in
        *" __ssterm_cwd "*) : ;;
        *) PROMPT_COMMAND+=(__ssterm_cwd) ;;
      esac ;;
    *)
      case ";\${PROMPT_COMMAND-};" in
        *";__ssterm_cwd;"*) : ;;
        *) PROMPT_COMMAND="__ssterm_cwd\${PROMPT_COMMAND:+;\$PROMPT_COMMAND}" ;;
      esac ;;
  esac;
  $_bashPromptCompatibility
fi;
'''
            .trim()
            .split('\n')
            .map((line) => line.trim())
            .join(' ');
    final quoted = script.replaceAll("'", "'\\''");
    final hook = trackCwd ? "eval '$quoted'; " : '';
    final report = trackCwd ? '; __ssterm_cwd' : '';
    final prompt = trackCwd ? r'"${PS1:+prompt}"' : "''";
    return "$_echoPrefix stty echo; "
        "printf '\\033]777;ssterm-start;$token;%s\\007' $prompt; "
        "${hook}printf '\\033]777;ssterm-end;$token\\007\\r\\033[2K'"
        '$report\n';
  }

  StreamTransformer<Uint8List, Uint8List> get outputTransformer =>
      StreamTransformer.fromBind(_filterOutput);

  Stream<Uint8List> _filterOutput(Stream<Uint8List> source) async* {
    final echo = utf8.encode(_echoPrefix);
    final start = utf8.encode(_start);
    final emptyStart = utf8.encode(_emptyPromptStart);
    final end = utf8.encode(_end);
    var pending = <int>[];
    var hiding = false;
    var complete = false;
    await for (final bytes in source) {
      if (complete) {
        yield bytes;
        continue;
      }
      pending.addAll(bytes);
      if (!hiding) {
        var at = -1;
        var markerLength = 0;
        var useEcho = false;
        var hasPrompt = false;
        for (final candidate in [
          (bytes: echo, echoed: true, prompt: false),
          (bytes: start, echoed: false, prompt: true),
          (bytes: emptyStart, echoed: false, prompt: false),
        ]) {
          final found = _indexOf(pending, candidate.bytes);
          if (found >= 0 && (at < 0 || found < at)) {
            at = found;
            markerLength = candidate.bytes.length;
            useEcho = candidate.echoed;
            hasPrompt = candidate.prompt;
          }
        }
        if (at >= 0) {
          // Readline may already have printed a prompt and accepted the
          // invisible command with CR/LF. Neither belongs in the transcript.
          // Keep login lines, but discard that transient prompt line too.
          final visibleEnd = _beforeStartupPrompt(
            pending,
            at,
            echoed: useEcho,
            hasPrompt: hasPrompt,
          );
          if (visibleEnd > 0) {
            yield Uint8List.fromList(pending.sublist(0, visibleEnd));
          }
          pending = pending.sublist(at + markerLength);
          hiding = true;
        } else {
          // Retain the last complete line and the current partial line until
          // the marker arrives. Packet boundaries must not release the first
          // prompt or its Enter before we know initialization has started.
          final markerSafe =
              pending.length - max(echo.length, start.length).toInt() + 1;
          final lastNewline = pending.lastIndexOf(10);
          final previousNewline = lastNewline <= 0
              ? -1
              : pending.lastIndexOf(10, lastNewline - 1);
          final safe = min(markerSafe, previousNewline + 1).toInt();
          if (safe > 0) {
            yield Uint8List.fromList(pending.sublist(0, safe));
            pending = pending.sublist(safe);
          }
        }
      }
      if (hiding) {
        final at = _indexOf(pending, end);
        if (at >= 0) {
          final rest = pending.sublist(at + end.length);
          if (rest.isNotEmpty) yield Uint8List.fromList(rest);
          pending = [];
          complete = true;
        } else if (pending.length >= end.length) {
          pending = pending.sublist(pending.length - end.length + 1);
        }
      }
    }
    if (!hiding && pending.isNotEmpty) yield Uint8List.fromList(pending);
    if (hiding && !complete) {
      yield Uint8List.fromList(
        utf8.encode('\r\n[SSTerm shell integration did not finish]\r\n'),
      );
    }
  }
}

int _beforeStartupPrompt(
  List<int> bytes,
  int end, {
  required bool echoed,
  required bool hasPrompt,
}) {
  var lineStart = bytes.lastIndexOf(10, end - 1) + 1;
  if (!echoed && lineStart > 0) {
    // Modern readline emits a newline before execution. Shell integrations
    // may put OSC/CSI metadata between that newline and our start marker.
    final suffix = _visibleText(bytes.sublist(lineStart, end));
    if (suffix.isEmpty) {
      final previousStart = lineStart <= 1
          ? 0
          : bytes.lastIndexOf(10, lineStart - 2) + 1;
      if (hasPrompt ||
          _visibleText(bytes.sublist(previousStart, lineStart)).isEmpty) {
        lineStart = previousStart;
      }
    } else if (!hasPrompt) {
      return end;
    }
  }
  return lineStart;
}

String _visibleText(List<int> bytes) => String.fromCharCodes(bytes)
    .replaceAll(RegExp(r'\x1b\][\s\S]*?(?:\x07|\x1b\\)'), '')
    .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
    .trim();

// Preserve the existing workaround for Tencent Cloud's custom bash: its
// readline miscounts prompt width when the window title embeds \\u/\\h/\\w.
const _bashPromptCompatibility = r'''
case "$PS1" in
  *'\[\e]0;'*'\a\]'*)
    __ssterm_ps1_before="${PS1%%'\[\e]0;'*}";
    __ssterm_ps1_after="${PS1#*'\a\]'}";
    PS1="${__ssterm_ps1_before}${__ssterm_ps1_after}";
    unset __ssterm_ps1_before __ssterm_ps1_after ;;
esac;
''';

int _indexOf(List<int> bytes, List<int> pattern) {
  for (var at = 0; at <= bytes.length - pattern.length; at++) {
    var matches = true;
    for (var offset = 0; offset < pattern.length; offset++) {
      if (bytes[at + offset] != pattern[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return at;
  }
  return -1;
}
