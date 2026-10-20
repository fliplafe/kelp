# Kelp architecture

Kelp is a thin native shell around two things: a **daemon** that owns everything stateful
(agent sessions/PTYs, git, integrations, settings) and **extensions** that contribute almost
everything you see. The app itself only provides the window, the layout, a registry of
contributions, the command palette and settings.

```
┌ Sidebar ────────┐┌ Editor area ─────────────────────────────┐┌ Inspector ──────┐
│ Project       + ││ [Claude ●][Terminal][app.ts][Browser]    ││ ▤  ⎇  ☰  …      │
│  ▾ Workspace 1  ││ ┌──────────────────┬──────────────────┐  ││ Files / Source  │
│     ✻ Claude ⚙  ││ │ agent terminal   │ file / browser / │  ││ Control / Issues│
│     ✻ Codex ?   ││ │                  │ diff / ext view  │  ││ + extension     │
│  ▸ Workspace 2 ✓││ └──────────────────┴──────────────────┘  ││   panels        │
│ Limits          ││   groups split freely, tabs of any kind  ││                 │
└─────────────────┘└──────────────────────────────────────────┘└─────────────────┘
```

## Concepts
- **Project**: a git repository (`repo.*` RPCs).
- **Workspace**: a desk in the project's folder — its own tabs, splits and agents, nothing on disk
  (`workspace.create`, stored as worktree records whose path is the repo path). "+" opens a new one instantly,
  named "Workspace N" until its first agent prompt names it; several desks share the folder.
  Closing one ends its agents and leaves the files. (Workspaces from older versions may be git worktrees.)
- **Agent**: a session in a workspace (`session.*`). Status: working · needs input · done · idle · paused · ended.
- **Tab**: anything shown in the editor area, addressed by a URI:
  `session:<id>`, `file:<path>#L12`, `diff:<path>`, `https://…`, `ext:<extension>/<view>`.
  Groups of tabs split right/down; drag tabs between groups or onto an edge to split.

## Contribution points (built-in Swift extensions and `extension.json` folders use the same ones)
| Point | Where it shows |
| --- | --- |
| panels | right inspector (selector icons) |
| editors | center tab types, listed in each pane's "+" menu and the empty workspace |
| commands | command palette (⇧⌘P), menus, key bindings, `kelp run <id>` |
| settings | Settings window (generated forms) and `~/.kelp/settings.json` |
| themes | Appearance settings; drive terminal + editor colors |
| agents | agent CLIs offered in the "+" menu and the empty workspace |

Every action of the app is a command with an id (`workbench.toggleSidebar`, `editor.saveAll`, `agents.new`…), as in
VS Code and Zed: the menu bar is laid out by id (`AppDelegate.buildMenu`), settings.json `keys` rebinds by id, and agents
run the same ids with `kelp run`.

Built-ins (Git, Files, Issues, Browser) can be turned off like any other extension. Kelp ships no example
extensions: user extensions live in `~/.kelp/extensions/<id>/` — see [extensions.md](extensions.md) — and can be
turned off or removed.

## Source Control
The Git built-in is a VS Code-style Source Control panel (`Builtins/SourceControl.swift`): branch menu, commit box
(Commit / Commit & Push / Amend), Merge / Staged / Changes sections with stage, unstage and discard, and a history graph
whose lanes GitKit computes (`GitKit/History.swift`). Rows open `diff:` tabs, side by side or inline with hunk staging.
Git runs in the daemon (`Daemon/GitHandlers.swift`: `git.branches`, `git.switch`, `git.graph`, `git.commitFiles`,
`git.discard`, `git.remote`, `git.stash` …), never on the main thread.

## Settings
`~/.kelp/settings.json`, owned by the daemon (`settings.get` / `settings.set`, `event.settings`
on change, also when the file is edited by hand). Flat dotted keys, VS Code style.

## AI agents and the IDE: skills
Every agent session gets `KELP_SOCKET` and the `kelp` CLI on PATH (open files/URLs, settings, extensions,
`ui state`). What an agent should *do* with it comes from two skills the app writes as Claude Code plugins in
`~/.kelp/agent-skills/` (`AgentSkills`): **kelp-extensions** (this repo's docs/extensions.md: where an extension
goes, its format, how to reload) and **kelp-settings** (every setting key, generated from the registry, and how to
change it). The daemon loads that folder per Claude session with `--plugin-dir`; turning a skill off in
Settings › Agents removes it. Nothing is written to the agent's own config. The app reloads extensions when their
files change.

## UI ↔ daemon
The app talks to the daemon only through JSON-RPC. IDE actions requested by agents go
`kelp` → daemon `ui.*` → `event.ui` to the app. The app publishes what it shows with
`ui.publish` so agents can ask (`ui.state`).
