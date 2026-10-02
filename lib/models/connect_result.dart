/// SSH 握手和认证完成后交给标签层的资源包。`mode` 决定是否创建交互终端或 SFTP
/// 客户端；使用完毕后资源由接收它的标签生命周期关闭。

import 'package:dartssh2/dartssh2.dart';

import 'ssh_host.dart';

/// 指定连接流程需要建立的 SSH 资源：`terminal` 打开交互会话，`sftp`
/// 建立文件传输通道。
enum ConnectMode { terminal, sftp }

/// SSH 连接操作的完整返回值，包含主连接、可选跳板连接、会话/SFTP
/// 通道以及用于展示和重连的主机信息。字段是否为空取决于 `mode`。
class ConnectResult {
  /// 到目标 SSH 主机的已认证客户端；拥有者负责最终关闭。
  final SSHClient client;
  /// 连接经过跳板机时使用的中间客户端；直连时为空。
  final SSHClient? jumpClient;
  /// 交互终端模式下打开的 Shell 会话；SFTP 模式下为空。
  final SSHSession? session;
  /// SFTP 模式下打开的文件传输客户端；不需要 SFTP 时为空。
  final SftpClient? sftp;
  /// 实际连接的主机名，供标签标题和诊断信息使用。
  final String host;
  /// 建立连接时使用的登录账号。
  final String username;
  /// 用户配置的主机别名，用于标签和连接列表展示。
  final String alias;
  /// 建立本次连接时使用的配置快照，供重连沿用。
  final SshHost profile;
  /// 本次连接创建的资源种类，决定 `session` / `sftp` 哪个字段有效。
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
