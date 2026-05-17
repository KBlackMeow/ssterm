import 'dart:io';

class SessionLogger {
  final IOSink _sink;
  final String path;

  SessionLogger._(this._sink, this.path);

  static Future<SessionLogger> create(String alias) async {
    final home = Platform.environment['HOME'] ?? '';
    final dir = Directory('$home/.ssterm/logs');
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
    final sink = File(path).openWrite();
    return SessionLogger._(sink, path);
  }

  void write(List<int> bytes) {
    _sink.add(bytes);
  }

  Future<void> close() => _sink.close();
}
