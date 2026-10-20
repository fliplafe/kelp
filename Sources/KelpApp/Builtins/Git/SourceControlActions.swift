import AppKit
import Core
import GitKit

/// What the rows and buttons do: stage, commit, sync, branches, and the context menu.
extension SourceControlController {
    // MARK: actions

    func run(_ method: String, _ extra: [String: JSONValue] = [:], done: String? = nil) {
        guard let wid = worktreeId else { return }
        var p = extra; p["id"] = .string(wid)
        busy = true
        if method == "git.remote", let op = extra["op"]?.string {
            syncing = (op == "push" ? String(localized: "Pushing…") : op == "pull" ? String(localized: "Pulling…") : String(localized: "Fetching…"), op == "push")
        }
        Task {
            let r = await AppModel.shared.tryCall(method, .object(p))
            busy = false; syncing = nil
            if let e = r.error {
                // A rejected push or a pull that stopped on conflicts is work for the agent; other failures just say why.
                if method == "git.remote", extra["op"]?.string == "push" { GitFix.offer(e, recipe: "fixPush", worktree: wid) }
                else if method == "git.remote", extra["op"]?.string == "pull", e.lowercased().contains("conflict") {
                    GitFix.offer(e, recipe: "resolveConflicts", worktree: wid, vars: ["base": String(localized: "the remote branch"), "files": String(localized: "see git status")])
                } else { Banner.show(e, style: .error) }
            } else if let done { Banner.show(done) }
            reloadAll()
        }
    }

    private func stage(_ files: [FileChange], _ on: Bool) {
        run(on ? "git.stage" : "git.unstage", ["files": .array(files.map { .string($0.path) })])
    }

    private func discard(_ files: [FileChange]) {
        guard !files.isEmpty else { return }
        let a = NSAlert(); a.alertStyle = .warning
        let name = (files[0].path as NSString).lastPathComponent
        if files.count == 1, files[0].untracked {
            a.messageText = String(localized: "Delete “\(name)”?"); a.informativeText = String(localized: "Git doesn't track this file, so it can't be restored.")
            a.addButton(withTitle: String(localized: "Delete File")).hasDestructiveAction = true
        } else {
            a.messageText = files.count == 1 ? String(localized: "Discard changes in “\(name)”?") : String(localized: "Discard all \(files.count) changes?")
            a.informativeText = String(localized: "This can't be undone.") + (files.contains(where: \.untracked) ? String(localized: " Untracked files are deleted.") : "")
            a.addButton(withTitle: files.count == 1 ? String(localized: "Discard Changes") : String(localized: "Discard \(files.count) Changes")).hasDestructiveAction = true
        }
        a.addButton(withTitle: String(localized: "Cancel"))
        guard runAsSheet(a) == .alertFirstButtonReturn else { return }
        run("git.discard", ["files": .array(files.map { .string($0.path) })])
    }

    func sectionActions(_ s: Section, _ n: Node) -> [RowAction] {
        let files = n.files
        switch s {
        case .merge: return [RowAction("plus", "Stage All (Mark Resolved)") { [weak self] in self?.stage(files, true) }]
        case .staged: return [RowAction("minus", "Unstage All") { [weak self] in self?.stage(files, false) }]
        case .changes: return [RowAction("arrow.uturn.backward", "Discard All Changes") { [weak self] in self?.discard(files) },
                               RowAction("plus", "Stage All Changes") { [weak self] in self?.stage(files, true) }]
        case .graph: return [RowAction("arrow.clockwise", "Refresh") { [weak self] in Task { await self?.loadGraph() } }]
        }
    }

    func fileActions(_ f: FileChange, _ s: Section) -> [RowAction] {
        var a = [RowAction("doc", "Open File") { [weak self] in self?.openFile(f) }]
        switch s {
        case .staged: a.append(RowAction("minus", "Unstage Changes") { [weak self] in self?.stage([f], false) })
        case .changes:
            a.append(RowAction("arrow.uturn.backward", "Discard Changes") { [weak self] in self?.discard([f]) })
            a.append(RowAction("plus", "Stage Changes") { [weak self] in self?.stage([f], true) })
        case .merge: a.append(RowAction("plus", "Stage (Mark Resolved)") { [weak self] in self?.stage([f], true) })
        case .graph: break
        }
        return a
    }

    @objc func commitPressed() { commit(push: false, amend: false) }

    func commit(push: Bool, amend: Bool) {
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wid = worktreeId, !busy, !changes.isEmpty || amend else { NSSound.beep(); return }
        // No message yet: a page to write it on, as in VS Code (amending starts from the last commit's message).
        guard !text.isEmpty else {
            let last = amend ? commits.first { $0.hash.hasPrefix(info?.head ?? "\u{0}") }?.subject : nil
            Workbench.open(CommitMessageTab.uri(wid, push: push, amend: amend, message: last)); return
        }
        busy = true
        if push { syncing = (String(localized: "Pushing…"), true) }
        Task {
            if await GitCommit.run(wid, message: text, push: push, amend: amend) { message.string = ""; messageChanged() }
            busy = false; syncing = nil
            reloadAll()
        }
    }

