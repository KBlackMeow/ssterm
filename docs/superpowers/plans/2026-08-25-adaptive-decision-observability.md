# Adaptive Decision Observability Implementation Plan

**Goal:** Make deep-decision card progress, token usage, and stalled calls visible.

1. Add failing tests for non-streaming usage preservation and card observability fields.
2. Preserve provider usage in `LlmResponse` and return it through deliberation results.
3. Aggregate usage, call count, timing, stalled state, and cancellation in the decision card.
4. Run analysis and the full Flutter suite.
