import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models/port_forward_rule.dart';

class PortForwardException implements Exception {
  PortForwardException(this.failures);

  final List<String> failures;

  @override
  String toString() => failures.join('; ');
}

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
