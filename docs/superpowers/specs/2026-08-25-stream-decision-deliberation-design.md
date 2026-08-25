# Stream adaptive-decision deliberation design

## Goal

Planning and independent review must use the same streaming transport as the
main Agent response. A user can see bytes arriving immediately instead of a
decision card being the only visible state while a non-streaming HTTP request
waits for completion.

## Flow

1. Insert the operational decision card and an ordinary assistant message for
   planning.
2. Start the planner through `LlmService.chatStream` with its existing
   tool-free request profile. Append each text event to the planning message.
3. Once the stream ends, parse the accumulated JSON. Replace the temporary
   streamed JSON with the existing concise, readable plan summary.
4. Repeat for independent review, showing its streamed data in a second
   ordinary assistant message and replacing it with the concise recommendation
   after parsing.
5. Continue with the existing main Agent streaming execution message.

The decision card continues to show telemetry and cancellation. It no longer
stands in for planner/reviewer output.

## Failure and usage

The stream helper accumulates diagnostics token counts and returns them with
the parsed value. On a stream error or invalid final JSON, it leaves a concise
failure message in the relevant assistant message and follows the existing
standard-execution fallback. Cancellation resets the isolated stream session.

Raw streamed JSON is visible only while the model is producing it; a successful
completion replaces it with the readable structured summary. Hidden reasoning
events and internal prompts remain hidden.
