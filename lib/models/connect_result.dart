import 'package:dartssh2/dartssh2.dart';

import 'ssh_host.dart';

enum ConnectMode { terminal, sftp }

class ConnectResult {
  final SSHClient client;
  final SSHClient? jumpClient;
  final SSHSession? session;
  final SftpClient? sftp;
  final String host;
  final String username;
  final String alias;
  final SshHost profile;
  final ConnectMode mode;

  ConnectResult({
    required this.client,
    this.jumpClient,
    this.session,
    this.sftp,
    required this.host,
    required this.username,
    required this.alias,
    required this.profile,
    required this.mode,
  });
}
