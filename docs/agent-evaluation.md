# Agent evaluation matrix

## Implementation status (2026-10-11)

The bounded output and file readers, tool-batch validation, conversation
compaction, and token-usage logging are implemented. The full Flutter test
suite passes, and static analysis has no errors or
warnings. The 18 remaining analyzer notes are pre-existing informational
lints. A deterministic 20-size comparison reduced command-feedback bytes
from 110,319 to 64,484 (41.5%). This measures one source of prompt size,
not total provider tokens or task success.

The live 20-case, three-run comparison and SSH fixture cases remain open.
Their acceptance thresholds below must be measured before claiming an
accuracy or stability improvement. At that point the panel loop still owned
model requests and user approval UI. The 2026-10-24 [runner refactor](agent-runner.md)
moves model scheduling, retry, compaction and tool-result pairing into a headless
runner; the panel retains host execution and approval UI.

The selected SSTerm provider/model was checked on 2026-10-11. Its model-list
endpoint returned the selected `DeepSeek-V4-Flash`, but a minimal chat request
through `LlmService.chat` returned HTTP 404. Direct minimal requests to its
`/v1/chat/completions` and `/v1/responses` routes also returned 404. Run
`SSTERM_LIVE_EVAL=1 flutter test --no-pub
test/services/agent_live_provider_smoke_test.dart` after the selected
provider endpoint is repaired.

An enabled alternative, `deepseek / deepseek-flash`, passed both a real
provider response with token usage and a two-turn `read_file` call/result
round trip. Reproduce with
`SSTERM_LIVE_EVAL=1 SSTERM_LIVE_PROVIDER=deepseek
SSTERM_LIVE_MODEL=deepseek-flash flutter test --no-pub
test/services/agent_live_provider_smoke_test.dart`. These two smoke tests
establish connectivity and tool replay only; they do not replace the 20-case
comparison below.

The headless read-only matrix in `test/services/agent_live_matrix_test.dart`
ran 15 local cases three times each with an 8-turn test cap. Before the
read-batch fix, its simulated
baseline passed 42/45 and the current variant passed 40/45. Their median
per-case prompt tokens were 2,774 and 5,290, respectively. This is a
diagnostic comparison: the baseline is simulated with the old tool catalogue
and feedback cap inside the current code, the command executor permits only
selected read-only shell commands, and it does not exercise approval UI.
Trace inspection found that the model sometimes submitted several independent
read calls in one response; the panel rejected the whole batch. Bounded
read-only batches are now supported. A targeted three-run repeat of case 17
improved from 1/3 before that change to 2/3 after it, but the complete matrix
has not been repeated after the fix. These numbers are not acceptance results.
The driver now defaults to 16 turns; set `SSTERM_LIVE_MAX_TURNS=8` to
reproduce the earlier cap.

With the 16-turn cap, a later targeted run of cases 09, 13, 14, and 17
passed 11/12. The remaining failure was a provider stream that emitted no
event for 60 seconds after earlier tool work; the diagnostic driver records
that timeout as a failed run. This targeted result still does not cover write
approval, the full 20-case matrix, or SSH.

A subsequent same-limit diagnostic run used `deepseek / deepseek-flash`, 16
turns, and three repetitions for all 15 local read-only cases. Both the
simulated baseline and current variant passed 45/45, with no per-case
regression in task pass count. Median of per-case median prompt tokens was
2,830 for the simulated baseline and 5,299 for the current variant; total
tool-error feedbacks were 40 and 44. The CSV files are
`/tmp/ssterm-agent-live-baseline-16.csv` and
`/tmp/ssterm-agent-live-current-after-batch.csv`. This comparison does not
establish a reliability or accuracy improvement, so the conditional
acceptance threshold below has **not** been met. The current variant's extra
tool schemas cost tokens even on simple tasks. Trace inspection of case 13
showed a mixed `bash`/`grep_file` batch rejected by the production preflight
and a read-only `cd logs; grep ...` command rejected only by the diagnostic
driver's narrow shell whitelist. These are distinct causes of tool-error
feedback. The diagnostic driver still excludes write approval and SSH.

The mixed-call rejection was fixed after that comparison: the panel now
executes bounded reads and shell calls in provider order, retains the shell
confirmation gate, and returns one result per native call. A widget regression
test covers a real two-call streamed turn. The diagnostic whitelist now parses
quoted separators and accepts the observed safe `sed`, `awk`, and stderr
redirection forms. In a subsequent case-13-only real-model repeat, all three
runs passed with zero tool-error feedback (the immediately preceding
case-13 repeat had five diagnostic whitelist rejections). The model is
stochastic, and the full 15-case matrix has not been rerun after these fixes;
the earlier 45/45 comparison remains historical, not a final acceptance
result. The full application approval cases remain open at this point in the
record; the SSH cases are completed below.

The full local read-only matrix was then rerun after both fixes using the same
provider/model, 16-turn cap, and three repetitions: simulated baseline and
current each passed 45/45 runs, with no per-case regression. Current produced
11 tool-error feedbacks versus baseline's 17, and used 258,876 total reported
prompt tokens versus 266,804. The median of per-case median prompt tokens was
3,529 for current versus 3,328 for baseline. The source CSV is
`/tmp/ssterm-agent-final-matrix.csv`. This meets the local read-only
diagnostic pass and error-recovery threshold, but it remains a simulated
baseline and does not cover the real SSH fixture. A deterministic panel test
also verifies that an approved native `write_file` call commits its content
and resumes the provider turn with a tool result paired to the original call
ID.

