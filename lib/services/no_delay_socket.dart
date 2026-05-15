import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Disables Nagle's algorithm so each keypress is sent immediately.
class NoDelaySocket implements SSHSocket {
  NoDelaySocket._(this._socket);

  final Socket _socket;

  static Future<NoDelaySocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.setOption(SocketOption.tcpNoDelay, true);
    return NoDelaySocket._(s);
  }

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();
}
