import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'ssh_host.dart';
import '../services/sftp_download_worker.dart';

/// 任务的数据流向，用于选择上传或下载实现以及对应的进度处理。
enum TransferType { upload, download }

/// 传输任务生命周期状态。暂停和取消只对运行中的任务有意义；
/// 完成或失败后的状态用于队列展示，不能再恢复传输。
enum TransferStatus { running, paused, done, cancelled, error }

/// 一次上传或下载的可观察模型，持有名称、总量、已传量和状态，
/// 并通过通知驱动队列界面刷新。暂停、继续和取消会转发给对应的活动传输。
class TransferTask extends ChangeNotifier {
  TransferTask._({required this.name, required this.type, required this.total});

  /// 队列中显示的文件名，不保证包含完整本地或远程路径。
  final String name;
  /// 上传或下载方向，决定任务控制和数据通路。
  final TransferType type;
  /// 任务开始时探测到的文件总字节数；未知大小按 0 处理。
  final int total;
  /// 已成功传输的字节数，用于计算进度。
  int bytes = 0;
  /// 当前任务状态；变化时通过 `ChangeNotifier` 通知队列界面。
  TransferStatus status = TransferStatus.running;
  /// 任务失败时用于展示的错误文本，成功或仍在运行时为空。
  String? error;

  /// 上传取消回调；关闭远端句柄由实际上传协程负责收尾。
  Future<void> Function()? _abortUpload;
  /// 上传协程的完成 future，取消任务时等待其完成清理。
  Future<void>? _uploadDone;
  /// 暂停上传时阻塞数据源的门闩，恢复或取消时释放。
  Completer<void>? _uploadResumeGate;
  // Used only by isolated downloads for cancellation.
  /// 下载任务使用的后台 isolate，取消时立即终止。
  Isolate? _downloadIsolate;
  /// 接收后台下载进度、完成和错误消息的端口。
  ReceivePort? _downloadReceivePort;

  /// 上次通知 UI 的时间，用于限制高频进度重绘。
  DateTime? _lastProgressNotify;
  /// 进度通知的最小间隔，避免每个数据块都触发界面重建。
  static const _progressNotifyInterval = Duration(milliseconds: 100);

  /// 是否已释放监听器和后台资源；为 true 后不再派发进度通知。
  bool _disposed = false;
  bool get isActive =>
      status == TransferStatus.running || status == TransferStatus.paused;

  double get progress => total > 0 ? (bytes / total).clamp(0.0, 1.0) : 0.0;

  void pause() {
    if (status != TransferStatus.running) return;
    // SftpFileWriter resumes its own source subscription after every ACK.
    // Pausing that subscription directly is therefore overwritten by the
    // writer while an upload is in flight. Gate the source stream instead.
    _uploadResumeGate ??= Completer<void>();
    status = TransferStatus.paused;
    notifyListeners();
  }

  void resume() {
    if (status != TransferStatus.paused) return;
    status = TransferStatus.running;
    _releaseUploadGate();
    notifyListeners();
  }

  Future<void> cancel() async {
    if (!isActive) return;
    // Publish cancellation before closing the handle so the upload pump
    // cannot enqueue another WRITE while cancellation is in progress.
    status = TransferStatus.cancelled;
    _releaseUploadGate();
    notifyListeners();
    try {
      await _abortUpload?.call();
    } catch (_) {
      // The upload runner still owns final close/delete cleanup.
    }
    await _uploadDone;
    _downloadIsolate?.kill(priority: Isolate.immediate);
    _downloadIsolate = null;
    _downloadReceivePort?.close();
    _downloadReceivePort = null;
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
    if (isActive) {
      status = TransferStatus.cancelled;
      _releaseUploadGate();
      final abortUpload = _abortUpload;
      if (abortUpload != null) {
        unawaited(abortUpload().catchError((_) {}));
      }
    }
    _abortUpload = null;
    _downloadIsolate?.kill(priority: Isolate.immediate);
    _downloadIsolate = null;
    _downloadReceivePort?.close();
    _downloadReceivePort = null;
    super.dispose();
  }

  Future<bool> _waitForUploadResume() async {
    while (status == TransferStatus.paused) {
      final gate = _uploadResumeGate ??= Completer<void>();
      await gate.future;
    }
    return status == TransferStatus.running;
  }

  void _releaseUploadGate() {
    final gate = _uploadResumeGate;
    _uploadResumeGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}

/// 一个 SSH 连接对应的传输队列管理器。它创建任务、限制并发数并转发任务状态；
/// 关闭时应取消/清理由该管理器启动的工作。
class TransferManager extends ChangeNotifier {
  TransferManager({this.sshProfile});

  /// 上传时每次提交给 SFTP writer 的字节块大小。
  static const _uploadWriteChunkSize = 32 * 1024;
  /// 上传最多同时等待确认的写请求数，用于限制内存和远端队列积压。
  static const _uploadMaxPendingWrites = 64;

