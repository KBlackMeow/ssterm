/// Limits the work a single user-driven Agent run may consume.
///
/// The panel owns one instance for one run. Callers supply the current time so
/// the policy stays deterministic in tests and never starts a side effect once
/// a limit has been reached.
class AgentExecutionBudget {
  AgentExecutionBudget({
    this.maxModelRequests,
    this.maxShellCalls,
    DateTime? startedAt,
    this.maxElapsed,
  }) : assert(maxModelRequests == null || maxModelRequests > 0),
       assert(maxShellCalls == null || maxShellCalls > 0),
       assert(maxElapsed == null || !maxElapsed.isNegative),
       _startedAt = startedAt ?? DateTime.now();

  /// Null disables the corresponding budget limit.
  final int? maxModelRequests;
  final int? maxShellCalls;
  final Duration? maxElapsed;
  final DateTime _startedAt;

  int _modelRequests = 0;
  int _shellCalls = 0;

  int get modelRequests => _modelRequests;
  int get shellCalls => _shellCalls;

  AgentBudgetStop? consumeModelRequest(DateTime now) {
    final elapsedStop = _elapsedStop(now);
    if (elapsedStop != null) return elapsedStop;
    if (maxModelRequests != null && _modelRequests >= maxModelRequests!) {
      return const AgentBudgetStop(AgentBudgetLimit.modelRequests);
    }
    _modelRequests++;
    return null;
  }

  AgentBudgetStop? consumeShellCall(DateTime now) {
    final elapsedStop = _elapsedStop(now);
    if (elapsedStop != null) return elapsedStop;
    if (maxShellCalls != null && _shellCalls >= maxShellCalls!) {
      return const AgentBudgetStop(AgentBudgetLimit.shellCalls);
    }
    _shellCalls++;
    return null;
  }

  AgentBudgetStop? _elapsedStop(DateTime now) =>
      maxElapsed != null && now.isAfter(_startedAt.add(maxElapsed!))
      ? const AgentBudgetStop(AgentBudgetLimit.elapsed)
      : null;
}

/// Agent 执行预算中可触发停止的上限类别，分别限制模型请求数、Shell
/// 调用数和总执行时长。
enum AgentBudgetLimit { modelRequests, shellCalls, elapsed }

/// 执行达到预算上限时携带的停止原因。调用方可据此显示具体限制并决定是否将停止状
/// 态写入会话记录。
class AgentBudgetStop {
  const AgentBudgetStop(this.limit);

  final AgentBudgetLimit limit;
}
