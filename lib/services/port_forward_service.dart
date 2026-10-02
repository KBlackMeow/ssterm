/// 根据主机配置启动并释放 SSH 端口转发。启动失败会逐条收集错误，
/// 调用方可选择在保留其他成功转发的同时向用户报告失败项。

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models/port_forward_rule.dart';

/// 启动一组转发规则后仍有规则失败时抛出的聚合异常；`failures`
/// 按规则保留各自错误，便于界面逐项显示。
class PortForwardException implements Exception {
  PortForwardException(this.failures);

  final List<String> failures;

  @override
  String toString() => failures.join('; ');
}

/// 持有当前连接启动的本地监听 socket、远程转发和 SOCKS5 转发。
/// `startAll` 会尝试所有启用规则；停止或释放服务时关闭已建立的转发资源。
class PortForwardService {
  final _serverSockets = <ServerSocket>[];
  final _remoteForwards = <SSHRemoteForward>[];
  SSHDynamicForward? _dynamicForward;

  bool get hasActive =>
      _serverSockets.isNotEmpty ||
      _remoteForwards.isNotEmpty ||
      _dynamicForward != null;

  Future<void> startAll(SSHClient client, List<PortForwardRule> rules) async {
    final failures = <String>[];
    for (final rule in rules) {
      if (!rule.enabled) continue;
      try {
        await _startRule(client, rule);
      } catch (e) {
        failures.add('${rule.label}: $e');
      }
    }
    if (failures.isNotEmpty) {
      throw PortForwardException(failures);
    }
  }

  Future<void> _startRule(SSHClient client, PortForwardRule rule) async {
    switch (rule.type) {
      case ForwardType.local:
        final server = await ServerSocket.bind('127.0.0.1', rule.localPort);
        _serverSockets.add(server);
        server.listen((socket) async {
          try {
            final channel = await client.forwardLocal(
              rule.remoteHost,
              rule.remotePort,
            );
            socket.cast<List<int>>().pipe(channel.sink);
            channel.stream.cast<List<int>>().pipe(socket);
          } catch (_) {
            socket.destroy();
          }
        });

      case ForwardType.remote:
        final fwd = await client.forwardRemote(port: rule.remotePort);
        if (fwd == null) {
          throw StateError('remote forwarding was rejected by the SSH server');
        }
        _remoteForwards.add(fwd);
        fwd.connections.listen((channel) async {
          try {
            final local = await Socket.connect('127.0.0.1', rule.localPort);
            channel.stream.cast<List<int>>().pipe(local);
            local.cast<List<int>>().pipe(channel.sink);
          } catch (_) {
            channel.sink.close();
          }
        });

      case ForwardType.dynamic_:
        _dynamicForward = await client.forwardDynamic(
          bindHost: '127.0.0.1',
          bindPort: rule.localPort,
        );
    }
  }

  Future<void> stopAll() async {
    for (final s in _serverSockets) {
      await s.close();
    }
    _serverSockets.clear();

    for (final fwd in _remoteForwards) {
      fwd.close();
    }
    _remoteForwards.clear();

    await _dynamicForward?.close();
    _dynamicForward = null;
  }
}
