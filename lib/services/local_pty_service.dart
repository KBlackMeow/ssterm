import 'dart:io';

/// Builds the environment map for a WSL session.
///
/// [systemRoot] is the Windows SystemRoot (e.g. `C:\Windows`).
/// [extras] are optional additional variables merged last (highest priority).
Map<String, String> buildWslEnvironment({
  required String systemRoot,
  Map<String, String>? extras,
}) {
  final env = <String, String>{
    'SSTERM_EXACT_ENV': '1',
    'TERM': 'xterm-256color',
    'COLORTERM': 'truecolor',
    'TERM_PROGRAM': 'ssterm',
    'WSLENV': '',
    'SystemRoot': systemRoot,
    'WINDIR': Platform.environment['WINDIR'] ?? systemRoot,
    'PATH': [
      '$systemRoot\\System32',
      systemRoot,
      '$systemRoot\\System32\\Wbem',
      '$systemRoot\\System32\\WindowsPowerShell\\v1.0',
      if (Platform.environment.containsKey('PATH'))
        Platform.environment['PATH']!,
    ].join(';'),
  };

  for (final key in const [
    'APPDATA',
    'LOCALAPPDATA',
    'ProgramData',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'PUBLIC',
    'TEMP',
    'TMP',
    'USERNAME',
    'USERDOMAIN',
    'USERPROFILE',
  ]) {
    final value = Platform.environment[key];
    if (value != null && value.isNotEmpty) env[key] = value;
  }

  if (extras != null) env.addAll(extras);
  return env;
}

/// Builds the environment map for a Git Bash session.
///
/// [executable] is the full path to the Git Bash executable (used to derive
/// the Git root). [systemRoot] is the Windows SystemRoot.
/// [userProfile] and [extras] are optional.
Map<String, String> buildGitBashEnvironment({
  required String executable,
  required String systemRoot,
  String? userProfile,
  Map<String, String>? extras,
}) {
  final gitRoot = executable
      .replaceFirst(
        RegExp(r'\\usr\\bin\\env\.exe$', caseSensitive: false),
        '',
      )
      .replaceFirst(RegExp(r'\\bin\\bash\.exe$', caseSensitive: false), '');

  final path = [
    if (gitRoot != executable) ...[
      '$gitRoot\\usr\\bin',
      '$gitRoot\\mingw64\\bin',
      '$gitRoot\\bin',
    ],
    '$systemRoot\\System32',
    systemRoot,
    if (Platform.environment.containsKey('PATH'))
      Platform.environment['PATH']!,
  ].join(';');

  final env = <String, String>{
    'TERM': 'xterm-256color',
    'COLORTERM': 'truecolor',
    'TERM_PROGRAM': 'ssterm',
    'SystemRoot': systemRoot,
    'WINDIR': systemRoot,
    'PATH': path,
    'MSYSTEM': 'MINGW64',
    'MSYS': 'enable_pcon winsymlinks:nativestrict',
    'CHERE_INVOKING': '1',
    'SHELL': '/usr/bin/bash',
  };

  final effectiveProfile = userProfile ?? Platform.environment['USERPROFILE'];
  final temp = Platform.environment['TEMP'];
  final tmp = Platform.environment['TMP'];
  final username = Platform.environment['USERNAME'];

  if (username != null) env['USERNAME'] = username;
  if (effectiveProfile != null) {
    env['USERPROFILE'] = effectiveProfile;
    env['HOME'] = effectiveProfile;
  }
  if (temp != null) env['TEMP'] = temp;
  if (tmp != null) env['TMP'] = tmp;

  if (extras != null) {
    env.addAll(extras);
    env['SHELL'] = '/usr/bin/bash'; // always win after extras
  }
  return env;
}

/// Builds the environment map for a standard (non-WSL, non-Git-Bash) local shell.
///
/// Starts from [base] (defaults to [Platform.environment]) and overlays the
/// required TERM variables plus any [extras].
Map<String, String> buildLocalShellEnvironment({
  Map<String, String>? base,
  Map<String, String>? extras,
}) {
  final env = Map<String, String>.from(base ?? Platform.environment)
    ..['TERM'] = 'xterm-256color'
    ..['COLORTERM'] = 'truecolor'
    ..['TERM_PROGRAM'] = 'ssterm';

  if (extras != null) env.addAll(extras);
  return env;
}
