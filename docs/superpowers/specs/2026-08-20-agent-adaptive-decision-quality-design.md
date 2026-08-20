# Agent Adaptive Decision Quality

## Goal

Improve the quality of a 27B-class model by using an adaptive, evidence-led
decision loop.  The Agent should spend extra model calls only on tasks that
benefit from them, produce a recommended solution with a concise comparison of
alternatives, and validate its result against real tool evidence.

The target is not to claim that a 27B model is intrinsically equivalent to a
120B model.  Instead, the host compensates for its weaker single-pass planning
with structured decomposition, independent critique, constrained execution,
and verification.  The default operating point balances answer quality with
latency and API cost.

## Problem

The current Agent makes one model-driven decision at a time, but it has no
host-level distinction between a simple direct task and a task with meaningful
alternative solutions.  A smaller model can consequently commit too early to
one approach, omit a constraint, or mistake an unverified tool result for a
completed task.  Adding only more system-prompt wording cannot reliably make
the model generate, challenge, and verify alternatives.

## Behavior

### First-turn route and anchors

Before the first model request, the host selects the task's reasoning mode.
This is external routing: do not depend on a 27B model to reliably decide for
itself when to switch from quick execution to deep planning.  The route is
locked for the task, not continuously rewritten mid-trajectory:

- **Fast** uses the existing concise think-act loop.
- **Deep** requires the decision path below.
- **Uncertain** uses a neutral route that asks for evidence or escalates after
  its first observed result; it must not select an unstable halfway persona.

The static system prompt continues to carry durable safety and tool protocol.
Immediately after each user task, the host appends a short, fixed routing guide
to the user-side task context.  The deep guide calls out architecture,
constraints, edge cases, and integration points; it ends each reasoning block
in a decision or information need.  The fast guide calls for direct,
verifiable completion.  Both include three anti-runaway anchors: review what
is already complete, finish when the evidence is sufficient, and avoid
unguided environment inspection or exhaustive search.  The guide contains no
dynamic secrets or host facts, preserving stable system-prompt caching.

### First-turn tool focus

When a session exposes a large tool catalogue, the first request may advertise
only the one or two tools necessary to take a safe initial step.  After the
first durable tool outcome, the complete authorised catalogue becomes
available.  This is an optional, measured optimisation: it must never hide a
tool required to answer the task safely, or reduce a user's existing access.
The full catalogue is restored on every later request and after session resume.

### Fast path

Tasks that are low risk, have one obvious action, and require no material
trade-off use the existing single-agent loop.  They do not receive additional
planning or critique calls.

### Deep decision path

The Agent upgrades a task when it has multiple credible implementations,
changes project or host state, has a material cost or risk, depends on
incomplete/current information, needs recovery from an earlier failure, or the
user explicitly requests a recommendation.

The deep path has these phases:

1. **Plan.** Generate two or three executable candidate solutions.  Each
   candidate declares assumptions, risks, cost or time, a validation method,
   and its fit for the user's stated goal.  The planner selects a provisional
   recommendation.
2. **Critique.** A fresh model call receives the user task and structured plan
   but is limited to finding unsupported assumptions, missing constraints,
   lower-risk alternatives, and incorrect ranking.  It performs no tools and
   has no authority to execute changes.
3. **Execute.** The existing Agent loop carries out the revised recommended
   plan.  Existing command classification, approval, and write-proposal
   boundaries remain authoritative.
4. **Verify.** A verifier compares actual shell/MCP/test results with the
   validation criteria captured in the plan.  If evidence contradicts the
   plan, it returns the failure evidence and remaining budget to planning for a
   limited re-plan instead of retrying blindly.
5. **Summarize.** The final answer gives the recommended solution, a concise
   alternatives comparison, verification evidence, and any residual risks or
   unverified assumptions.  It must not expose private chain-of-thought.

## Architecture

### TaskComplexityClassifier

Classifies a user request as fast or deep.  Its decision is deterministic from
observable task signals where possible; the model may request escalation when
new evidence reveals uncertainty.  It also selects fast, deep, or uncertain
first-turn guidance and records the route for diagnostics.  Classification is
recorded for diagnostics.

