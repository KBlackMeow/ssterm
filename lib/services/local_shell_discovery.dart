import 'dart:convert';
import 'dart:io';

/// A local shell that can be launched in a PTY tab.
class LocalShellOption {
  const LocalShellOption({
    required this.id,
    required this.displayName,
    required this.executable,
    this.arguments = const [],
    this.environment,
    this.useUnixWrapper = false,
    this.isWsl = false,
  });

  final String id;
  final String displayName;
  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
  final bool useUnixWrapper;
  final bool isWsl;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalShellOption &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Discovers shells available on the current machine.
class LocalShellDiscovery {
  static List<LocalShellOption>? _cache;

  /// Returns cached shells or runs discovery.
  static Future<List<LocalShellOption>> discover({bool refresh = false}) async {
    if (!refresh && _cache != null) return _cache!;
    final shells = await _discoverAll();
    _cache = shells;
    return shells;
  }

  /// Synchronous discovery without WSL (fast path for startup).
  static List<LocalShellOption> discoverSync() {
    final seen = <String>{};
    final shells = <LocalShellOption>[];
    if (Platform.isWindows) {
      _discoverWindowsNative(shells, seen);
    } else {
      _discoverUnix(shells, seen);
    }
    return shells;
  }

  static LocalShellOption defaultShell(List<LocalShellOption> shells) {
    if (shells.isEmpty) return fallback();

    final envShell = Platform.isWindows
        ? Platform.environment['COMSPEC']
        : Platform.environment['SHELL'];

    if (envShell != null) {
      final normalized = _normalizePath(envShell);
      for (final shell in shells) {
        if (_normalizePath(shell.executable) == normalized) {
          return shell;
        }
      }
    }

    return shells.first;
  }

  static LocalShellOption fallback() {
    if (Platform.isWindows) {
      final cmd =
          Platform.environment['COMSPEC'] ?? r'C:\Windows\System32\cmd.exe';
      return LocalShellOption(id: 'cmd', displayName: 'CMD', executable: cmd);
    }
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    return LocalShellOption(
      id: 'shell:${_normalizePath(shell)}',
      displayName: displayNameFor(shell),
      executable: shell,
      useUnixWrapper: true,
    );
  }

  static Future<List<LocalShellOption>> _discoverAll() async {
    final seen = <String>{};
    final shells = <LocalShellOption>[];

    if (Platform.isWindows) {
      _discoverWindowsNative(shells, seen);
      await _discoverWsl(shells, seen);
    } else {
      _discoverUnix(shells, seen);
    }

    return shells;
  }

  static void _discoverWindowsNative(
    List<LocalShellOption> shells,
    Set<String> seen,
  ) {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final candidates =
        <
          ({
            String id,
            String name,
            String path,
            List<String> args,
            Map<String, String>? env,
          })
        >[
          (
            id: 'cmd',
            name: 'CMD',
            path:
                Platform.environment['COMSPEC'] ??
                r'$systemRoot\System32\cmd.exe',
            args: const <String>[],
            env: null,
          ),
          (
            id: 'powershell',
            name: 'PowerShell',
            path: r'$systemRoot\System32\WindowsPowerShell\v1.0\powershell.exe',
            args: const ['-NoLogo'],
            env: null,
          ),
          (
            id: 'pwsh',
            name: 'PowerShell 7',
            path: r'C:\Program Files\PowerShell\7\pwsh.exe',
            args: const ['-NoLogo'],
            env: null,
          ),
          (
            id: 'pwsh-x86',
            name: 'PowerShell 7',
            path: r'C:\Program Files (x86)\PowerShell\7\pwsh.exe',
            args: const ['-NoLogo'],
            env: null,
          ),
          (
            id: 'git-bash',
            name: 'Git Bash',
            path: r'C:\Program Files\Git\usr\bin\env.exe',
            args: const [
              'MSYSTEM=MINGW64',
              'MSYS=enable_pcon winsymlink:nativestrict',
              'CHERE_INVOKING=1',
              'SHELL=/usr/bin/bash',
              '/usr/bin/bash',
              '--login',
              '-i',
            ],
            env: {
              'MSYSTEM': 'MINGW64',
              // ConPTY pseudo-console support; winsymlink alone is not enough.
              'MSYS': 'enable_pcon winsymlink:nativestrict',
              'CHERE_INVOKING': '1',
              // MSYS login scripts exec $SHELL — a Windows path causes
              // "cannot execute binary file".
              'SHELL': '/usr/bin/bash',
            },
          ),
          (
            id: 'git-bash-x86',
            name: 'Git Bash',
            path: r'C:\Program Files (x86)\Git\usr\bin\env.exe',
            args: const [
              'MSYSTEM=MINGW64',
              'MSYS=enable_pcon winsymlink:nativestrict',
              'CHERE_INVOKING=1',
              'SHELL=/usr/bin/bash',
              '/usr/bin/bash',
              '--login',
              '-i',
            ],
            env: {
              'MSYSTEM': 'MINGW64',
              'MSYS': 'enable_pcon winsymlink:nativestrict',
              'CHERE_INVOKING': '1',
              'SHELL': '/usr/bin/bash',
            },
          ),
        ];

    for (final c in candidates) {
      final path = c.path.replaceAll(r'$systemRoot', systemRoot);
      _addShell(
        shells,
        seen,
        id: c.id,
        displayName: c.name,
        executable: path,
        arguments: c.args,
        environment: c.env,
      );
    }
  }

