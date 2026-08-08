# Agent2 Login Shell Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local macOS/Linux Agent2 background commands inherit the user's login-shell PATH without using a persistent terminal session.

**Architecture:** A focused resolver launches the selected POSIX shell once in login mode, reads a NUL-delimited PATH, validates it, and memoizes the result by shell executable. The background executor obtains that override before spawning each independent command; all Windows variants and SSH retain their existing execution routes.

**Tech Stack:** Dart, Flutter test, `dart:io` Process APIs.

## Global Constraints

- Affect only local macOS/Linux Agent2 background execution.
- Cache only PATH in memory; never write it to history, ordinary logs, or disk.
- Every Agent2 command remains a bounded, cancellable independent child process.
- Resolver failure, invalid data, or timeout must fall back to the inherited application environment.
- Do not apply login-shell resolution to SSH, Windows, WSL, or Git Bash.

---

### Task 1: Add an isolated login-shell PATH resolver

**Files:**
- Create: `lib/services/login_shell_environment.dart`
- Create: `test/services/login_shell_environment_test.dart`

**Interfaces:**
- Produces: `typedef LoginShellPathReader = Future<ProcessResult> Function(String executable, List<String> arguments);`
- Produces: `class LoginShellEnvironmentResolver` with `Future<Map<String, String>> resolvePath(LocalShellOption shell)`.
- Consumes: `LocalShellOption` from `lib/services/local_shell_discovery.dart`.

- [ ] **Step 1: Write the failing resolver tests**

```dart
test('reads and caches a NUL-terminated PATH for a shell', () async {
  var calls = 0;
  final resolver = LoginShellEnvironmentResolver(
    run: (executable, arguments) async {
      calls++;
      expect(executable, '/bin/zsh');
      expect(arguments, ['-l', '-c', 'printf "%s\\0" "$PATH"']);
      return ProcessResult(1, 0, '/opt/homebrew/bin:/usr/bin\u0000', '');
    },
  );
  const shell = LocalShellOption(id: 'zsh', displayName: 'Zsh', executable: '/bin/zsh');
  expect(await resolver.resolvePath(shell), {'PATH': '/opt/homebrew/bin:/usr/bin'});
  await resolver.resolvePath(shell);
  expect(calls, 1);
});
```

Add separate tests for non-zero exit, missing NUL terminator, empty PATH, and `TimeoutException`; each expects `const {}`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/login_shell_environment_test.dart`

Expected: compile failure because `LoginShellEnvironmentResolver` does not exist.

- [ ] **Step 3: Implement the resolver**

```dart
typedef LoginShellPathReader = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class LoginShellEnvironmentResolver {
  LoginShellEnvironmentResolver({
    LoginShellPathReader? run,
    this.timeout = const Duration(seconds: 3),
  }) : _run = run ?? ((executable, arguments) => Process.run(executable, arguments));

  final LoginShellPathReader _run;
  final Duration timeout;
  final Map<String, Future<Map<String, String>>> _cache = {};

  Future<Map<String, String>> resolvePath(LocalShellOption shell) =>
      _cache.putIfAbsent(shell.executable, () => _resolve(shell));
}
```

Use `<shell> -l -c 'printf "%s\\0" "$PATH"'`. The private resolution method applies the timeout, accepts exactly one nonempty NUL-terminated PATH value, and returns `const {}` on all failures. Do not log stdout, stderr, or PATH.

- [ ] **Step 4: Run resolver tests**

Run: `flutter test test/services/login_shell_environment_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/login_shell_environment.dart test/services/login_shell_environment_test.dart
git commit -m "feat: resolve login shell path for agent2"
```

### Task 2: Apply the cached PATH to POSIX background commands

**Files:**
- Modify: `lib/services/background_command_executor.dart:104-160`
- Modify: `test/services/background_command_executor_test.dart`

**Interfaces:**
- Consumes: `LoginShellEnvironmentResolver.resolvePath(LocalShellOption)` from Task 1.
- Produces: `BackgroundCommandExecutor` constructor accepting an optional `LoginShellEnvironmentResolver`.

- [ ] **Step 1: Write failing executor tests**

```dart
test('merges the resolved login PATH for a POSIX command', () async {
  // Inject a resolver that returns PATH=/opt/homebrew/bin:/usr/bin and a
  // process-start seam; assert the final environment uses that PATH.
});

test('does not resolve a login PATH for a Windows target', () async {
  // Inject a counting resolver and assert it is never called.
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/background_command_executor_test.dart`

Expected: FAIL because the executor has no resolver dependency and POSIX process environments are unchanged.

- [ ] **Step 3: Implement the executor integration**

```dart
class BackgroundCommandExecutor {
  BackgroundCommandExecutor({
    this.timeout = const Duration(seconds: 120),
    this.outputLimitBytes = 256 * 1024,
    LoginShellEnvironmentResolver? loginEnvironmentResolver,
  }) : _loginEnvironmentResolver =
           loginEnvironmentResolver ?? LoginShellEnvironmentResolver();

  final LoginShellEnvironmentResolver _loginEnvironmentResolver;
}
```

Immediately before `Process.start`, call the resolver only when `target.platform` is macOS or Linux, merge its result after `_nonInteractiveEnvironment`, and retain the existing TERM/COLORTERM stripping. Check cancellation again after awaiting resolution; if cancelled, return the normal cancelled result without starting a process.

- [ ] **Step 4: Run focused regression tests**

Run: `flutter test test/services/background_command_executor_test.dart test/services/login_shell_environment_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/background_command_executor.dart test/services/background_command_executor_test.dart
git commit -m "feat: apply login shell path to agent2 commands"
```

### Task 3: Verify supported-shell behavior and full regression suite

**Files:**
- Modify: `test/services/login_shell_environment_test.dart`

**Interfaces:**
- Consumes: completed resolver and executor integration from Tasks 1-2.

- [ ] **Step 1: Add a real-host guarded integration test**

```dart
test('zsh login environment exposes Homebrew when installed', () async {
  if (!Platform.isMacOS || !File('/opt/homebrew/bin/brew').existsSync()) return;
  const shell = LocalShellOption(id: 'zsh', displayName: 'Zsh', executable: '/bin/zsh');
  final environment = await LoginShellEnvironmentResolver().resolvePath(shell);
  expect(environment['PATH'], contains('/opt/homebrew/bin'));
});
```

- [ ] **Step 2: Run focused and complete tests**

Run: `flutter test test/services/login_shell_environment_test.dart test/services/background_command_executor_test.dart && flutter test`

Expected: all tests pass; platform-guarded integration test may be skipped when Homebrew is absent.

- [ ] **Step 3: Run static analysis and diff validation**

Run: `dart format lib/services/login_shell_environment.dart test/services/login_shell_environment_test.dart lib/services/background_command_executor.dart test/services/background_command_executor_test.dart && git diff --check && flutter analyze`

Expected: no analyzer errors; report any pre-existing warnings separately.

- [ ] **Step 4: Commit final test coverage**

```bash
git add test/services/login_shell_environment_test.dart
git commit -m "test: cover agent2 login shell environment"
```

