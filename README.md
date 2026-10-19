# Krill

A native macOS app for running many coding agents side by side — each in its own git worktree, with live status,
notifications, diff review, an editor, a browser with Design Mode, and GitHub/Linear built in. An open-source,
Swift + AppKit: no Electron, no cloud, no telemetry.

- **Any CLI agent.** Claude Code, Codex, OpenCode, Gemini CLI, Cursor Agent, Pi, Amp — or any command. Agents are JSON files.
- **Sessions outlive the window.** A background daemon (`krilld`) owns the terminals; quit the app and agents keep working.
- **Plain git.** Standard branches and `git worktree`; everything is checkable from a normal terminal.
- **Everything from the CLI.** `krill` drives the app, so agents can drive it too.

Requires macOS 14+.

## Build and run

```sh
swift build                      # everything
swift test                       # all tests
scripts/bundle.sh                # dist/Krill.app + dist/Krill.dmg (universal, release)
SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=krill scripts/bundle.sh   # signed + notarized
```

For quick iteration: `swift build && .build/debug/KrillApp` (the app starts `krilld` next to it if needed).

## CLI

```sh
krill status
krill task "Add a dark mode toggle to settings" --agent claude   # branch + worktree + agent, named from the prompt
krill worktree create feat/login | list | current | note "half done"
krill terminal list | read <id> | send <id> "run the tests" | context <id>
krill fanout "Fix the flaky test" --agents claude,codex
krill diff | commit "msg" | merge | push
krill install                                                   # run the daemon as a LaunchAgent
```

## Per-repo config: `.krill.yaml`

```yaml
setup: npm install              # runs in every new worktree
shared: node_modules            # symlinked from the main checkout instead of reinstalling
tabs: claude, shell             # sessions opened in each new worktree
issueCommand: "Fix {title}: {body}"
recipe.commit: "Write a conventional commit for: {stagedPatch}"
```

`.worktreeinclude` lists gitignored files (globs) copied into new worktrees, e.g. `.env*`.

## Architecture

See [AGENTS.md](AGENTS.md). License: MIT.