    @objc func sync() {
        guard let info else { return }
        if info.upstream == nil { run("git.remote", ["op": "push"], done: String(localized: "Published \(info.current ?? "HEAD")")); return }
        guard let wid = worktreeId else { return }
        busy = true; syncing = (String(localized: "Syncing…"), (info.ahead ?? 0) > 0)
        Task {
            if await AppModel.shared.call("git.remote", .obj(["id": .string(wid), "op": "pull"])) != nil {
                if (info.ahead ?? 0) > 0 { _ = await AppModel.shared.call("git.remote", .obj(["id": .string(wid), "op": "push"])) }
            }
            busy = false; syncing = nil; reloadAll()
        }
    }

    @objc func branchMenu() {
        guard let info else { return }
        let m = NSMenu()
        for b in info.local {
            let i = m.add(b) { [weak self] in self?.run("git.switch", ["branch": .string(b)]) }
            i.state = b == info.current ? .on : .off
        }
        if !info.remote.isEmpty {
            let sub = NSMenu()
            for b in info.remote { sub.add(b) { [weak self] in self?.run("git.switch", ["branch": .string(b), "remote": true]) } }
            m.addItem(.separator())
            let r = m.addItem(withTitle: String(localized: "Remote Branches"), action: nil, keyEquivalent: ""); r.submenu = sub
        }
        m.addItem(.separator())
        m.add(String(localized: "Create Branch…")) { [weak self] in
            guard let name = prompt(String(localized: "Create Branch"), String(localized: "Starts from \(info.current ?? "HEAD") and switches to it.")), !name.isEmpty else { return }
            self?.run("git.switch", ["branch": .string(name), "create": true])
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: branchButton.bounds.height + 4), in: branchButton)
    }

    func showMoreMenu() {
        guard let wid = worktreeId else { return }
        let m = NSMenu()
        m.add(String(localized: "Pull")) { [weak self] in self?.run("git.remote", ["op": "pull"], done: String(localized: "Pulled")) }
        m.add(String(localized: "Push")) { [weak self] in self?.run("git.remote", ["op": "push"], done: String(localized: "Pushed")) }
        m.add(String(localized: "Fetch")) { [weak self] in self?.run("git.remote", ["op": "fetch"]) }
        m.addItem(.separator())
        m.add(String(localized: "Stash Changes")) { [weak self] in self?.run("git.stash", done: String(localized: "Changes stashed")) }
        m.add(String(localized: "Pop Stash")) { [weak self] in self?.run("git.stash", ["pop": true]) }
        m.addItem(.separator())
        m.add(String(localized: "Open All Changes")) { Workbench.open(DiffTab.uri(wid)) }
        m.add(String(localized: "Create Pull Request…")) { PRActions.create(worktree: wid) }
        if let w = AppModel.shared.worktree(wid), let r = AppModel.shared.repo(w.repoId), w.path != r.path {
            m.add(String(localized: "Merge into \(r.baseBranch)…")) { [weak self] in self?.mergeIntoBase() }
        }
        let anchor: NSView = moreButton ?? view
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    /// A workspace on its own branch (worktree) into the project's base branch.
    private func mergeIntoBase() {
        guard let wid = worktreeId else { return }
        Task {
            guard let r = await AppModel.shared.call("git.merge", .obj(["id": .string(wid)])) else { return }
            if r["merged"]?.bool == true { Banner.show(String(localized: "Merged")); await AppModel.shared.refresh(); return }
            let files = (r["conflicts"]?.array ?? []).compactMap(\.string)
            let a = NSAlert(); a.messageText = String(localized: "Merge Conflicts"); a.alertStyle = .warning
            a.informativeText = files.joined(separator: "\n") + String(localized: "\n\nThe merge was aborted; nothing changed.")
            a.addButton(withTitle: String(localized: "OK"))
            if FileActions.targetAgent != nil { a.addButton(withTitle: String(localized: "Ask Agent to Resolve")) }
            if await runSheet(a) == .alertSecondButtonReturn, let w = AppModel.shared.worktree(wid), let repo = AppModel.shared.repo(w.repoId) {
                GitFix.send("resolveConflicts", worktree: wid, vars: ["base": repo.baseBranch, "files": files.joined(separator: ", ")])
            }
        }
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let o = menu === graphOutline.menu ? graphOutline : outline
        guard let n = o.item(atRow: o.clickedRow) as? Node else { return }
        switch n.kind {
        case .file(let f, let s):
            if s != .merge { menu.add(String(localized: "Open Changes")) { [weak self] in self?.open(f, s) } }
            menu.add(String(localized: "Open File")) { [weak self] in self?.openFile(f) }
            menu.addItem(.separator())
            for a in fileActions(f, s).dropFirst() { menu.add(a.title) { a.run() } }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.path, forType: .string) }
        case .commit(let i):
            let c = commits[i]
            menu.add(String(localized: "Copy Commit Hash")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.hash, forType: .string) }
            menu.add(String(localized: "Copy Commit Message")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.subject, forType: .string) }
        case .commitFile(let h, let f):
            menu.add(String(localized: "Open Changes")) { [weak self] in if let w = self?.worktreeId { Workbench.open(DiffTab.uri(w, file: f.path, commit: h)) } }
            menu.add(String(localized: "Open File")) { [weak self] in self?.openFile(f) }
        default: break
        }
    }
}
