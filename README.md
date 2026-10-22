# Kelp

A native macOS IDE between a classic editor like VS Code and an agent app like Claude Desktop: agents work side by
side, and the code they touch is one tab away to read, review and edit.

![An agent's finished change next to its diff, Source Control on the right, every workspace's agents in the sidebar](docs/screenshots/agent-and-diff.png)

- **Code at hand.** Editor with language servers, file tree, diffs, browser; any tab in any split.
- **Agents first.** Claude Code, Codex, OpenCode, Gemini CLI and 15 more out of the box, or any CLI. Live status,
  review as a diff; agents keep working after you quit the app.
- **Git built in.** Source Control as in VS Code: stage or discard a hunk, commit, push, branch graph. Pull requests
  and CI from GitHub and GitLab; Linear and Jira issues.
- **Extensible.** Panels, commands and themes come from extensions; a JSON file is enough.
- **Native.** Swift + AppKit, terminal on libghostty. No Electron, no cloud, no telemetry.

![An agent waiting on a question; the sidebar counts who needs you](docs/screenshots/agent-asks.png)

## Install

Requires macOS 14+. Download `Kelp.dmg` from [Releases](https://github.com/nikiomori/kelp/releases/latest) and drag
Kelp to Applications; it updates itself (Kelp › Check for Updates…). Kelp's terminals have `kelp` on their PATH; for
other terminals: `ln -s /Applications/Kelp.app/Contents/MacOS/kelp /usr/local/bin/kelp`.

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

Everything the window does, `kelp` does too, so agents can drive Kelp as well (`kelp help` lists it all).

```sh
kelp status
kelp session new --agent claude                                # in the workspace of the current folder
kelp session new --cmd "npm test" --split down --wait          # a tab beside yours; exits with the command's code
kelp open Sources/App.swift:42 --split right                   # a tab in the app
kelp worktree create feat/login | list | current | note "half done"
kelp terminal list | read <id> | send <id> "run the tests" | context <id>
kelp diff | commit "msg" | merge | push
kelp ext search | install <id>                                 # the extension library
kelp install                                                   # run the daemon as a LaunchAgent
```

Claude Code sessions get Kelp's skills for this (Settings › Agents): ask the agent for a panel, a setting or a theme.

## Per-repo config: `.kelp.yaml`

```yaml
setup: npm install              # runs in every new worktree
shared: node_modules            # symlinked from the main checkout instead of reinstalling
tabs: claude, shell             # sessions opened in each new worktree
run: npm run dev                # Run menu: run / test / lint / build (⌘R, ⌘U); script.<name> for any other
test: npm test
issueCommand: "Fix {title}: {body}"
recipe.commit: "Write a conventional commit for: {stagedPatch}"
```

Its commands run only after you trust the project in Kelp, and ask again when the file changes.
`.worktreeinclude` lists gitignored files (globs) copied into new worktrees, e.g. `.env*`.

## Extensions

An extension is a folder with an `extension.json` in `~/.kelp/extensions`: a panel that shows what a command prints,
commands, settings, themes, agents. Format: [docs/extensions.md](docs/extensions.md). Ready ones are in the
[library](https://github.com/nikiomori/kelp-extensions) (Settings › Extensions › Library, or `kelp ext search`).

## Architecture

See [docs/architecture.md](docs/architecture.md). License: MIT.
