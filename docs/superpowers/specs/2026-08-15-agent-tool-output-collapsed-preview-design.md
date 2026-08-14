# Agent Tool-output Collapsed Preview

## Goal

Keep the Agent transcript compact by making execution-related cards collapsed
by default while preserving a short, useful preview. Normal Agent prose and
cards that require a user decision remain fully visible.

## Scope

Apply a four-line default preview to completed command-result output and MCP
tool-result content. A user can expand a card to inspect all of its content and
collapse it again.

Native/legacy tool-call cards remain collapsed by default. Their existing
summary-only header is the collapsed representation; expanding continues to
show the call name, ID, and redacted arguments.

## Design

### Command results

Change `_CommandResultCard`'s collapsed output limit from eight lines to four.
The command, AI-supplied purpose, risk, and exit status remain visible in the
header. If output exceeds four lines, show the first four followed by an
expand affordance that reports the omitted-line count. When expanded, show the
full output and a collapse affordance.

Live command cards retain their existing rolling three-line tail, because it
already fits within the preview limit.

### MCP results

Make `_McpResultCard` stateful and render it as an expansion card. Its
collapsed state displays the MCP server/tool header and a preview of up to four
logical content lines across all result blocks. Text blocks contribute their
first lines; image, resource, and unsupported blocks contribute their existing
short placeholder text. If content remains hidden, expose an expand
affordance. Expanded state renders every original content block without
truncation and offers collapse.

The result's success/error colour and error status remain visible in both
states. The stored MCP result and provider feedback are not truncated or
modified.

### Exclusions

Do not collapse normal Agent responses, user messages, notices, or interactive
approval/question cards. Do not alter tool dispatch, command execution, MCP
requests, model transcripts, content redaction, or artifact retention.

## Tests

- Command-result card uses a four-line collapsed limit and retains its
  expand/collapse controls.
- MCP-result card is stateful, starts collapsed, limits its preview to four
  logical lines, and retains error styling.
- Tool-call cards remain initially collapsed and continue to render details
  only after expansion.
- Normal Agent reply rendering remains outside the collapsing behavior.

