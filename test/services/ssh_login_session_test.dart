import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:ssterm/models/ssh_host.dart';
import 'package:ssterm/services/ssh_connection.dart';

void main() {
  for (final configuration in [
    (shell: '/bin/zsh', windows: false),
    (shell: '/bin/bash', windows: false),
    if (File('/opt/homebrew/bin/bash').existsSync())
      (shell: '/opt/homebrew/bin/bash', windows: false),
    (shell: '/bin/zsh', windows: true),
  ]) {
    final shell = configuration.shell;
    final windows = configuration.windows;
    test(
      windows
          ? 'Windows SSH identification keeps native shell startup'
          : 'SSH $shell preserves login banner and cwd tracking',
      () async {
        final directory = await Directory.systemTemp.createTemp('ssterm-sshd-');
        addTearDown(() => directory.delete(recursive: true));
        final root = directory.path;
        for (final name in ['host', 'identity']) {
          final keygen = await Process.run('/usr/bin/ssh-keygen', [
            '-q',
            '-t',
            'ed25519',
            '-N',
            '',
            '-f',
            '$root/$name',
          ]);
          expect(keygen.exitCode, 0, reason: '${keygen.stderr}');
        }
        const profile = "PS1='fixture> '\nprintf 'SSTERM_PROFILE_LOADED\\n'\n";
        const promptHook = "printf '\\033]9;fixture-prompt\\007'";
        await File('$root/.zshrc').writeAsString(
          '$profile'
          '[[ -o login ]] || exit 98\n'
          '__fixture_prompt() { $promptHook; }\n'
          'precmd_functions=(__fixture_prompt)\n',
        );
        await File('$root/.bash_profile').writeAsString(
          '$profile'
          'shopt -q login_shell || exit 98\n'
          'PROMPT_COMMAND="$promptHook"\n',
        );
        final child = await Directory('$root/child directory').create();
        final childPath = await child.resolveSymbolicLinks();
        await File('$root/login.sh').writeAsString('''#!/bin/sh
export HOME='$root' ZDOTDIR='$root' SHELL=$shell
if [ -z "\${SSH_ORIGINAL_COMMAND-}" ]; then
  printf 'Welcome to SSTerm login fixture\\n'
  cd "$root"
  exec $shell -il
else
  exec /bin/sh -c "\$SSH_ORIGINAL_COMMAND"
fi
''');
        final chmod = await Process.run('/bin/chmod', [
          '700',
          '$root/login.sh',
        ]);
        expect(chmod.exitCode, 0);
        final listener = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = listener.port;
        await listener.close();
        await File('$root/sshd_config').writeAsString('''
ListenAddress 127.0.0.1
Port $port
HostKey $root/host
PidFile $root/pid
AuthorizedKeysFile $root/identity.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
LogLevel DEBUG3
VersionAddendum ${windows ? 'OpenSSH_for_Windows' : 'ssterm-fixture'}
ForceCommand $root/login.sh
''');
        final daemon = await Process.start('/usr/sbin/sshd', [
          '-D',
          '-e',
          '-f',
          '$root/sshd_config',
        ]);
        final logs = StringBuffer();
        daemon.stdout.transform(utf8.decoder).listen(logs.write);
        daemon.stderr.transform(utf8.decoder).listen(logs.write);
        addTearDown(() async {
          daemon.kill();
          await daemon.exitCode;
        });
        var ready = false;
        for (var attempt = 0; attempt < 100; attempt++) {
          try {
            final socket = await Socket.connect('127.0.0.1', port);
            socket.destroy();
            ready = true;
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        }
        expect(ready, isTrue, reason: '$logs');
        final account = await Process.run('/usr/bin/id', ['-un']);
        final result = await connectSshHost(
          SshHost(
            alias: 'login-fixture',
            hostname: '127.0.0.1',
            port: port,
            user: (account.stdout as String).trim(),
            identityFile: '$root/identity',
          ),
          verifyHostKey: (_, _) async => true,
        );
        addTearDown(result.client.close);
        final session = result.session!;
        final output = StringBuffer();
        final initialCwd = Completer<void>();
        final changedCwd = Completer<void>();
        utf8.decoder.bind(session.stdout).listen((text) {
          output.write(text);
          final changed = windows
              ? output.toString().contains('\r\n$childPath\r\n')
              : output.toString().contains('\x1b]7;file://$childPath\x1b\\') &&
                    output.toString().lastIndexOf('fixture> ') >
                        output.toString().lastIndexOf('\x1b]7;file://');
          if (changed && !changedCwd.isCompleted) {
            changedCwd.complete();
          }
          final ready = windows
              ? output.toString().contains('fixture> ')
              : output.toString().contains('\x1b]7;file://') &&
                    output.toString().lastIndexOf('fixture> ') >
                        output.toString().lastIndexOf('\x1b]7;file://');
          if (ready && !initialCwd.isCompleted) {
            initialCwd.complete();
          }
        });
        await initialCwd.future.timeout(const Duration(seconds: 10));
        expect(output.toString(), contains('Welcome to SSTerm login fixture'));
        expect(output.toString(), isNot(contains('ssterm-start;')));
        final screen = Terminal()..resize(80, 24);
        screen.write(output.toString());
        expect(
          'fixture> '.allMatches(screen.buffer.getText()),
          hasLength(1),
          reason:
              'Initialization must not leave an extra empty prompt: '
              '${screen.buffer.getText()}',
        );
        expect(
          'SSTERM_PROFILE_LOADED'.allMatches(output.toString()),
          hasLength(1),
        );
        // Check actual wire request order: a probe before the shell can consume
        // PAM's one-time login messages even if this fixture has no PAM stack.
        final shellRequest = logs.toString().indexOf('req shell');
        final execRequest = logs.toString().indexOf('req exec');
        expect(shellRequest, isNonNegative);
        expect(execRequest, windows ? -1 : greaterThan(shellRequest));
        if (windows) {
          expect(output.toString(), isNot(contains(']7;file://')));
        }
        session.write(
          utf8.encode("cd '$childPath'\n${windows ? 'pwd\n' : ''}"),
        );
        await changedCwd.future.timeout(const Duration(seconds: 5));
        // Echo must have been restored for normal user input.
        expect(output.toString(), contains("cd '/private/"));
        expect(
          ']9;fixture-prompt'.allMatches(output.toString()).length,
          greaterThanOrEqualTo(2),
        );
        session.write(utf8.encode('exit\n'));
        await session.done.timeout(const Duration(seconds: 5));
      },
      skip: !Platform.isMacOS || !File('/usr/sbin/sshd').existsSync(),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
