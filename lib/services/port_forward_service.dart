import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models/port_forward_rule.dart';

class PortForwardService {
  final _serverSockets = <ServerSocket>[];
  final _remoteForwards = <SSHRemoteForward>[];
  SSHDynamicForward? _dynamicForward;

  bool get hasActive =>
      _serverSockets.isNotEmpty ||
      _remoteForwards.isNotEmpty ||
      _dynamicForward != null;

  Future<void> startAll(SSHClient client, List<PortForwardRule> rules) async {
    for (final rule in rules) {
      if (!rule.enabled) continue;
      try {
        await _startRule(client, rule);
      } catch (_) {
        // Keep going — don't abort other rules if one fails
      }
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
        if (fwd == null) return;
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
