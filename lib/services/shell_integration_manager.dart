import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/app_dir.dart';
import 'local_shell_discovery.dart';

const _integrationBegin = '# >>> SSTerm Shell Integration v1 >>>';
const _integrationEnd = '# <<< SSTerm Shell Integration v1 <<<';

enum ShellIntegrationState {
  checking,
  notInstalled,
  installed,
  damaged,
  unavailable,
}

enum ShellIntegrationKind {
  powershell,
  bash,
  zsh,
  fish,
  wslBash,
  wslZsh,
  wslFish,
  cmd,
}

class ShellIntegrationTarget {
  const ShellIntegrationTarget({
    required this.id,
    required this.label,
    required this.kind,
    this.profilePath,
    this.distribution,
    this.state = ShellIntegrationState.notInstalled,
    this.message,
  });

  final String id;
  final String label;
  final ShellIntegrationKind kind;
  final String? profilePath;
  final String? distribution;
  final ShellIntegrationState state;
  final String? message;

  ShellIntegrationTarget copyWith({
    ShellIntegrationState? state,
    String? message,
  }) => ShellIntegrationTarget(
    id: id,
    label: label,
    kind: kind,
    profilePath: profilePath,
    distribution: distribution,
    state: state ?? this.state,
    message: message,
  );
}

class ShellIntegrationManager {
  static Future<List<ShellIntegrationTarget>> discover() async {
    final targets = <String, ShellIntegrationTarget>{};
    await for (final target in discoverIncrementally()) {
      targets[target.id] = target;
    }
    return targets.values.toList(growable: false);
  }

