---
name: verify-fix
description: Force a self-skeptical re-check after the agent claims a fix worked — re-run the original failing reproducer and compare actual output to the expected outcome.
when_to_use: the user asks "are you sure it works?", "verify the fix", or "did that actually work?"; OR you've just edited a config / restarted a service / installed a package and want to confirm BEFORE declaring `[TASK_COMPLETE]`.
---

# Verify-Fix Playbook

You're being asked to **prove** a fix actually worked — not just that the command you ran exited 0, but that the **observable user-visible symptom** is gone.  Adapted from Claude Code's `verify` skill, but for terminal/sysadmin work.

The bar is: **if the original reproducer fails again, the fix did NOT work, regardless of what intermediate steps reported.**

## Step 1 — Identify the reproducer (no command this turn, just think)

From the prior conversation context, extract THREE things:

1. **The original symptom** — what command / page / service was failing, with what error.
2. **The applied fix** — what file you edited, package you installed, service you restarted.
3. **The expected post-fix observation** — what the SAME reproducer should now show on success.

If you can't name all three from the conversation, end the turn with `[ASK_USER]` and ask the user to spell out the reproducer.  Guessing here wastes a verification cycle.

## Step 2 — Re-run the original reproducer (ONE command this turn)

Run the EXACT command from step 1 — same flags, same target.  Do NOT substitute a "similar" command that you think proves the same thing; the user's frame of reference is the original command.

Common reproducer shapes:

| Symptom class | Re-verify command |
|---|---|
| HTTP service was 500'ing | `curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' <URL>` |
| Port wasn't listening | `nc -z -w 2 <host> <port> && echo OPEN \|\| echo CLOSED` |
| Command-not-found | `command -v <cmd> && <cmd> --version` |
| Permission denied on file | `ls -la <path> && cat <path> \| head -1` |
| Service was down | `systemctl is-active <unit>` (Linux) or `launchctl print system/<label>` (macOS) |
| Build was failing | The exact `make` / `npm run build` / `cargo build` command from before |
| Test was failing | The exact `pytest -k …` / `go test -run …` / `jest <pattern>` from before |
| Env var was unset in shell | `printenv VARNAME` (NOT `echo $VARNAME` — that's empty for either unset OR empty-string) |

## Step 3 — Interpret the result

| Outcome | Action |
|---|---|
| Exit 0 AND output matches expectation | ANSWER: state plainly "Verified: …" + paste the proving evidence (exit code, key output line).  End with `[TASK_COMPLETE]`. |
| Exit 0 BUT output is wrong (HTTP 200 returning the old broken page; service active but old config) | The fix touched the wrong layer.  Diagnose ONE level deeper (config reload? cache? rolled to wrong host?) and continue INVESTIGATE — do NOT claim success. |
| Non-zero exit | Fix did NOT take.  Read stderr carefully — the error is often DIFFERENT from the original (a fix that turned `EACCES` into `ENOENT` is progress, not regression).  Continue INVESTIGATE from the new error. |
| Reproducer itself errored (typo, missing binary) | This is YOUR mistake, not the fix's.  Pivot, do NOT retry the same broken reproducer. |

## Anti-patterns to avoid

- **"It probably works because the service restarted"** — restart succeeded ≠ service serves correctly.  Always probe the user-facing surface.
- **"I'll just check the logs look clean"** — absence of new errors in 5 seconds of log tail ≠ working.  Hit the actual endpoint.
- **Running a DIFFERENT command that the user didn't ask about** — the user remembers the original symptom; verify against THAT.
- **Skipping verification because you're "confident"** — confidence without evidence is exactly what this skill exists to override.

## Stop conditions

End with `[TASK_COMPLETE]` only after BOTH conditions hold:
1. Exit code is what success looks like for THIS command (often 0, but `grep` returning 1 = no match, which can be success depending on intent).
2. The output / response body / status line matches what the user originally wanted to see.

End with `[ASK_USER]` if the reproducer reveals a NEW failure mode that wasn't in the original task scope — don't silently expand work.
