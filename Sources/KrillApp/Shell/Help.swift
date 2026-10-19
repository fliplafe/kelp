import Foundation
import Core

/// Help › How Krill Works: a short guide, opened as a Markdown tab.
enum Help {
    static let guide = """
    # How Krill works

    ## Projects, workspaces, agents
    - **Project** — a folder with a git repository (File › Add Project…, ⌘O). It's a section in the sidebar.
    - **Workspace** — a clean desk in that folder: its own tabs, splits and agents. **+** next to the project (⌘N) opens one
      at once; it's named after the first thing you ask an agent. Rename with a double-click; close with ⇧⌘W (agents stop,
      files stay). Several workspaces can work in the same folder.
    - **Agent** — Claude Code, Grok, Antigravity, Qwen… whatever is installed and runs on this Mac (found automatically).

    ## What the sidebar tells you
    | Mark | Means |
    | --- | --- |
    | spinner | working |
    | orange **?** | asked you something — needs your input |
    | green **✓** | finished; there's something new to look at (bold until you open it) |
    | ○ | ready for a task |
    | moon | paused to save memory — opens where it left off |

    Under each workspace: what its agents are doing. Under each agent: its state and what it did.

    ## The middle: tabs and splits
    The toolbar **+** opens an agent, a terminal, a browser or what extensions add. ⌘D splits right, ⇧⌘D down; drag a tab to
    an edge to split, between groups to move it. ⌘W closes a tab (in an empty workspace, the workspace).
    Edited files show a dot on their tab and in the window's close button; ⌘S saves.

    ## The right panel
    Files (⌥⌘1), Source Control (⌥⌘2) — changes, staging, commit, history graph; click a file for its diff — Issues, and
    panels from extensions.

    ## Extensions and agents
    Everything above is an extension; turn them off in Settings › Extensions. To add one, ask Claude Code in a tab:
    *"make a Krill panel that lists my Docker containers"*. It knows how through Krill's **skills** (Settings › Agents),
    which also let it change settings for you: *"switch Krill to the Dracula theme"*.

    ## Settings
    Krill › Settings… (⌘,) — or ~/.krill/settings.json, or `krill settings set <key> <value>` from any terminal.

    ## Shortcuts
    ⌘N workspace · ⌥⌘T agent · ⌘T terminal · ⇧⌘B browser · ⌘P open file · ⇧⌘P commands · ⌘D / ⇧⌘D split ·
    ⌘1…9 tabs · ⇧⌘] / ⇧⌘[ next / previous tab · ⌘] / ⌘[ next / previous group · ⌘0 sidebar · ⌥⌘0 right panel ·
    ⌘S save · ⌘W close tab · ⇧⌘W close workspace. Shortcuts work on any keyboard layout.
    """

    static var location: URL { Paths.root.appendingPathComponent("HELP.md") }

    /// Written next to the user's settings when opened, so it always matches this version.
    static var file: URL {
        try? guide.write(to: location, atomically: true, encoding: .utf8)
        return location
    }
}