  /// 下载隔离执行器用于新建独立 SSH 连接的配置；上传仍使用调用方传入的客户端。
  final SshHost? sshProfile;

  /// 当前队列中的任务，最新加入的任务放在列表前端。
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

    final task = TransferTask._(
      name: name,
      type: TransferType.upload,
      total: total,
    );
    _tasks.insert(0, task);
    notifyListeners();

    final uploadDone = _runUpload(task, sftp, localFile, remotePath);
    task._uploadDone = uploadDone;
    unawaited(uploadDone);
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
      throw StateError(
        'TransferManager has no sshProfile; cannot start isolated download',
      );
    }

    final attr = await sftp.stat(remotePath);
    final total = attr.size ?? 0;
    final name = remotePath.split('/').last;

    final task = TransferTask._(
      name: name,
      type: TransferType.download,
      total: total,
    );
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

  Future<void> _runUpload(
    TransferTask task,
    SftpClient sftp,
    File localFile,
    String remotePath,
  ) async {
    final uploadPath = sftpUploadTempPath(remotePath);
    SftpFile? remoteFile;
    var remoteFileClosed = false;
    var remoteFileCreated = false;
    var uploadCommitted = false;

    Future<void> openRemoteFile({required bool exclusive}) async {
      remoteFile = await sftp.open(
        uploadPath,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            (exclusive ? SftpFileOpenMode.exclusive : SftpFileOpenMode.write),
      );
      remoteFileClosed = false;
      remoteFileCreated = true;
    }

    Future<void> closeRemoteFile() async {
      final file = remoteFile;
      if (remoteFileClosed || file == null) return;
      remoteFileClosed = true;
      await file.close();
    }

    try {
      // Upload into a unique sibling file. Exclusive creation means even an
      // extremely unlikely generated-name collision cannot overwrite or later
      // delete a file owned by another transfer.
      await openRemoteFile(exclusive: true);
      if (!task.isActive) {
        await closeRemoteFile();
        return;
      }

      // Keep a bounded pipeline of WRITE requests in flight. Waiting for every
      // 32 KiB block individually limits throughput to roughly 32 KiB / RTT,
      // which is especially painful over long-distance SSH connections.
      //
      // We don't use SftpFileWriter here because its asynchronous stream
      // callbacks don't reliably surface write failures to `done`, and its
      // internal flow-control resume can override a user pause.
      task._abortUpload = closeRemoteFile;
      try {
        await _pumpUploadFile(task, remoteFile!, localFile);
      } on SftpStatusError catch (error) {
        if (error.code != 4 || !task.isActive) rethrow;

        // A few embedded/managed SFTP servers reject concurrent writes to one
        // handle with the generic status code 4. Retry once sequentially so
        // those servers remain compatible while normal servers get pipelining.
        await closeRemoteFile();
        if (!task.isActive) return;
        task._onProgress(0);
        await openRemoteFile(exclusive: false);
        if (!task.isActive) return;
        await _pumpUploadFile(
          task,
          remoteFile!,
          localFile,
          maxPendingWrites: 1,
        );
      }
      // A successful CLOSE response is part of upload completion. If the
      // close fails, report failure and remove only our private temp file.
      await closeRemoteFile();
      if (!task.isActive) return;

      // Standard SFTP v3 rename is the no-replace commit point: readers never
      // observe a partial destination, and an existing same-name file makes
      // this upload fail instead of overwriting another uploader's result.
      await sftp.rename(uploadPath, remotePath);
      uploadCommitted = true;
      if (task.isActive) {
        task._complete();
      }
    } catch (e) {
      task._fail(_uploadErrorMessage(e, remotePath));
    } finally {
      task._abortUpload = null;
      if (!uploadCommitted && remoteFileCreated) {
        await cleanupIncompleteSftpUpload(
          close: closeRemoteFile,
          remove: () => sftp.remove(uploadPath),
        );
      } else {
        try {
          await closeRemoteFile();
        } catch (_) {
          // A successful upload was already closed above. This is normally an
          // idempotent no-op; never replace the transfer's terminal state.
        }
      }
    }
  }

  Future<void> _pumpUploadFile(
    TransferTask task,
    SftpFile remoteFile,
    File localFile, {
    int maxPendingWrites = _uploadMaxPendingWrites,
  }) {
    return pumpSftpUpload(
      source: localFile.openRead(),
      write: (data, offset) => remoteFile.writeBytes(data, offset: offset),
      waitUntilRunnable: task._waitForUploadResume,
      onProgress: task._onProgress,
      chunkSize: _uploadWriteChunkSize,
      maxPendingWrites: maxPendingWrites,
    );
  }