### DecisionPlan

An internal structured record containing candidate solutions, the common
comparison dimensions, the provisional and final recommendation, assumptions,
validation criteria, and consumption from the decision budget.  Keeping this
separate from prose prevents critical constraints from disappearing between
model turns.

Comparison dimensions are applied only when relevant:

- outcome fit;
- evidence and probability of success;
- risk and reversibility;
- latency and model/tool cost;
- maintenance and operational complexity.

### PlanCritic and OutcomeVerifier

`PlanCritic` is a read-only model stage.  `OutcomeVerifier` consumes structured
tool outcomes rather than model assertions.  Neither component can bypass the
existing command safety, file-write approval, or user-question mechanisms.

### DecisionSummary

Converts the internal plan and evidence into a brief user-facing report:

- **Recommendation** — selected approach and primary rationale.
- **Comparison** — why the viable alternatives were not selected.
- **Evidence** — relevant command, test, MCP, or retrieved facts.
- **Remaining risk** — what is still inferred or requires user input.

## Data flow

`user task -> classify -> fast path | plan -> critique -> execute -> verify
-> optional bounded re-plan -> decision summary`

All mutating operations remain in the existing execution phase.  A risky
operation still requires the current user confirmation flow even if the plan
ranked it highest.

## Budgets and failure handling

- A fast task has its current one-call behavior.
- A deep task has a default total budget of three to five calls across planning,
  critique, execution, and verification.  A failed verification may spend up
  to two additional calls on recovery.
- No-evidence retries are prohibited.  A re-plan must cite new tool output,
  user input, or a specifically identified planning defect.
- If a plan/critique response is malformed, a provider fails, or the budget is
  exhausted, safely fall back to the existing single-agent path where possible.
  The final answer must state that the recommendation is incomplete rather
  than claim optimality.
- Facts, user preferences, and model assumptions are tagged separately.  A
  recommendation based on an unverified assumption identifies it as such.

## Measurement and model calibration

The routing and anchoring behaviours are hypotheses to validate in SSTerm;
they are not assumed to transfer from another runtime or model family.  For
each supported local 27B model, run a fixed task set with an unchanged host
environment and compare the candidate presets against the current loop.

Record at least:

- task completion and verification-pass rate;
- user-visible recommendation quality on tasks with alternatives;
- mean model calls, tool calls, elapsed time, and token use;
- safety-gate compliance;
- failure category, including incorrect routing, tool misuse, unsupported
  assertion, insufficient exploration, and runaway exploration.

Promote a route, near-message guide, or first-turn tool focus only when it
improves verification-adjusted completion without an unacceptable cost or
safety regression.  Keep per-model settings versioned and observable so an
operator can revert to the baseline path.

## Tests and acceptance criteria

Add focused tests for:

- classification into fast and deep paths;
- plan creation with comparable candidates and relevant dimensions;
- a critique that corrects an invalid provisional recommendation;
- execution respecting the current approval/safety gates;
- verifier-led recovery with a bounded call count and no blind retry;
- budget exhaustion and safe fallback;
- first-turn route selection and stable near-message guidance;
- correct expansion from a focused first-turn tool set to the full authorised
  catalogue;
- anti-runaway anchors terminating unproductive exploration;
- a final summary containing recommendation, comparison, evidence, and
  residual risk without chain-of-thought;
- preservation of one-call behavior for simple tasks.

Acceptance uses representative code debugging, host-operation, recommendation,
and incomplete-information tasks.  The deep path must produce a comparison,
validate key conclusions through available tools when applicable, and finish
within its configured budget.  The fast path must not gain extra model calls.

## Out of scope

- Guaranteeing that every 27B model matches a 120B model's knowledge,
  reasoning ceiling, or generation quality.
- Introducing additional model providers or a separate large-model fallback.
- Replacing existing host command safety, user-approval, provider protocols,
  or transcript-compaction behavior.
- Treating results from an external routing project or a different model family
  as proof that the same prompts or routes work for SSTerm.
