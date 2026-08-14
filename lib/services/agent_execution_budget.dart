/// Limits the work a single user-driven Agent run may consume.
///
/// The panel owns one instance for one run. Callers supply the current time so
/// the policy stays deterministic in tests and never starts a side effect once
/// a limit has been reached.
class AgentExecutionBudget {
  AgentExecutionBudget({
    this.maxModelRequests = 12,
    this.maxShellCalls = 24,
    DateTime? startedAt,
    this.maxElapsed = const Duration(minutes: 12),
  }) : assert(maxModelRequests > 0),
       assert(maxShellCalls > 0),
       assert(!maxElapsed.isNegative),
       _startedAt = startedAt ?? DateTime.now();

  final int maxModelRequests;
  final int maxShellCalls;
  final Duration maxElapsed;
  final DateTime _startedAt;

  int _modelRequests = 0;
  int _shellCalls = 0;

  int get modelRequests => _modelRequests;
  int get shellCalls => _shellCalls;

  AgentBudgetStop? consumeModelRequest(DateTime now) {
    final elapsedStop = _elapsedStop(now);
    if (elapsedStop != null) return elapsedStop;
    if (_modelRequests >= maxModelRequests) {
      return const AgentBudgetStop(AgentBudgetLimit.modelRequests);
    }
    _modelRequests++;
    return null;
  }

  AgentBudgetStop? consumeShellCall(DateTime now) {
    final elapsedStop = _elapsedStop(now);
    if (elapsedStop != null) return elapsedStop;
    if (_shellCalls >= maxShellCalls) {
      return const AgentBudgetStop(AgentBudgetLimit.shellCalls);
    }
    _shellCalls++;
    return null;
  }

  AgentBudgetStop? _elapsedStop(DateTime now) =>
      now.isAfter(_startedAt.add(maxElapsed))
      ? const AgentBudgetStop(AgentBudgetLimit.elapsed)
      : null;
}

enum AgentBudgetLimit { modelRequests, shellCalls, elapsed }

class AgentBudgetStop {
  const AgentBudgetStop(this.limit);

  final AgentBudgetLimit limit;
}