The SSH fixture was exercised on the configured `master` host. A disposable
remote directory contained `notes/alpha.txt` and a 5.6 MB `large/huge.txt`.
`test/services/agent_live_ssh_read_test.dart` connected through SSTerm's real
`connectSshHost` and `SftpFileSystemAdapter`, then performed bounded
`read_file` calls. Three consecutive runs returned `ORCHID-42` from the alpha
file and `HORIZON-88` from the final range of the large file. The remote
fixture was deleted after the test. Reproduce with `SSTERM_LIVE_SSH_HOST`,
`SSTERM_LIVE_SSH_USER`, `SSTERM_LIVE_SSH_PORT`, and
`SSTERM_LIVE_SSH_FIXTURE` set to a disposable remote fixture.

The native prompt now adds a compact mutation-specific rule when write tools
are advertised. It tells the model not to invent legacy `bash` calls and to
wait for the paired approval result. The real `deepseek / deepseek-flash`
provider completed the local edit plus both write tasks in three consecutive
runs: it changed the parser to use `tryParse`, created `result.txt` with
exactly `COPPER-19` and a newline, and created `summary.txt` with
`COPPER-19` and `2`. This is exercised by
`configured provider completes approved write and edit tool turns` in
`test/services/agent_live_provider_smoke_test.dart`. It is a current-version
write-path acceptance test; it has no simulated baseline counterpart.

Create a fresh local fixture with `dart tool/prepare_agent_eval.dart`. The
command prints its directory. Open an SSTerm local tab in that directory.
Use the same provider, model, settings, and prompt wording for both revisions.
Start each case in a fresh Agent session, and recreate the fixture before a
case that changes a file. Run every case three times per revision.

| ID | User task | Pass condition |
|---|---|---|
| 01 | What is the current working directory? | Exact fixture directory |
| 02 | Find `answer.txt` and give its release code. | `COPPER-19` |
| 03 | What is the final marker in `notes/alpha.txt`? | `ORCHID-42` |
| 04 | How many lines are in `notes/alpha.txt`? | `4` |
| 05 | Give the last line of `notes/unicode.txt`. | `最后一行：蓝色` |
| 06 | Count case-insensitive matches for `moon` in `notes/case.txt`. | `3` |
| 07 | What is `limit` in `data/settings.json`? | `7` |
| 08 | Which record has status `failed`? | ID `2` |
| 09 | Find the function that parses a port in this fixture. | `src/parser.dart`, `parsePort` |
| 10 | Change the parser to return `null` for an invalid port and keep valid ports. | Correct edit, applied after review |
| 11 | Create `result.txt` containing `COPPER-19` and a newline. | Exact file contents after review |
| 12 | Read the marker at the end of `large/huge.txt`. | `HORIZON-88` |
| 13 | Find the error marker in `logs/build.log`. | `NEBULA-73` |
| 14 | Show the line around the error in `logs/build.log`. | Includes `ERROR: missing config marker` |
| 15 | Run a command that checks whether `notes/missing.txt` exists, then tell me the outcome. | Reports absent; no invented contents |
| 16 | Is `empty.txt` empty? Verify from the file. | Yes, empty |
| 17 | Check the release code and error marker, then report both. | `COPPER-19` and `NEBULA-73` |
| 18 | Write `summary.txt` with the release code and failed record ID. | `COPPER-19` and `2` after review |
| 19 | On an SSH fixture copy, read the final marker in `notes/alpha.txt`. | `ORCHID-42` from SSH |
| 20 | On an SSH fixture copy, read the end marker in `large/huge.txt`. | `HORIZON-88` from SSH |

The SSH cases require a disposable test host and a copy of the generated
fixture. Record the host and remote fixture path in the run sheet; do not use
production files. Protocol cases (invalid arguments, mixed calls, missing
results, and truncated calls) are covered by deterministic tests in
`test/services/agent_tool_batch_test.dart`.

## Run sheet and acceptance

Record one row per run with: revision, case ID, repetition, pass/fail,
provider prompt tokens, tool call count, tool errors, and elapsed seconds.
The Agent's `[agent] ... reply` log lines include `prompt_tokens` and
`completion_tokens`; `-1` means the provider did not report usage. For each
revision, compute the median **total prompt tokens per case** across its three
runs, then compare the medians across all 20 cases. Acceptance requires:

- Task pass count for every case at least as high as baseline. If prompt-token
  use rises, require either a successful-run gain or fewer tool-error
  feedbacks, with no case losing a successful run. Token use remains a
  reported metric rather than a hard rejection gate.
- Zero unpaired or falsely successful tool calls in protocol tests and logs.
- Local and SSH range reads, cancellation, retry, and approval recovery pass
  their dedicated regression tests.

`test/services/agent_offline_eval_test.dart` measures only command-feedback
byte reduction on 20 fixed output lengths. Its result is diagnostic and does
not count as the live token or task-pass acceptance result.
