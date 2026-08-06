# Agent Settings Module Split

## Goal

Reduce the Agent page to model and capability configuration by promoting Skills
and MCP Servers into independent first-level Settings destinations.

## Navigation

The desktop rail and narrow navigation expose: Appearance, Font, Cursor, SSH,
Commands, Agent, Skills, MCP, Safety, and About.

## Module Boundaries

- Agent retains Default Provider, Display, Web Search, File Write, and Providers.
- Skills contains the installed-skill list, enabled count, bulk actions, and toggles.
- MCP contains the master switch, server cards, and Add MCP Server action.
- Existing AgentConfig fields, connection handling, controllers, and persistence
  callbacks are unchanged.

## Implementation and Verification

Extract dedicated Skills and MCP tab builders from the current Agent list; reuse
the existing section widgets rather than duplicating them. Increase the tab
controller length and keep rail labels, icons, narrow navigation, and indexed
content list aligned. Add coverage that confirms Skills and MCP are destinations
and no longer render in Agent.
