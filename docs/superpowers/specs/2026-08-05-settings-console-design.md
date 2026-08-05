# Settings Console Design

## Goal

Modernise the Settings page so it matches ssterm's existing dark Liquid Glass
language while prioritising desktop use. The page should feel like a precise
terminal control console, not a generic mobile form.

## Scope

- Restyle `SettingsPage` and its reusable settings primitives.
- Replace the desktop top tab strip with a persistent, compact category rail.
- Retain every existing category, field, action, persistence path, and callback.
- Preserve a usable narrow-window layout by falling back to the current
  horizontal tab navigation when a rail would make content too narrow.

No settings schema, terminal rendering behaviour, agent behaviour, or network
behaviour changes are included.

## Chosen Direction: Terminal Control Console

The visual system uses a deep ink background, cold-grey hairline dividers,
compact spacing, and cyan-blue signal colour. Monospaced type is reserved for
small labels, statuses, paths, and values; normal UI text remains legible
proportional text. Glow appears only on active navigation and focused controls.
Existing `FrostedGlassStyle` surfaces are reused where appropriate, keeping the
page aligned with the app's Liquid Glass materials without excessive blur.

### Page frame

On desktop-width layouts, the page contains:

1. A compact header with a settings glyph, `SETTINGS` label, and a contextual
   status line.
2. A fixed left rail listing Appearance, Font, Cursor, SSH, Commands, Agent,
   Safety, and About. The active destination uses a cyan leading signal and
   muted translucent fill.
3. A right content pane. It keeps the current tab bodies and scroll behaviour.
   Each destination is still backed by the existing `TabController`, so no
   callbacks or state paths change.

The terminal preview remains available in Appearance but becomes a concise,
framed status-preview panel rather than a page-wide banner. This restores first
screen space for actual controls.

### Components

- **Settings shell:** owns responsive layout and maps a rail selection to the
  existing tab controller.
- **Console navigation item:** icon, label, active state, tooltip, keyboard/
  pointer focus treatment, and selection callback.
- **Section heading:** small uppercase monospace label with a hairline rule or
  status marker.
- **Console surface:** shared card decoration used for settings groups:
  translucent ink fill, 1px cool border, 8-10px radius, subdued top highlight.
- **Setting rows:** existing toggles, selectors, inputs, and buttons are
  visually harmonised into compact key/value rows. Their handlers remain
  unchanged.

### Responsive behaviour

The console rail is enabled only when content has sufficient desktop width.
Below the chosen breakpoint, the header and current horizontally scrollable
`TabBar` remain available, preventing the Agent and provider forms from being
unnecessarily constrained. Both presentations select the same tab and expose
the same widget bodies.

## Data Flow and Error Handling

Visual interactions delegate to the current `_apply`, `_agentApply`, and
existing callback paths. Rail selection calls `TabController.animateTo`; tab
swipes and rail state remain synchronised through the controller listener.

There are no new asynchronous operations or user-visible errors. Existing API
key loading, command persistence, and form validation retain their behaviour.

## Accessibility and Interaction

- Navigation labels remain visible on desktop; icons also get tooltips.
- Active and hover states meet contrast requirements without relying only on
  colour; the active item has a leading bar and stronger type weight.
- Existing Material controls retain their semantic roles and keyboard support.
- The narrow layout keeps its scrollable category controls for touch and
  reduced-width windows.

## Tests and Verification

Add widget coverage for the responsive shell: desktop shows the console rail,
narrow layouts show the tab strip, and selecting a rail item changes the visible
tab. Run the focused widget tests, `flutter analyze`, and the project test
suite after implementation. Manually inspect the Appearance and Agent tabs at
desktop and narrow widths to confirm high-density layout without clipping.

## Acceptance Criteria

- Desktop settings uses a persistent console-style category rail.
- All eight current categories and settings remain reachable and functional.
- Appearance opens with a compact terminal preview and console surfaces.
- Existing Liquid Glass visual language is recognisable in surfaces and active
  states.
- Narrow layouts retain a usable tab-based presentation.
- Analyzer and tests complete successfully.
