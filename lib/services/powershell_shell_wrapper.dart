/// Returns a PowerShell script that wires up OSC 133 (shell-integration /
/// command-boundary markers) and OSC 7 (working-directory reporting) for a
/// native Windows PowerShell or PowerShell 7 session — the PowerShell
/// counterpart of `local_shell_wrapper.dart`'s POSIX bash/zsh wrapper.
///
/// OSC 133 is the same protocol used by iTerm2, VS Code, Warp, and Zed —
/// `OSC 133;C` marks the start of a command's output, `OSC 133;D;<exit_code>`
/// marks the end. The agent loop relies on these markers to capture the
/// exact bytes a command produced, plus its exit code.
///
/// PowerShell has no built-in preexec/precmd hook mechanism (unlike zsh's
/// `precmd_functions`/`preexec_functions` or bash's `PROMPT_COMMAND`/`PS0`),
/// so this uses the two hooks the ecosystem (VS Code's shell integration,
/// prompt frameworks like oh-my-posh/posh-git) already relies on:
///   - a PSReadLine `Enter` key handler fires right before a submitted line
///     is accepted, giving us the command-start (`C`) marker;
///   - an overridden `prompt` function fires right before the next prompt is
///     rendered — i.e. right after the previous command finished — giving us
///     the command-end (`D`) marker plus the exit code and cwd.
///
/// Delivered via `-EncodedCommand` (base64 UTF-16LE, see
/// `encodePowerShellCommand` in `../utils/windows_powershell.dart`) rather
/// than an on-disk `.ps1` file, so it runs regardless of the user's
/// execution policy (`Restricted`/`AllSigned` would otherwise block a
/// script file). No `-NoProfile` is used when launching PowerShell with this
/// prelude, so the user's own `$PROFILE` loads first — which is exactly why
/// both hooks below chain to whatever was already bound rather than
/// clobbering it.
String buildPowerShellOsc133Prelude() => r'''
$script:SstmOsc133Enabled = $false

function global:__sstm_emit_c {
  [Console]::Out.Write([char]27 + ']133;C' + [char]7)
}

# --- Enter-key hook: command-start marker -----------------------------------
# Wrapped in one broad try/catch: PSReadLine missing, too old (pre-`Chord`
# API), or locked down all degrade silently to "no C marker" rather than
# erroring out the whole session. When that happens `$script:SstmOsc133Enabled`
# stays false, which gates the `D` emission below too — a lone `D` with no
# matching `C` would permanently flip the output pipe's `hasOsc133` flag,
# routing every future command into the OSC133 capture path even though `C`
# will never arrive, which is strictly worse than today's echo-sentinel
# fallback. So: both markers activate together, or neither does.
try {
  if (Get-Module -ListAvailable -Name PSReadLine) {
    Import-Module PSReadLine -ErrorAction Stop
  }

  # Chain to whatever Enter was already bound to (a user's own $PROFILE may
  # have remapped it) rather than clobbering it. Get-PSReadLineKeyHandler
  # only exposes a `Function` label for the binding, not an invokable
  # reference — when it's a named built-in (the common case), we can look it
  # up by name via PSConsoleReadLine's static method; when it's a custom
  # scriptblock, there's no public API to retrieve it, so we fall back to
  # AcceptLine (this replaces that specific custom Enter behavior for the
  # session — a known, disclosed limitation, not an oversight).
  $sstmPrevEnter = Get-PSReadLineKeyHandler -ErrorAction Stop |
    Where-Object { $_.Key -eq 'Enter' } |
    Select-Object -First 1
  $global:SstmPrevEnterFn = if ($sstmPrevEnter) { $sstmPrevEnter.Function } else { 'AcceptLine' }

  Set-PSReadLineKeyHandler -Chord Enter -ScriptBlock {
    param($key, $arg)
    __sstm_emit_c
    try {
      [Microsoft.PowerShell.PSConsoleReadLine]::$($global:SstmPrevEnterFn).Invoke($key, $arg)
    } catch {
      [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
    }
  } -ErrorAction Stop

  $script:SstmOsc133Enabled = $true
} catch {
  # See note above — degrade to no OSC133 at all; the prompt override below
  # still installs (guarded separately) for OSC7 cwd tracking only.
}

# --- prompt hook: command-end marker + cwd ----------------------------------
$script:SstmPrevPrompt = if (Test-Path Function:\prompt) { $function:prompt } else { $null }

function global:prompt {
  # Capture status FIRST: anything evaluated below (including invoking the
  # previous prompt function) would overwrite $?/$LASTEXITCODE before we
  # read them.
  $sstmSuccess = $?
  $sstmLastExit = $global:LASTEXITCODE

  if ($script:SstmOsc133Enabled) {
    # Unified exit-code idiom (same pattern prompt frameworks use to unify
    # cmdlet vs. native-exe exit semantics): trust $? first; only fall back
    # to $LASTEXITCODE on failure, and only when it's actually an [int] --
    # it's $null until the first native exe ever runs, and a successful
    # cmdlet never resets it, so a stale nonzero value from an earlier
    # command must not be misreported as the current command's exit code.
    $sstmCode = 0
    if (-not $sstmSuccess) {
      $sstmCode = if ($sstmLastExit -is [int] -and $sstmLastExit -ne 0) { $sstmLastExit } else { 1 }
    } elseif ($sstmLastExit -is [int]) {
      $sstmCode = $sstmLastExit
    }
    [Console]::Out.Write([char]27 + ']133;D;' + $sstmCode + [char]7)
  }

  # Triple slash is load-bearing: RemoteCwdParser's `file://<host>/<path>`
  # matcher treats everything up to the first `/` as the host, so a
  # two-slash `file://C:/Users/foo` would swallow the drive letter into the
  # (discarded) host component. `file:///C:/Users/foo` gives an empty host
  # and keeps the drive letter in the captured path.
  $sstmCwd = $PWD.ProviderPath -replace '\\', '/'
  [Console]::Out.Write([char]27 + ']7;file:///' + $sstmCwd + [char]27 + '\')

  if ($script:SstmPrevPrompt) { & $script:SstmPrevPrompt } else { "PS $($PWD.Path)> " }
}
''';
