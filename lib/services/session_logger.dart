import 'dart:io';

import 'package:ssterm/io/output_pipe.dart';

import '../utils/app_dir.dart';

class SessionLogger implements LogSink {
  final IOSink _sink;
  final String path;

  SessionLogger._(this._sink, this.path);

  static Future<SessionLogger> create(String alias) async {
    final base = await appDataDir();
    final dir = Directory('${base.path}/logs');
    if (!await dir.exists()) await dir.create(recursive: true);

    final safe = alias.replaceAll(RegExp(r'[^\w\-.]'), '_');
    final now = DateTime.now();
    final ts =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '_${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final path = '${dir.path}/${safe}_$ts.log';
    final file = File(path);
    final sink = file.openWrite();
    // Restrict log file so other local users cannot read terminal output (POSIX only).
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', path]);
    }
    return SessionLogger._(sink, path);
  }

  @override
  void write(List<int> bytes) {
    _sink.add(bytes);
  }

  @override
  Future<void> close() => _sink.close();
}