  String _uploadErrorMessage(Object error, String remotePath) {
    if (error is SftpStatusError && error.code == 4) {
      return 'The server rejected the upload to "$remotePath" (SFTP code 4). '
          'The destination may already exist, or the directory may not be '
          'writable. Also check available disk space and quota.';
    }
    return error.toString();
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

/// Returns a private sibling path used to stage one upload before rename.
///
/// The caller must create it with [SftpFileOpenMode.exclusive]. Randomness
/// avoids normal collisions; exclusive creation provides the actual safety
/// guarantee if a collision nevertheless occurs.
@visibleForTesting
/// 根据目标路径生成同目录下的唯一暂存文件名。上传先写入暂存文件，
/// 完成后再重命名为目标路径，避免中断时留下半截正式文件；
/// 测试可注入 nonce 以稳定复现路径。
String sftpUploadTempPath(String remotePath, {String? nonce}) {
  final slash = remotePath.lastIndexOf('/');
  final directory = slash < 0 ? '' : remotePath.substring(0, slash + 1);
  final unique = nonce ?? _newSftpUploadNonce();
  return '$directory.ssterm-upload-$unique.part';
}

String _newSftpUploadNonce() {
  final random = Random.secure();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
      '${random.nextInt(1 << 31).toRadixString(16)}-'
      '${random.nextInt(1 << 31).toRadixString(16)}';
}

/// Sends an upload as a bounded pipeline of SFTP WRITE requests.
///
/// All write futures get an error handler as soon as they are created. This
/// both keeps failures inside the transfer task and lets us safely drain the
/// remaining in-flight requests before the remote handle is closed.
@visibleForTesting
/// 将字节流分块写入已打开的远程文件句柄，并通过回调报告进度。
/// 实现会限制未完成写请求的数量；关闭句柄前需等待在途写入结束，避免传输被截断。
Future<void> pumpSftpUpload({
  required Stream<List<int>> source,
  required Future<void> Function(Uint8List data, int offset) write,
  required Future<bool> Function() waitUntilRunnable,
  required void Function(int bytes) onProgress,
  int chunkSize = 32 * 1024,
  int maxPendingWrites = 64,
}) async {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
  }
  if (maxPendingWrites <= 0) {
    throw ArgumentError.value(
      maxPendingWrites,
      'maxPendingWrites',
      'must be positive',
    );
  }

  final pending = <Future<_UploadWriteResult>>[];
  var nextOffset = 0;
  var bytesAcknowledged = 0;

  Future<void> drainOldest() async {
    final result = await pending.removeAt(0);
    if (result.error != null) {
      // Every pending future is already guarded, so it is safe to wait for the
      // rest before propagating the first failure to the transfer task.
      await Future.wait(pending);
      pending.clear();
      Error.throwWithStackTrace(result.error!, result.stackTrace!);
    }
    bytesAcknowledged += result.length;
    onProgress(bytesAcknowledged);
  }

  await for (final input in source) {
    final data = input is Uint8List ? input : Uint8List.fromList(input);
    for (var start = 0; start < data.length;) {
      if (!await waitUntilRunnable()) {
        await Future.wait(pending);
        return;
      }

      final end = (start + chunkSize).clamp(0, data.length);
      final block = Uint8List.sublistView(data, start, end);
      final offset = nextOffset;
      nextOffset += block.length;
      start = end;

      pending.add(
        write(block, offset).then(
          (_) => _UploadWriteResult.success(block.length),
          onError: (Object error, StackTrace stackTrace) =>
              _UploadWriteResult.failure(block.length, error, stackTrace),
        ),
      );

      if (pending.length >= maxPendingWrites) {
        await drainOldest();
      }
    }
  }

  while (pending.isNotEmpty) {
    await drainOldest();
  }
}

class _UploadWriteResult {
  const _UploadWriteResult.success(this.length)
    : error = null,
      stackTrace = null;

  const _UploadWriteResult.failure(this.length, this.error, this.stackTrace);

  /// 本次写入成功确认的字节数。
  final int length;
  /// 写请求失败时保存的原始异常；成功时为空。
  final Object? error;
  /// 写请求失败时对应的堆栈，用于保留诊断信息。
  final StackTrace? stackTrace;
}

/// Closes an incomplete upload before removing its remote destination.
///
/// Both operations are best-effort because a broken transport can make
/// cleanup impossible. In particular, a close failure must not prevent the
/// subsequent remove attempt or replace the transfer's original error.
@visibleForTesting
/// 在上传失败路径中尽力关闭远程句柄并删除暂存文件。
/// 清理错误不会覆盖原始传输错误，避免掩盖真正失败原因。
Future<void> cleanupIncompleteSftpUpload({
  required Future<void> Function() close,
  required Future<void> Function() remove,
}) async {
  try {
    await close();
  } catch (_) {
    // Continue with removal even when the handle can no longer be closed.
  }
  try {
    await remove();
  } catch (_) {
    // The SFTP connection may already be unavailable.
  }
}