  static Stream<ShellIntegrationTarget> discoverIncrementally() {
    late final StreamController<ShellIntegrationTarget> controller;
    var cancelled = false;
    controller = StreamController<ShellIntegrationTarget>(
      onListen: () async {
        final pending = <Future<void>>[];
        void emit(ShellIntegrationTarget target) {
          if (!cancelled && !controller.isClosed) controller.add(target);
        }

        void inspect(ShellIntegrationTarget target) {
          emit(target.copyWith(state: ShellIntegrationState.checking));
          pending.add(check(target).then(emit));
        }

        try {
          if (Platform.isIOS || Platform.isAndroid) return;
          final home = userHomeDir();
          if (home == null) return;
          final documents = Platform.isWindows
              ? await _windowsDocumentsDirectory(home)
              : null;
          for (final target in _nativeTargets(home, documents: documents)) {
            inspect(target);
          }

          if (Platform.isWindows) {
            List<String> distros = const [];
            try {
              distros = await _listWslDistros();
            } catch (error, stackTrace) {
              if (!cancelled && !controller.isClosed) {
                controller.addError(error, stackTrace);
              }
            }
            for (final distro in distros) {
              final placeholder = ShellIntegrationTarget(
                id: 'wsl:$distro',
                label: 'WSL $distro',
                kind: ShellIntegrationKind.wslBash,
                distribution: distro,
                state: ShellIntegrationState.checking,
                message: 'Detecting the default user and login shell…',
              );
              emit(placeholder);
              pending.add(
                _wslTarget(distro).then((target) async {
                  if (target.state == ShellIntegrationState.unavailable) {
                    emit(target);
                    return;
                  }
                  emit(target.copyWith(state: ShellIntegrationState.checking));
                  emit(await check(target));
                }),
              );
            }
          }
          await Future.wait(pending);
        } catch (error, stackTrace) {
          if (!cancelled && !controller.isClosed) {
            controller.addError(error, stackTrace);
          }
        } finally {
          if (!cancelled && !controller.isClosed) await controller.close();
        }
      },
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }

  static List<ShellIntegrationTarget> _nativeTargets(
    String home, {
    String? documents,
  }) {
    final targets = <ShellIntegrationTarget>[];
    if (Platform.isWindows) {
      final shells = LocalShellDiscovery.discoverSync();
      if (shells.any((shell) => shell.id == 'cmd')) {
        targets.add(
          const ShellIntegrationTarget(
            id: 'cmd',
            label: 'CMD',
            kind: ShellIntegrationKind.cmd,
            state: ShellIntegrationState.installed,
            message: 'Built in through the PROMPT environment variable.',
          ),
        );
      }
      if (shells.any((shell) => shell.id == 'powershell')) {
        targets.add(
          ShellIntegrationTarget(
            id: 'powershell',
            label: 'Windows PowerShell',
            kind: ShellIntegrationKind.powershell,
            profilePath:
                '${documents ?? '$home/Documents'}/WindowsPowerShell/profile.ps1',
          ),
        );
      }
      if (shells.any((shell) => shell.id.startsWith('pwsh'))) {
        targets.add(
          ShellIntegrationTarget(
            id: 'pwsh',
            label: 'PowerShell 7',
            kind: ShellIntegrationKind.powershell,
            profilePath:
                '${documents ?? '$home/Documents'}/PowerShell/profile.ps1',
          ),
        );
      }
      if (shells.any(isGitBashShell)) {
        targets.add(
          ShellIntegrationTarget(
            id: 'git-bash',
            label: 'Git Bash',
            kind: ShellIntegrationKind.bash,
            profilePath: '$home/.bashrc',
          ),
        );
      }
    } else {
      for (final shell in LocalShellDiscovery.discoverSync()) {
        final name = shell.executable.split('/').last.toLowerCase();
        if (name == 'bash' && !targets.any((target) => target.id == 'bash')) {
          targets.add(
            ShellIntegrationTarget(
              id: 'bash',
              label: 'Bash',
              kind: ShellIntegrationKind.bash,
              profilePath: '$home/.bashrc',
            ),
          );
        } else if (name == 'zsh' &&
            !targets.any((target) => target.id == 'zsh')) {
          targets.add(
            ShellIntegrationTarget(
              id: 'zsh',
              label: 'Zsh',
              kind: ShellIntegrationKind.zsh,
              profilePath: '$home/.zshrc',
            ),
          );
        } else if (name == 'fish' &&
            !targets.any((target) => target.id == 'fish')) {
          targets.add(
            ShellIntegrationTarget(
              id: 'fish',
              label: 'Fish',
              kind: ShellIntegrationKind.fish,
              profilePath: '$home/.config/fish/config.fish',
            ),
          );
        }
      }
    }

    return targets;
  }

  static Future<List<String>> _listWslDistros() async {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final result = await Process.run(
      '$root\\System32\\wsl.exe',
      const ['--list', '--quiet'],
      stdoutEncoding: null,
      stderrEncoding: null,
    ).timeout(const Duration(seconds: 10));
    if (result.exitCode != 0) {
      throw Exception(decodeWslProcessOutput(result.stderr).trim());
    }
    return decodeWslProcessOutput(result.stdout, assumeUtf16Le: true)
        .split(RegExp(r'[\r\n]+'))
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
  }

  static Future<String> _windowsDocumentsDirectory(String home) async {
    try {
      final result = await Process.run('reg.exe', const [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
        '/v',
        'Personal',
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) {
        final value = parseWindowsRegistryValue(result.stdout.toString());
        if (value != null) {
          return value.replaceAll(
            RegExp('%USERPROFILE%', caseSensitive: false),
            home,
          );
        }
      }
    } catch (_) {}
    return '$home/Documents';
  }

  static Future<ShellIntegrationTarget> check(
    ShellIntegrationTarget target,
  ) async {
    if (target.kind == ShellIntegrationKind.cmd) return target;
    try {
      final content = await _readProfile(target);
      final hasBegin = content.contains(_integrationBegin);
      final hasEnd = content.contains(_integrationEnd);
      if (hasBegin != hasEnd) {
        return target.copyWith(
          state: ShellIntegrationState.damaged,
          message: 'The SSTerm marker block is incomplete.',
        );
      }
      return target.copyWith(
        state: hasBegin
            ? ShellIntegrationState.installed
            : ShellIntegrationState.notInstalled,
        message: hasBegin ? 'Automatic cwd synchronization is enabled.' : null,
      );
    } catch (error) {
      return target.copyWith(
        state: ShellIntegrationState.unavailable,
        message: error.toString(),
      );
    }
  }

  static Future<ShellIntegrationTarget> retry(
    ShellIntegrationTarget target,
  ) async {
    final distro = target.distribution;
    if (distro != null) {
      final detected = await _wslTarget(distro);
      if (detected.state == ShellIntegrationState.unavailable) return detected;
      return check(detected);
    }
    return check(target);
  }

  static Future<ShellIntegrationTarget> install(
    ShellIntegrationTarget target,
  ) async {
    if (target.kind == ShellIntegrationKind.cmd) return target;
    final current = await _readProfile(target);
    final updated = target.state == ShellIntegrationState.damaged
        ? repairShellIntegrationBlock(
            current,
            shellIntegrationBlockFor(target.kind),
          )
        : upsertShellIntegrationBlock(
            current,
            shellIntegrationBlockFor(target.kind),
          );
    await _writeProfile(target, updated);
    return check(target);
  }

  static Future<ShellIntegrationTarget> uninstall(
    ShellIntegrationTarget target,
  ) async {
    if (target.kind == ShellIntegrationKind.cmd) return target;
    final current = await _readProfile(target);
    await _writeProfile(target, removeShellIntegrationBlock(current));
    return check(target);
  }

  static Future<ShellIntegrationTarget> _wslTarget(String distro) async {
    try {
      final results = await Future.wait([
        _runWsl(distro, const ['printenv', 'HOME']),
        _runWsl(distro, const ['printenv', 'SHELL']),
      ]);
      for (final result in results) {
        if (result.exitCode != 0) {
          throw Exception(result.stderr.trim());
        }
      }
      final home = results[0].stdout.trim();
      final shell = results[1].stdout.trim();
      if (!home.startsWith('/')) {
        throw StateError('WSL returned an invalid HOME directory: $home');
      }
      final shellName = shell.split('/').last.toLowerCase();
      if (shellName != 'bash' && shellName != 'zsh' && shellName != 'fish') {
        throw UnsupportedError(
          'The default WSL login shell is ${shell.isEmpty ? 'unknown' : shell}. '
          'Automatic profile installation currently supports bash, zsh, and fish.',
        );
      }
      final zsh = shellName == 'zsh';
      final fish = shellName == 'fish';
      return ShellIntegrationTarget(
        id: 'wsl:$distro',
        label: 'WSL $distro',
        kind: fish
            ? ShellIntegrationKind.wslFish
            : zsh
            ? ShellIntegrationKind.wslZsh
            : ShellIntegrationKind.wslBash,
        profilePath:
            '$home/${fish
                ? '.config/fish/config.fish'
                : zsh
                ? '.zshrc'
                : '.bashrc'}',
        distribution: distro,
      );
    } catch (error) {
      return ShellIntegrationTarget(
        id: 'wsl:$distro',
        label: 'WSL $distro',
        kind: ShellIntegrationKind.wslBash,
        distribution: distro,
        state: ShellIntegrationState.unavailable,
        message: error.toString(),
      );
    }
  }

  static Future<String> _readProfile(ShellIntegrationTarget target) async {
    if (target.distribution != null) {
      final path = target.profilePath;
      if (path == null) throw StateError('WSL profile path is unavailable.');
      final file = File(_wslUncPath(target.distribution!, path));
      return await file.exists()
          ? decodeProfileBytes(await file.readAsBytes())
          : '';
    }
    final path = target.profilePath;
    if (path == null) throw StateError('Profile path is unavailable.');
    final file = File(path);
    return await file.exists()
        ? decodeProfileBytes(await file.readAsBytes())
        : '';
  }

  static Future<void> _writeProfile(
    ShellIntegrationTarget target,
    String content,
  ) async {
    final path = target.profilePath;
    if (path == null) throw StateError('Profile path is unavailable.');
    if (target.distribution != null) {
      await _writeLocalProfileFile(
        File(_wslUncPath(target.distribution!, path)),
        content,
      );
      return;
    }

    await _writeLocalProfileFile(File(path), content);
  }

  static Future<void> _writeLocalProfileFile(File file, String content) async {
    final path = file.path;
    await file.parent.create(recursive: true);
    final existed = await file.exists();
    final originalBytes = existed ? await file.readAsBytes() : null;
    if (existed) {
      await file.copy('$path.ssterm-backup');
    }
    final temporary = File('$path.ssterm-tmp');
    await temporary.writeAsBytes(
      encodeProfileContent(content, originalBytes),
      flush: true,
    );
    try {
      if (await file.exists()) await file.delete();
      await temporary.rename(path);
    } catch (_) {
      if (!await file.exists() && originalBytes != null) {
        await file.writeAsBytes(originalBytes, flush: true);
      }
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  static String _wslUncPath(String distro, String linuxPath) {
    if (!linuxPath.startsWith('/')) {
      throw ArgumentError.value(
        linuxPath,
        'linuxPath',
        'WSL profile path must be absolute.',
      );
    }
    return r'\\wsl$\' + distro + linuxPath.replaceAll('/', r'\');
  }

  static Future<_WslResult> _runWsl(
    String distro,
    List<String> arguments,
  ) async {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final result = await Process.run(
      '$root\\System32\\wsl.exe',
      ['-d', distro, '--', ...arguments],
      stdoutEncoding: null,
      stderrEncoding: null,
    ).timeout(const Duration(seconds: 10));
    return _WslResult(
      exitCode: result.exitCode,
      stdout: decodeWslProcessOutput(result.stdout),
      stderr: decodeWslProcessOutput(result.stderr),
    );
  }
}

class _WslResult {
  const _WslResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

String decodeWslProcessOutput(Object? value, {bool assumeUtf16Le = false}) {
  if (value is String) return value;
  if (value is! List<int> || value.isEmpty) return '';
  var bytes = value;
  final hasUtf16LeBom =
      bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe;
  if (hasUtf16LeBom) {
    bytes = bytes.sublist(2);
  }
  final pairs = bytes.length ~/ 2;
  final zeroHighBytes = pairs == 0
      ? 0
      : List.generate(
          pairs,
          (index) => bytes[index * 2 + 1],
        ).where((byte) => byte == 0).length;
  if (assumeUtf16Le ||
      hasUtf16LeBom ||
      (pairs > 0 && zeroHighBytes >= pairs ~/ 3)) {
    final units = <int>[];
    for (var index = 0; index + 1 < bytes.length; index += 2) {
      units.add(bytes[index] | (bytes[index + 1] << 8));
    }
    return String.fromCharCodes(units).replaceAll('\u0000', '');
  }
  return utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '');
}

String? parseWindowsRegistryValue(String output) {
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    final match = RegExp(
      r'^\s*Personal\s+REG_(?:EXPAND_)?SZ\s+(.+?)\s*$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

String decodeProfileBytes(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }
  final offset =
      bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf
      ? 3
      : 0;
  return utf8.decode(bytes.sublist(offset));
}

List<int> encodeProfileContent(String content, List<int>? originalBytes) {
  if (originalBytes != null &&
      originalBytes.length >= 2 &&
      originalBytes[0] == 0xff &&
      originalBytes[1] == 0xfe) {
    return [0xff, 0xfe, ..._encodeUtf16(content, littleEndian: true)];
  }
  if (originalBytes != null &&
      originalBytes.length >= 2 &&
      originalBytes[0] == 0xfe &&
      originalBytes[1] == 0xff) {
    return [0xfe, 0xff, ..._encodeUtf16(content, littleEndian: false)];
  }
  final hadUtf8Bom =
      originalBytes != null &&
      originalBytes.length >= 3 &&
      originalBytes[0] == 0xef &&
      originalBytes[1] == 0xbb &&
      originalBytes[2] == 0xbf;
  return [
    if (hadUtf8Bom) ...const [0xef, 0xbb, 0xbf],
    ...utf8.encode(content),
  ];
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var index = 0; index + 1 < bytes.length; index += 2) {
    units.add(
      littleEndian
          ? bytes[index] | (bytes[index + 1] << 8)
          : (bytes[index] << 8) | bytes[index + 1],
    );
  }
  return String.fromCharCodes(units);
}

List<int> _encodeUtf16(String value, {required bool littleEndian}) {
  final bytes = <int>[];
  for (final unit in value.codeUnits) {
    if (littleEndian) {
      bytes.addAll([unit & 0xff, unit >> 8]);
    } else {
      bytes.addAll([unit >> 8, unit & 0xff]);
    }
  }
  return bytes;
}

({String home, String shell}) parseWslProfileProbe(String output) {
  const marker = '__SSTERM_PROFILE__\t';
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    final markerIndex = line.indexOf(marker);
    if (markerIndex < 0) continue;
    final fields = line.substring(markerIndex + marker.length).split('\t');
    if (fields.length < 2) continue;
    final home = fields[0].trim();
    final shell = fields[1].trim();
    if (!home.startsWith('/')) {
      throw StateError('WSL returned an invalid HOME directory: $home');
    }
    return (home: home, shell: shell);
  }
  final summary = output.trim().replaceAll(RegExp(r'\s+'), ' ');
  throw StateError(
    summary.isEmpty
        ? 'WSL did not return its default user profile.'
        : 'WSL profile probe returned no valid result: $summary',
  );
}

String upsertShellIntegrationBlock(String content, String block) {
  final newline = content.contains('\r\n') ? '\r\n' : '\n';
  final body = block.replaceAll('\r\n', '\n').replaceAll('\n', newline);
  final normalizedBlock =
      '$_integrationBegin$newline$body$newline$_integrationEnd';
  final begin = content.indexOf(_integrationBegin);
  final end = content.indexOf(_integrationEnd);
  if ((begin < 0) != (end < 0)) {
    throw const FormatException('Incomplete SSTerm Shell Integration block.');
  }
  if (begin >= 0) {
    final after = end + _integrationEnd.length;
    return '${content.substring(0, begin)}$normalizedBlock${content.substring(after)}';
  }
  if (content.isEmpty) return '$normalizedBlock$newline';
  return '${content.trimRight()}$newline$newline$normalizedBlock$newline';
}

String removeShellIntegrationBlock(String content) {
  final newline = content.contains('\r\n') ? '\r\n' : '\n';
  final begin = content.indexOf(_integrationBegin);
  final end = content.indexOf(_integrationEnd);
  if (begin < 0 && end < 0) return content;
  if (begin < 0 || end < begin) {
    throw const FormatException('Incomplete SSTerm Shell Integration block.');
  }
  final after = end + _integrationEnd.length;
  final merged = '${content.substring(0, begin)}${content.substring(after)}';
  return '${merged.replaceAll(RegExp(r'(?:\r?\n){3,}'), '$newline$newline').trimRight()}$newline';
}

String repairShellIntegrationBlock(String content, String block) {
  final begin = content.indexOf(_integrationBegin);
  final end = content.indexOf(_integrationEnd);
  if (begin >= 0 && end < 0) {
    return upsertShellIntegrationBlock(content.substring(0, begin), block);
  }
  if (begin < 0 && end >= 0) {
    final lineStart = content.lastIndexOf('\n', end);
    final after = end + _integrationEnd.length;
    final withoutEnd =
        '${content.substring(0, lineStart < 0 ? 0 : lineStart)}'
        '${content.substring(after)}';
    return upsertShellIntegrationBlock(withoutEnd, block);
  }
  return upsertShellIntegrationBlock(content, block);
}

String shellIntegrationBlockFor(ShellIntegrationKind kind) => switch (kind) {
  ShellIntegrationKind.powershell =>
    r'''if ($env:TERM_PROGRAM -eq 'ssterm' -and -not $global:SSTermShellIntegrationLoaded) {
  $global:SSTermShellIntegrationLoaded = $true
  $script:SSTermPreviousPrompt = $function:prompt
  function global:prompt {
    try {
      $sstermPath = $PWD.ProviderPath.Replace('\', '/')
      [Console]::Out.Write([char]27 + ']7;file:///' + $sstermPath + [char]27 + '\')
    } catch {}
    if ($script:SSTermPreviousPrompt) { & $script:SSTermPreviousPrompt } else { "PS $($PWD.Path)> " }
  }
}''',
  ShellIntegrationKind.bash || ShellIntegrationKind.wslBash =>
    r'''if [ "${TERM_PROGRAM:-}" = "ssterm" ] && [ "${SSTERM_SHELL_INTEGRATION:-}" != "1" ]; then
  export SSTERM_SHELL_INTEGRATION=1
  __ssterm_cwd() { printf '\033]7;file://%s\033\\' "$PWD"; }
  if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
    case " ${PROMPT_COMMAND[*]} " in
      *" __ssterm_cwd "*) ;;
      *) PROMPT_COMMAND=(__ssterm_cwd "${PROMPT_COMMAND[@]}") ;;
    esac
  else
    case ";${PROMPT_COMMAND:-};" in
      *";__ssterm_cwd;"*) ;;
      *) PROMPT_COMMAND="__ssterm_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac
  fi
fi''',
  ShellIntegrationKind.zsh || ShellIntegrationKind.wslZsh =>
    r'''if [[ "${TERM_PROGRAM:-}" == "ssterm" && "${SSTERM_SHELL_INTEGRATION:-}" != "1" ]]; then
  export SSTERM_SHELL_INTEGRATION=1
  __ssterm_cwd() { printf '\033]7;file://%s\033\\' "$PWD"; }
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd __ssterm_cwd
fi''',
  ShellIntegrationKind.fish || ShellIntegrationKind.wslFish =>
    r'''if test "$TERM_PROGRAM" = "ssterm"; and not set -q SSTERM_SHELL_INTEGRATION
  set -gx SSTERM_SHELL_INTEGRATION 1
  function __ssterm_cwd --on-event fish_prompt
    printf '\e]7;file://%s\e\\' (pwd)
  end
  __ssterm_cwd
end''',
  ShellIntegrationKind.cmd => '',
};
