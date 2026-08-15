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

enum AgentBudgetLimit { modelRequests, shellCalls, elapsed }

class AgentBudgetStop {
  const AgentBudgetStop(this.limit);

  final AgentBudgetLimit limit;
}
