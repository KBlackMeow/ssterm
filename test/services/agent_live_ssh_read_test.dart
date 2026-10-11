import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/connect_result.dart';
import 'package:ssterm/models/ssh_host.dart';
import 'package:ssterm/services/agent_output_store.dart';
import 'package:ssterm/services/agent_read_tools.dart';
import 'package:ssterm/services/file_write_service.dart';
import 'package:ssterm/services/ssh_connection.dart';

/// Exercises SSTerm's actual SFTP file adapter against a disposable fixture.
/// Enable only when all `SSTERM_LIVE_SSH_*` variables are supplied.
void main() {
  test(
    'live SSH bounded reads find fixture markers',
    () async {
      final host = Platform.environment['SSTERM_LIVE_SSH_HOST']!;
      final user = Platform.environment['SSTERM_LIVE_SSH_USER']!;
      final path = Platform.environment['SSTERM_LIVE_SSH_FIXTURE']!;
      final port = int.parse(Platform.environment['SSTERM_LIVE_SSH_PORT']!);
      final result = await connectSshHost(
        SshHost(alias: 'live-eval', hostname: host, port: port, user: user),
        mode: ConnectMode.sftp,
        // SSH CLI has already verified this host for the explicitly supplied
        // test profile. The production UI uses its persistent verifier.
        verifyHostKey: (_, _) async => true,
      );
      addTearDown(() => result.client.close());
      final adapter = SftpFileSystemAdapter(
        sftp: result.sftp,
        label: 'ssh: live-eval',
      );
      final reads = AgentReadTools(
        outputStore: AgentOutputStore(
          directory: Directory.systemTemp,
          sessionId: 'live-ssh-eval',
        ),
        fileSystem: adapter,
      );

      final alpha = await reads.execute('read_file', {
        'path': '$path/notes/alpha.txt',
        'offset': 0,
        'max_bytes': 8192,
      });
      expect(alpha.isError, isFalse);
      expect(alpha.content, contains('ORCHID-42'));

      final huge = await reads.execute('read_file', {
        'path': '$path/large/huge.txt',
        'offset': 5599900,
        'max_bytes': 8192,
      });
      expect(huge.isError, isFalse);
      expect(huge.content, contains('HORIZON-88'));
    },
    skip:
        Platform.environment['SSTERM_LIVE_SSH_HOST'] == null ||
        Platform.environment['SSTERM_LIVE_SSH_USER'] == null ||
        Platform.environment['SSTERM_LIVE_SSH_PORT'] == null ||
        Platform.environment['SSTERM_LIVE_SSH_FIXTURE'] == null,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
