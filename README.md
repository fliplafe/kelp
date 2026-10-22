# Kelp

A native macOS IDE that balances a classic code editor and an agent-first workspace.

Editors like VS Code are built around a person writing code; agents come later, as a side panel. Agent apps like
Claude Desktop are built around a conversation; the code sits behind it, out of reach. Kelp is made for doing both at
once: several agents working side by side, and the code they touch always one tab away, to read, review and edit by
hand. And it stays a Mac app: Swift and AppKit, no Electron, no cloud.

## The idea

**Code you can see and change.** A source editor with language servers, a file tree with Finder's keys, diffs with
hunk staging, Markdown and notebooks, a browser whose Design Mode hands an element's source to an agent. Every tab — an
agent, a terminal, a file, a diff, a web page — goes into any split, so the layout follows the task.

**Agents, first class.** Any CLI agent: Claude Code, Codex, OpenCode, Gemini CLI, Cursor Agent, Pi, Amp, or any
command (agents are JSON files). Each shows whether it is working, waiting for you or done, and tells you when it needs
you; its changes come back as a diff you can comment on line by line. A background daemon (`kelpd`) owns the terminals,
so quitting the app doesn't stop the agents. GitHub, GitLab, Bitbucket, Linear and Jira are built in: start an agent
from an issue, review pull requests, follow CI. Agents drive Kelp too, through the `kelp` CLI: open files, run
commands, report progress.

**Flexible, not fixed.** Panels, tabs, commands, settings and themes come from extensions. A panel that shows what a
command prints is a JSON file; shared extensions install from Settings › Extensions › Library or `kelp ext install`.

**Native and light.** System controls and SF Symbols, the terminal on libghostty (GPU-rendered), web pages in the
system's WebKit. No Electron, no bundled Chromium or Node, no account, no cloud service, no telemetry: Kelp talks only
to the tools you set up (`git`, `gh`, `glab`, your agents) and to its update feed. Plain git underneath, so everything
can be checked from any terminal.

Requires macOS 14+.

## Install

Download `Kelp.dmg` from [Releases](https://github.com/nikiomori/kelp/releases/latest) and drag Kelp to Applications;
it updates itself (Kelp › Check for Updates…). Kelp's terminals have `kelp` on their PATH; for other terminals:
`ln -s /Applications/Kelp.app/Contents/MacOS/kelp /usr/local/bin/kelp`.

## Build and run

```sh
scripts/build-ghostty.sh         # once: libghostty into Vendor/ (downloads zig 0.16 into a cache)
swift build                      # everything
swift test                       # all tests
scripts/bundle.sh                # dist/Kelp.app + dist/Kelp.dmg (universal, release)
SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=kelp scripts/bundle.sh   # signed + notarized
scripts/publish.sh               # GitHub release + update feed for that DMG (bump the version in Resources/Info.plist first)
```

For quick iteration: `swift build && .build/debug/KelpApp` (the app starts `kelpd` next to it if needed).

## CLI

```sh
kelp status
kelp session new --agent claude                                # in the workspace of the current folder
kelp worktree create feat/login | list | current | note "half done"
kelp terminal list | read <id> | send <id> "run the tests" | context <id>
kelp diff | commit "msg" | merge | push
kelp install                                                   # run the daemon as a LaunchAgent
```

## Per-repo config: `.kelp.yaml`

```yaml
setup: npm install              # runs in every new worktree
shared: node_modules            # symlinked from the main checkout instead of reinstalling
tabs: claude, shell             # sessions opened in each new worktree
issueCommand: "Fix {title}: {body}"
recipe.commit: "Write a conventional commit for: {stagedPatch}"
```

`.worktreeinclude` lists gitignored files (globs) copied into new worktrees, e.g. `.env*`.

## Architecture

See [docs/architecture.md](docs/architecture.md). License: MIT.
