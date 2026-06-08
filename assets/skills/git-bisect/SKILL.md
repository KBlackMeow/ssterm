---
name: git-bisect
description: Locate the first bad commit via git bisect, with full pre-flight checks and a non-interactive `git bisect run` fast-path.
when_to_use: the user asks to find which commit broke something, mentions a "regression", says "it used to work", or explicitly asks to bisect git history.
---

# Git Bisect Playbook

You are walking the user through a `git bisect` session to locate the FIRST bad commit.

## Pre-flight checks (one combined turn, then STOP)

Run these THREE commands chained with `&&` so they execute as a single bisect-able shell turn:

```bash
git rev-parse --is-inside-work-tree && git status --porcelain && git log --oneline -10
```

What the output tells you:
- `true` from `rev-parse` → we are inside a git repo. If not, STOP and `[ASK_USER]` for the repo path.
- Empty `status --porcelain` → working tree clean, safe to bisect. If dirty, ask the user to stash / commit first; bisect with a dirty tree leaves the user stranded mid-bisect when the test commands modify files.
- `log --oneline -10` → most recent commits, so you can suggest a known-good starting point.

## Establish the GOOD and BAD endpoints

Before starting the bisect, you MUST know:

1. **A bad commit** (usually `HEAD`) where the bug REPRODUCES.
2. **A good commit** (usually an older tag or a known-working SHA) where the bug DOES NOT reproduce.

If the user hasn't told you the good commit, ASK them — never guess. A wrong "good" endpoint wastes the entire bisect.

## Run the bisect

Start with:

```bash
git bisect start <BAD_SHA_or_HEAD> <GOOD_SHA>
```

For EACH iteration of the bisect:
1. git will check out a midpoint commit and print its SHA.
2. You ask the user to run their reproducer (or, if you have a one-line check, run it via the agent).
3. Mark the result:
   - Reproducer fails → `git bisect bad`
   - Reproducer passes → `git bisect good`
   - Build broken / test cannot run → `git bisect skip`

When `git bisect` prints `<SHA> is the first bad commit`, finish with:

```bash
git bisect reset
```

ALWAYS run `git bisect reset` at the end (success OR abort), otherwise the user's working tree stays on the midpoint commit, which is a huge usability papercut.

## Automating with `git bisect run`

When you have a deterministic one-liner that exits 0 for good / non-0 for bad, prefer `git bisect run` — it walks the entire history in a single turn:

```bash
git bisect run sh -c 'make test-foo 2>/dev/null'
```

`git bisect run` ignores exit code 125 (treated as "skip"), so write the test command to `exit 125` on un-buildable revisions.

## Stop conditions

End your turn with `[TASK_COMPLETE]` after `git bisect reset` succeeds AND you've named the first-bad-commit SHA + its subject line to the user.

End your turn with `[ASK_USER]` whenever:
- The good/bad endpoints aren't known yet.
- The working tree is dirty and you need permission to stash.
- A test command is interactive or destructive (touches the database, makes network calls).
