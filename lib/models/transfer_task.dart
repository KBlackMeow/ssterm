import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

enum TransferType { upload, download }

enum TransferStatus { running, paused, done, cancelled, error }

class TransferTask extends ChangeNotifier {
  TransferTask._({
    required this.name,
    required this.type,
    required this.total,
  });

  final String name;
  final TransferType type;
  final int total;
  int bytes = 0;
  TransferStatus status = TransferStatus.running;
  String? error;

  SftpFileWriter? _writer;
  StreamSubscription<Uint8List>? _downloadSub;

  bool get isActive =>
      status == TransferStatus.running || status == TransferStatus.paused;

  double get progress => total > 0 ? (bytes / total).clamp(0.0, 1.0) : 0.0;

  void pause() {
    if (status != TransferStatus.running) return;
    _writer?.pause();
    _downloadSub?.pause();
    status = TransferStatus.paused;
    notifyListeners();
  }

  void resume() {
    if (status != TransferStatus.paused) return;
    _writer?.resume();
    _downloadSub?.resume();
    status = TransferStatus.running;
    notifyListeners();
  }

  Future<void> cancel() async {
    if (!isActive) return;
    await _downloadSub?.cancel();
    await _writer?.abort();
    status = TransferStatus.cancelled;
    notifyListeners();
  }

  void _onProgress(int b) {
    bytes = b;
    notifyListeners();
  }

  void _complete() {
    if (!isActive) return;
    status = TransferStatus.done;
    notifyListeners();
  }

  void _fail(dynamic e) {
    if (!isActive) return;
    status = TransferStatus.error;
    error = e.toString();
    notifyListeners();
  }
}

class TransferManager extends ChangeNotifier {
  final _tasks = <TransferTask>[];

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  int get activeCount => _tasks.where((t) => t.isActive).length;

  /// Stat the file and enqueue an upload task. Throws on pre-flight error.
  Future<TransferTask> startUpload({
    required SftpClient sftp,
    required String localPath,
    required String remotePath,
  }) async {
    final localFile = File(localPath);
    final total = await localFile.length();
    final name = localPath.split(Platform.pathSeparator).last;

    final task = TransferTask._(name: name, type: TransferType.upload, total: total);
    _tasks.insert(0, task);
    notifyListeners();

    _runUpload(task, sftp, localFile, remotePath);
    return task;
  }

  /// Stat the remote file and enqueue a download task. Throws on pre-flight error.
  Future<void> startDownload({
    required SftpClient sftp,
    required String remotePath,
    required String localPath,
  }) async {
    final attr = await sftp.stat(remotePath);
    final total = attr.size ?? 0;
    final name = remotePath.split('/').last;

    final task = TransferTask._(name: name, type: TransferType.download, total: total);
    _tasks.insert(0, task);
    notifyListeners();

    _runDownload(task, sftp, remotePath, localPath, total);
  }

  void remove(TransferTask task) {
    _tasks.remove(task);
    task.dispose();
    notifyListeners();
  }

  void clearDone() {
    final done = _tasks.where((t) => !t.isActive).toList();
    for (final t in done) {
      _tasks.remove(t);
      t.dispose();
    }
    notifyListeners();
  }

  void _runUpload(
    TransferTask task,
    SftpClient sftp,
    File localFile,
    String remotePath,
  ) async {
    try {
      final remoteFile = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      final stream = localFile.openRead().map(Uint8List.fromList);
      final writer = remoteFile.write(stream, onProgress: task._onProgress);
      task._writer = writer;
      await writer.done;
      await remoteFile.close();
      task._complete();
    } catch (e) {
      task._fail(e);
    }
  }

  void _runDownload(
    TransferTask task,
    SftpClient sftp,
    String remotePath,
    String localPath,
    int total,
  ) async {
    IOSink? sink;
    try {
      final remoteFile = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
      sink = File(localPath).openWrite();

      int received = 0;
      final completer = Completer<void>();

      final sub = remoteFile
          .read(length: total > 0 ? total : null)
          .cast<Uint8List>()
          .listen(
        (chunk) {
          sink!.add(chunk);
          received += chunk.length;
          task._onProgress(received);
        },
        onDone: () async {
          await sink?.flush();
          await sink?.close();
          await remoteFile.close();
          task._complete();
          if (!completer.isCompleted) completer.complete();
        },
        onError: (e) {
          task._fail(e);
          if (!completer.isCompleted) completer.completeError(e);
        },
        cancelOnError: true,
      );

      task._downloadSub = sub;
      // If cancelled before the subscription was assigned, honour it now
      if (!task.isActive) await sub.cancel();

      await completer.future.catchError((_) {});
    } catch (e) {
      await sink?.close();
      task._fail(e);
    }
  }

  @override
  void dispose() {
    for (final t in _tasks) {
      t.dispose();
    }
    super.dispose();
  }
}
