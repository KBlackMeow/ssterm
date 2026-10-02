/// `OutputPipe` 的只读诊断快照，用于测试和性能观测。
/// `queuedBytes` 与 `pendingAcceptedBytes` 描述不同阶段的积压；
/// `streamsPaused` 和 `holdOutputUntilRelease` 表示背压是否正在阻止
/// 继续接收或发布输出。

class OutputPipeMetrics {
  const OutputPipeMetrics({
    required this.queuedBytes,
    required this.streamsPaused,
    required this.pendingAcceptedBytes,
    required this.holdOutputUntilRelease,
  });

  final int queuedBytes;
  final bool streamsPaused;
  final int pendingAcceptedBytes;
  final bool holdOutputUntilRelease;
}
