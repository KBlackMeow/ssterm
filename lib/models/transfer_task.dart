import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'ssh_host.dart';
import '../services/sftp_download_worker.dart';

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
  // Used only by isolated downloads for cancellation.
  Isolate? _downloadIsolate;
  ReceivePort? _downloadReceivePort;

  DateTime? _lastProgressNotify;
  static const _progressNotifyInterval = Duration(milliseconds: 100);

  bool _disposed = false;
  bool get isActive =>
      status == TransferStatus.running || status == TransferStatus.paused;

  double get progress => total > 0 ? (bytes / total).clamp(0.0, 1.0) : 0.0;

  void pause() {
    if (status != TransferStatus.running) return;
    _writer?.pause();
    status = TransferStatus.paused;
    notifyListeners();
  }

  void resume() {
    if (status != TransferStatus.paused) return;
    _writer?.resume();
    status = TransferStatus.running;
    notifyListeners();
  }

  Future<void> cancel() async {
    if (!isActive) return;
    await _writer?.abort();
    _downloadIsolate?.kill(priority: Isolate.immediate);
    _downloadIsolate = null;
    _downloadReceivePort?.close();
    _downloadReceivePort = null;
    status = TransferStatus.cancelled;
    notifyListeners();
  }

  void _onProgress(int b) {
    if (_disposed) return;
    bytes = b;
    final now = DateTime.now();
    if (_lastProgressNotify != null &&
        now.difference(_lastProgressNotify!) < _progressNotifyInterval) {
      return;
    }
    _lastProgressNotify = now;
    notifyListeners();
  }

  void _complete() {
    if (_disposed || !isActive) return;
    status = TransferStatus.done;
    notifyListeners();
  }

  void _fail(dynamic e) {
    if (_disposed || !isActive) return;
    status = TransferStatus.error;
    error = e.toString();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_writer?.abort());
    _writer = null;
    _downloadIsolate?.kill(priority: Isolate.immediate);
    _downloadIsolate = null;
    _downloadReceivePort?.close();
    _downloadReceivePort = null;
    super.dispose();
  }
}

class TransferManager extends ChangeNotifier {
  TransferManager({this.sshProfile});

  /// SSH credentials used to open a dedicated download connection in an
  /// isolate, keeping the main isolate free for Flutter rendering.
  final SshHost? sshProfile;

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

  /// Stat the remote file and enqueue a download task.
  /// The actual transfer runs in a background [Isolate] so the main isolate
  /// (and Flutter's rendering) is unaffected by SSH crypto overhead.
  Future<TransferTask> startDownload({
    required SftpClient sftp,
    required String remotePath,
    required String localPath,
  }) async {
    final profile = sshProfile;
    if (profile == null) {
      throw StateError('TransferManager has no sshProfile; cannot start isolated download');
    }

    final attr = await sftp.stat(remotePath);
    final total = attr.size ?? 0;
    final name = remotePath.split('/').last;

    final task = TransferTask._(name: name, type: TransferType.download, total: total);
    _tasks.insert(0, task);
    notifyListeners();

    unawaited(_runIsolatedDownload(task, profile, remotePath, localPath));
    return task;
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

  Future<void> _runIsolatedDownload(
    TransferTask task,
    SshHost profile,
    String remotePath,
    String localPath,
  ) async {
    final receivePort = ReceivePort();

    Isolate isolate;
    try {
      isolate = await Isolate.spawn<SftpDownloadArgs>(
        sftpDownloadMain,
        SftpDownloadArgs(
          host: profile,
          remotePath: remotePath,
          localPath: localPath,
          replyPort: receivePort.sendPort,
        ),
        errorsAreFatal: false,
      );
    } catch (e) {
      receivePort.close();
      task._fail(e);
      return;
    }

    task._downloadIsolate = isolate;
    task._downloadReceivePort = receivePort;

    await for (final msg in receivePort) {
      if (!task.isActive) {
        // Cancelled while a message was in flight — clean up.
        isolate.kill(priority: Isolate.immediate);
        receivePort.close();
        return;
      }
      if (msg is int) {
        task._onProgress(msg);
      } else if (msg == null) {
        receivePort.close();
        task._downloadIsolate = null;
        task._downloadReceivePort = null;
        task._complete();
        return;
      } else if (msg is String) {
        receivePort.close();
        task._downloadIsolate = null;
        task._downloadReceivePort = null;
        task._fail(msg);
        return;
      }
    }
  }

  @override
  void dispose() {
    for (final t in _tasks) {
      t.dispose();
    }
    _tasks.clear();
    super.dispose();
  }
}
