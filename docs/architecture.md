# Krill architecture

Krill is a thin native shell around two things: a **daemon** that owns everything stateful
(agent sessions/PTYs, git, integrations, settings) and **extensions** that contribute almost
everything you see. The app itself only provides the window, the layout, a registry of
contributions, the command palette and settings.

```
┌ Sidebar ────────┐┌ Editor area ─────────────────────────────┐┌ Inspector ──────┐
│ Project         ││ [Claude ●][Terminal][app.ts][Browser]  + ││ ⎇  ☰  ◉  ⚑  ⧉   │
│  ▾ Workspace 1  ││ ┌──────────────────┬──────────────────┐  ││ Changes / Files │
│     ✻ Claude ⚙  ││ │ agent terminal   │ file / browser / │  ││ Issues / Agent  │
│     ✻ Codex ?   ││ │                  │ diff / ext view  │  ││ Docker / …      │
│  ▸ fix-login ✓  ││ └──────────────────┴──────────────────┘  ││ (extension      │
│ + Add Project   ││   groups split freely, tabs of any kind  ││  panels)        │
└─────────────────┘└──────────────────────────────────────────┘└─────────────────┘
```

## Concepts
- **Project**: a git repository (`repo.*` RPCs).
- **Workspace**: a working copy of a project with its own agents and layout (`worktree.*` RPCs).
  Every project has a *main* workspace on the repo itself; "+" makes isolated ones (a git worktree
  on a new branch) instantly, named "Workspace N" until the first agent prompt names it (on-device AI).
- **Agent**: a session in a workspace (`session.*`). Status: working · needs input · done · idle · paused · ended.
- **Tab**: anything shown in the editor area, addressed by a URI:
  `session:<id>`, `file:<path>#L12`, `diff:<path>`, `https://…`, `chat:<id>`, `ext:<extension>/<view>`.
  Groups of tabs split right/down; drag tabs between groups or onto an edge to split.

## Contribution points (built-in Swift extensions and `extension.json` folders use the same ones)
| Point | Where it shows |
| --- | --- |
| panels | right inspector (selector icons) |
| editors | center tab types, listed in the "+" menu |
| commands | command palette (⇧⌘P), menus, key bindings |
| settings | Settings window (generated forms) and `~/.krill/settings.json` |
| themes | Appearance settings; drive terminal + editor colors |
| agents | agent CLIs offered in "+" menus |

Built-ins (Git, Files, Issues, Browser, Chat, Agents) can be disabled like any other extension.
User extensions live in `~/.krill/extensions/<id>/` — see [extensions.md](extensions.md).

## Settings
`~/.krill/settings.json`, owned by the daemon (`settings.get` / `settings.set`, `event.settings`
on change, also when the file is edited by hand). Flat dotted keys, VS Code style.

## AI agents drive the IDE
Every agent session gets `KRILL_SOCKET` and the `krill` CLI on PATH; Claude Code sessions also get
the `krill` MCP server (`--mcp-config`). Both expose the same verbs: open files/URLs/terminals in the
editor area, read what the user is looking at, read/write settings, list/create/enable extensions,
run commands. "New Extension with AI…" scaffolds a folder and starts an agent on it; the app reloads
extensions when their files change.

## UI ↔ daemon
The app talks to the daemon only through JSON-RPC. IDE actions requested by agents go
`krill`/MCP → daemon `ui.*` → `event.ui` to the app. The app publishes what it shows with
`ui.publish` so agents can ask (`ui.state`).