  static Future<void> _discoverWsl(
    List<LocalShellOption> shells,
    Set<String> seen,
  ) async {
    final wsl = _wslExecutable();
    if (wsl == null) return;

    try {
      final result = await Process.run(
        wsl,
        ['--list', '--quiet'],
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (result.exitCode != 0) return;

      final distros = _decodeWslDistroNames(result.stdout);
      for (final distro in distros) {
        final loginShell = await _wslLoginShell(wsl, distro);
        _addShell(
          shells,
          seen,
          id: 'wsl:$distro',
          displayName: 'WSL $distro',
          executable: wsl,
          arguments: ['-d', distro, '--cd', '~', '--', loginShell, '-li'],
          isWsl: true,
        );
      }
    } catch (_) {}
  }

  static Future<String> _wslLoginShell(String wsl, String distro) async {
    try {
      final result = await Process.run(wsl, [
        '-d',
        distro,
        '-e',
        'sh',
        '-lc',
        r'getent passwd "$(id -un)" | cut -d: -f7',
      ]);
      if (result.exitCode == 0) {
        final shell = result.stdout.toString().trim();
        if (shell.startsWith('/')) return shell;
      }
    } catch (_) {}
    return '/bin/sh';
  }

  /// `wsl --list --quiet` returns UTF-16LE names on Windows.
  static List<String> _decodeWslDistroNames(Object? stdout) {
    if (stdout is! List<int> || stdout.isEmpty) {
      return const [];
    }

    var bytes = stdout;
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      bytes = bytes.sublist(2);
    }

    final looksUtf16Le =
        bytes.length > 1 &&
        List.generate(
              bytes.length ~/ 2,
              (i) => bytes[(i * 2) + 1],
            ).where((byte) => byte == 0).length >=
            (bytes.length ~/ 4);

    final text = looksUtf16Le ? _decodeUtf16Le(bytes) : utf8.decode(bytes);
    return text
        .replaceAll('\u0000', '')
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  static String _decodeUtf16Le(List<int> bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  static void _discoverUnix(List<LocalShellOption> shells, Set<String> seen) {
    final paths = <String>{};

    final envShell = Platform.environment['SHELL'];
    if (envShell != null && envShell.isNotEmpty) {
      paths.add(envShell);
    }

    const common = [
      '/bin/zsh',
      '/bin/bash',
      '/usr/bin/zsh',
      '/usr/bin/bash',
      '/usr/local/bin/zsh',
      '/usr/local/bin/bash',
      '/opt/homebrew/bin/zsh',
      '/opt/homebrew/bin/bash',
      '/opt/homebrew/bin/fish',
      '/usr/local/bin/fish',
      '/usr/bin/fish',
      '/bin/fish',
      '/bin/sh',
      '/bin/tcsh',
      '/bin/ksh',
    ];
    paths.addAll(common);

    try {
      final etcShells = File('/etc/shells');
      if (etcShells.existsSync()) {
        for (final line in etcShells.readAsLinesSync()) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          paths.add(trimmed);
        }
      }
    } catch (_) {}

    for (final path in paths) {
      if (!_isUsableUnixShell(path)) continue;
      _addShell(
        shells,
        seen,
        id: 'shell:${_normalizePath(path)}',
        displayName: displayNameFor(path),
        executable: path,
        useUnixWrapper: true,
      );
    }
  }

  static bool _isUsableUnixShell(String path) {
    if (!_fileExists(path)) return false;
    final base = path.split('/').last;
    const blocked = {'nologin', 'false', 'sync', 'halt', 'shutdown'};
    return !blocked.contains(base);
  }

  static void _addShell(
    List<LocalShellOption> shells,
    Set<String> seen, {
    required String id,
    required String displayName,
    required String executable,
    List<String> arguments = const [],
    Map<String, String>? environment,
    bool useUnixWrapper = false,
    bool isWsl = false,
  }) {
    final key = isWsl ? id : _normalizePath(executable);
    if (seen.contains(key)) return;
    if (!_fileExists(executable)) return;
    seen.add(key);

    shells.add(
      LocalShellOption(
        id: id,
        displayName: displayName,
        executable: executable,
        arguments: arguments,
        environment: environment,
        useUnixWrapper: useUnixWrapper,
        isWsl: isWsl,
      ),
    );
  }

  static String displayNameFor(String path, {String? wslDistro}) {
    if (wslDistro != null) return 'WSL $wslDistro';

    final lower = path.toLowerCase();
    if (lower.contains(r'\git\') || lower.contains('/git/')) {
      if (lower.endsWith('bash.exe') || lower.endsWith('/bash')) {
        return 'Git Bash';
      }
    }

    final name = path.split(Platform.pathSeparator).last.toLowerCase();
    return switch (name) {
      'cmd.exe' => 'CMD',
      'powershell.exe' => 'PowerShell',
      'pwsh.exe' => 'PowerShell 7',
      'bash.exe' || 'bash' => 'Bash',
      'zsh' => 'Zsh',
      'fish' => 'Fish',
      'sh' => 'Sh',
      'tcsh' => 'Tcsh',
      'ksh' => 'Ksh',
      'dash' => 'Dash',
      _ => name.replaceAll('.exe', ''),
    };
  }

  static String? _wslExecutable() {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final candidate = '$systemRoot\\System32\\wsl.exe';
    if (_fileExists(candidate)) {
      return candidate;
    }
    try {
      final result = Process.runSync('where', ['wsl.exe'], runInShell: true);
      if (result.exitCode == 0) {
        final line = result.stdout.toString().split('\n').first.trim();
        if (line.isNotEmpty && _fileExists(line)) {
          return line;
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _fileExists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static String _normalizePath(String path) =>
      path.replaceAll('\\', '/').toLowerCase();
}
