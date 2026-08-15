# Terminal Query Response Design

## Goal

Make SSTerm answer terminal capability queries deterministically, so Fish 4.7+
and other xterm-compatible programs can initialise without a per-shell
workaround. The behavior must be identical for local PTYs and SSH sessions on
macOS, Linux, and Windows.

## Compatibility boundary

SSTerm is an xterm-compatible terminal with a conservative iTerm2-compatible
subset. It must never claim support for an iTerm2-only feature which SSTerm
cannot perform. In particular, it does not advertise iTerm2 image/file
transfer, profile switching, proprietary clipboard commands, or kitty keyboard
protocol support.

Existing user input, OSC 7 working-directory handling, OSC 52 handling,
focus reporting, resize behavior, and application output must remain unchanged.

## Protocol responses

The vendored xterm terminal owns parsing and response generation. Its existing
`onOutput` channel returns response bytes to the active local PTY or SSH
channel, so both transports use one implementation.

| Query | Response | Rule |
| --- | --- | --- |
| DA1 (`CSI c`) | Existing VT100/xterm DA1 | Preserve the current response. |
| DA2 (`CSI > c`) | Existing xterm-95-compatible DA2 | Preserve the current response. |
| Kitty keyboard state (`CSI ? u`) | `CSI ? 0 u` | Explicitly report that kitty keyboard protocol is disabled. |
| XTVERSION (`CSI > 0 q`) | `DCS >|SSTerm <version> ST` | Identify SSTerm honestly; never identify as iTerm2. |
| OSC 11 background query | `OSC 11;rgb:RRRR/GGGG/BBBB ST` | Read the active terminal background supplied by the host. |
| XTGETTCAP (`DCS +q`) | Valid encoded responses only for supported terminal capabilities; invalid response otherwise | Fish needs `indn` and `query_os_name` handling to complete its probing. |
| iTerm2 feature query (`OSC 1337;Capabilities`) | A deterministic capability report containing only implemented standard capabilities | Do not advertise iTerm2 proprietary actions. |

Responses are generated only after a complete parsed query. They contain no
platform-specific executable paths, hostnames, or user data. A query split over
arbitrary output chunks receives exactly one response; repeated complete
queries receive exactly the same response.

## Host integration

`Terminal` exposes a small immutable capability profile. The Flutter host
constructs the same profile for every terminal tab. It supplies display-derived
values such as active background color and pixel metrics, while the terminal
core supplies protocol formatting and parser state.

The profile is platform-neutral. macOS, Linux, and Windows may provide
different pixel-scale values, but the protocol parser and advertised semantic
features remain the same. Missing host data yields a standards-safe negative
or default response rather than an exception.

The current Fish `no-query-term` launch workaround is removed once runtime
coverage proves the terminal responds before Fish consumes input. This makes
direct Fish startup and `zsh → fish` use the same normal Fish startup path.

## Parser and safety

Add an incremental DCS parser alongside the existing incremental CSI/OSC
parsers. It must retain incomplete input until `ST`, cap request size, and
treat malformed or unknown DCS as ordinary terminal control traffic without
echoing it to the process. All decoding is ASCII/hex validated before use.

Query responses bypass output display and flow only through `Terminal.onOutput`.
They must not enter terminal scrollback, Agent output, OSC 7 cwd parsing, or
logs.

## Verification

- Unit-test each supported CSI, OSC, and DCS request, including byte-by-byte
  and multi-query chunking.
- Assert stable, single responses for repeated requests and safe negative
  responses for malformed/unknown requests.
- Test that normal terminal text and all current DA/OSC behavior are unchanged.
- Add an integration fixture for Fish's observed startup probe sequence and
  verify it receives DA plus XTGETTCAP handling without `no-query-term`.
- Exercise the local and SSH callback wiring with the same response fixture.
- Run the vendored xterm suite, SSTerm service/widget suite, static analysis,
  and platform-specific source checks. Native PTY smoke tests run on macOS and
  Windows; Linux is covered by the common xterm and local-process tests.
