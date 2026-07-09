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
