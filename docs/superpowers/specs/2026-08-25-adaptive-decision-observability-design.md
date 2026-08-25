# Adaptive Decision Observability Design

The deep-decision transcript card will show elapsed time, completed model-call
count, and aggregate provider-reported prompt/completion tokens. It updates
once per second and reports "Still waiting for the model" after 15 seconds
without a lifecycle update. A cancel button reuses the Agent panel's existing
stop action.

Provider usage remains nullable. A card shows "Token data unavailable" unless
at least one isolated planning, critique, or verification response supplied
actual usage; it never estimates token use. `LlmResponse` preserves parsed
usage from OpenAI-compatible, Anthropic, Gemini, and Ollama non-streaming
responses. Deliberation methods return their parsed value with that usage so
the UI can aggregate it without affecting the model-facing transcript.
