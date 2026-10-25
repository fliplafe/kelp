import AppKit
import Core

/// What the branch chip opens: where the branch stands against its upstream, what a pull or push would move, the buttons
/// that do it, and a line to commit what's changed. Everything bigger (staging, history, diffs) stays in Source Control.
@MainActor
final class SyncPopover: NSViewController {
    private static let width: CGFloat = 332, shown = 5
    private static let times: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static let captionAttributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.ui(11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.4]

    private let app: AppModel
    private let wid: String
    weak var popover: NSPopover?

    private let name = NSTextField(labelWithString: ""), upstream = NSTextField(labelWithString: "")
    private let switchButton = NSButton(title: String(localized: "Switch"), target: nil, action: nil)
    private lazy var pull = button(String(localized: "Pull")) { [weak self] in self?.sync(["pull"]) }
    private lazy var push = button(String(localized: "Push")) { [weak self] in self?.sync(["push"]) }
    private lazy var fetch = button("") { [weak self] in self?.sync(["fetch"]) }
    private lazy var retry = button(String(localized: "Pull, then push")) { [weak self] in self?.sync(["pull", "push"]) }
    private lazy var commit = button(String(localized: "Commit")) { [weak self] in self?.commitPressed() }
    private let busy = NSProgressIndicator(), note = NSTextField(wrappingLabelWithString: ""), status = NSStackView()
    private let outgoing = NSStackView(), incoming = NSStackView(), upToDate = NSTextField(labelWithString: "")
    private let changes = NSTextField(labelWithString: ""), message = NSTextField()
    private let changeBlock = NSStackView()
    private let root = NSStackView()

    private var unsynced: Unsynced?
    private var listKey = ""
    private var result: (text: String, failed: Bool, rejected: Bool)?
    private var showIncoming = false, committing = false

    init(app: AppModel, worktree: String) {
        self.app = app
        wid = worktree
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    override func loadView() {
        name.font = .ui(14, weight: .semibold)
        upstream.font = .ui(12)
        upstream.textColor = .secondaryLabelColor
        for l in [name, upstream] {
            l.lineBreakMode = .byTruncatingMiddle
            l.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        }
        switchButton.bezelStyle = .rounded
        switchButton.controlSize = .small
        switchButton.target = self
        switchButton.action = #selector(switchMenu)
        let head = NSStackView(views: [column([name, upstream], spacing: 1), switchButton])
        head.spacing = 8

        fetch.image = .symbol("arrow.clockwise", String(localized: "Fetch"))
        fetch.toolTip = String(localized: "Fetch")
        let actions = NSStackView(views: [pull, push, fetch])
        actions.spacing = 8
        NSLayoutConstraint.activate([push.widthAnchor.constraint(equalTo: pull.widthAnchor), fetch.widthAnchor.constraint(equalToConstant: 36)])

        busy.style = .spinning
        busy.controlSize = .small
        note.font = .ui(12)
        note.maximumNumberOfLines = 4
        note.preferredMaxLayoutWidth = Self.width - 22
        retry.controlSize = .small
        status.setViews([busy, note], in: .top)
        status.spacing = 6
        status.alignment = .top

        for s in [outgoing, incoming] {
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 2
        }
        upToDate.font = .ui(12)
        upToDate.textColor = .secondaryLabelColor

        message.placeholderString = String(localized: "Commit message")
        message.delegate = self
        message.target = self
        message.action = #selector(commitPressed)
        let field = NSStackView(views: [message, commit])
        field.spacing = 8
        field.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        changes.font = .ui(12)
        changeBlock.orientation = .vertical
        changeBlock.alignment = .leading
        changeBlock.spacing = 8
        changeBlock.setViews([rule(), changes, field], in: .top)

        let open = ClosureButton(title: String(localized: "Open Source Control")) { [weak self] in
            self?.app.workbench.showPanel("git.changes")
            self?.popover?.performClose(nil)
        }
        open.isBordered = false
        open.attributedTitle = NSAttributedString(string: open.title,
                                                  attributes: [.font: NSFont.ui(12, weight: .medium), .foregroundColor: NSColor.controlAccentColor])

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        root.setViews([head, actions, status, retry, outgoing, incoming, upToDate, changeBlock, rule(), open], in: .top)
        root.setCustomSpacing(8, after: status)
        for v in [head, actions, status] as [NSView] { v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app, wid] in app.git[wid] } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app, wid] in app.syncing[wid] } changed: { [weak self] _ in self?.update() }
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.bezelStyle = .push
        b.imagePosition = .imageLeading
        return b
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        return s
    }

    private func rule() -> NSView {
        let r = NSBox()
        r.boxType = .separator
        r.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return r
    }

    private func label(_ text: String, size: CGFloat = 12, secondary: Bool = true) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .ui(size)
        l.textColor = secondary ? .secondaryLabelColor : .labelColor
        return l
    }

    // MARK: state

    private func update() {
        let info = app.git[wid]?.branches, running = app.syncing[wid]
        let ahead = info?.ahead ?? 0, behind = info?.behind ?? 0, published = info?.upstream != nil
        let hasRemote = published || !(info?.remote.isEmpty ?? true)
        name.stringValue = info?.current ?? info?.head ?? "HEAD"
        upstream.stringValue = info?.upstream ?? (hasRemote ? String(localized: "Not published yet") : String(localized: "No remote branch yet"))
        switchButton.isEnabled = info != nil && running == nil

        let idle = running == nil && info?.current != nil && hasRemote
        pull.isHidden = !published
        fetch.isHidden = !hasRemote
        push.isHidden = !hasRemote
        let pushFirst = behind == 0 && (ahead > 0 || !published)
        show(pull, published ? String(localized: "Pull") : "", count: behind, symbol: "arrow.down", prominent: behind > 0)
        show(push, published ? String(localized: "Push") : String(localized: "Publish Branch"), count: published ? ahead : 0,
             symbol: published ? "arrow.up" : "icloud.and.arrow.up", prominent: pushFirst)
        pull.isEnabled = idle && behind > 0
        push.isEnabled = idle && (ahead > 0 || !published)
        fetch.isEnabled = idle

        showStatus(running)
        loadLists(info)
        showLists(ahead: ahead, behind: behind, published: published, upstream: info?.upstream)
        showChanges()
        preferredContentSize = root.fittingSize
    }

    private func show(_ b: NSButton, _ title: String, count: Int, symbol: String, prominent: Bool) {
        let text = count > 0 ? "\(title) \(count)" : title
        let color: NSColor = prominent ? .white : .labelColor
        b.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: NSFont.ui(13)])
        b.image = .symbol(symbol, title)
        b.bezelColor = prominent ? .controlAccentColor : nil
        b.contentTintColor = prominent ? .white : nil
        b.setAccessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }

    private func showStatus(_ running: String?) {
        busy.isHidden = running == nil
        if let running {
            busy.startAnimation(nil)
            note.stringValue = running
            note.textColor = .secondaryLabelColor
        } else {
            busy.stopAnimation(nil)
            note.stringValue = result?.text ?? ""
            note.textColor = result?.failed == true ? .systemRed : .secondaryLabelColor
        }
        note.isHidden = note.stringValue.isEmpty
        retry.isHidden = !(running == nil && result?.failed == true && result?.rejected == true)
        status.isHidden = note.isHidden
    }

    /// The commits behind the counts, read again when the head, the upstream or a count moves (a fetch, a commit, a push).
    private func loadLists(_ info: BranchInfo?) {
        guard let b = info else { return }
        let key = "\(b.head ?? "")|\(b.upstream ?? "")|\(b.ahead ?? -1)|\(b.behind ?? -1)"
        guard key != listKey else { return }
        listKey = key
        Task {
            let u = await app.quiet(GitUnsynced(id: wid, limit: Self.shown))
            guard key == listKey else { return }
            unsynced = u
            update()
        }
    }

    private func showLists(ahead: Int, behind: Int, published: Bool, upstream: String?) {
        let out = unsynced?.outgoing ?? [], inc = unsynced?.incoming ?? []
        outgoing.isHidden = ahead == 0
        incoming.isHidden = behind == 0
        upToDate.isHidden = !(published && ahead == 0 && behind == 0)
        upToDate.stringValue = String(localized: "Up to date with \(upstream ?? "")")

        let title = published ? String(localized: "To push") : String(localized: "Not on a remote yet")
        outgoing.setViews([caption(title, ahead)] + out.map { row($0, trailing: when($0)) } + more(ahead - out.count), in: .top)

        let toggle = ClosureButton(title: "") { [weak self] in
            guard let self else { return }
            showIncoming.toggle()
            update()
        }
        toggle.isBordered = false
        toggle.attributedTitle = NSAttributedString(string: String(localized: "To pull").uppercased() + " · \(behind)", attributes: Self.captionAttributes)
        toggle.image = .symbol(showIncoming ? "chevron.down" : "chevron.right", String(localized: "To pull"))
        toggle.imagePosition = .imageLeading
        toggle.contentTintColor = .secondaryLabelColor
        let rows = showIncoming ? inc.map { row($0, trailing: $0.author) } + more(behind - inc.count) : []
        incoming.setViews([toggle] + rows, in: .top)
    }

    private func caption(_ text: String, _ n: Int) -> NSView {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text.uppercased() + " · \(n)", attributes: Self.captionAttributes)
        return l
    }

    private func when(_ c: Unsynced.Commit) -> String {
        Self.times.localizedString(for: Date(timeIntervalSince1970: c.date), relativeTo: Date())
    }

    private func more(_ n: Int) -> [NSView] { n > 0 ? [label(String(localized: "and \(n) more"))] : [] }

    private func row(_ c: Unsynced.Commit, trailing: String) -> NSView {
        let hash = label(c.hash, size: 11)
        hash.font = .monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular)
        let subject = label(c.subject, secondary: false)
        subject.lineBreakMode = .byTruncatingTail
        subject.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let r = NSStackView(views: [hash, subject, label(trailing, size: 11)])
        r.spacing = 8
        hash.widthAnchor.constraint(equalToConstant: 56).isActive = true
        r.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return r
    }

    private func showChanges() {
        let list = app.git[wid]?.changes ?? [], n = list.count
        let words = n == 1 ? String(localized: "1 uncommitted change") : String(localized: "\(n) uncommitted changes")
        let text = NSMutableAttributedString(string: n == 0 ? String(localized: "No uncommitted changes") : words,
                                             attributes: [.font: NSFont.ui(12), .foregroundColor: n == 0 ? NSColor.secondaryLabelColor : .labelColor])
        if n > 0, let s = app.git[wid]?.stats {
            let mono = NSFont.monospacedSystemFont(ofSize: TextSize.of(11), weight: .regular)
            for (count, sign, color) in [(s.totalAdded, "+", NSColor.systemGreen), (s.totalRemoved, "−", .systemRed)] where count > 0 {
                text.append(NSAttributedString(string: "   \(sign)\(count)", attributes: [.font: mono, .foregroundColor: color]))
            }
        }
        changes.attributedStringValue = text
        for v in changeBlock.arrangedSubviews where v !== changes && !(v is NSBox) { v.isHidden = n == 0 }
        let blocked = list.contains(where: \.conflicted) || app.syncing[wid] != nil || committing
        commit.isEnabled = !message.stringValue.trimmingCharacters(in: .whitespaces).isEmpty && !blocked
        message.isEnabled = !committing
    }

    // MARK: actions

    private func sync(_ ops: [String]) {
        guard app.syncing[wid] == nil else { return }
        let before = app.git[wid]?.branches, ahead = before?.ahead ?? 0, behind = before?.behind ?? 0
        let published = before?.upstream != nil, branch = before?.current ?? "HEAD"
        result = nil
        Task {
            if let error = await GitSync.run(app, wid, ops) {
                failed(error, ops: ops)
            } else if ops.contains("push") {
                let text = !published ? String(localized: "Published \(branch).")
                    : ahead == 1 ? String(localized: "Pushed 1 commit.") : String(localized: "Pushed \(max(ahead, 1)) commits.")
                result = (text, false, false)
            } else if ops.contains("pull") {
                result = (behind == 1 ? String(localized: "Pulled 1 commit.") : String(localized: "Pulled \(behind) commits."), false, false)
            }
            update()
        }
    }

    /// A pull that stopped on conflicts is work for the agent (and for Source Control); anything else says why, here.
    private func failed(_ error: String, ops: [String]) {
        guard ops.contains("pull"), error.lowercased().contains("conflict") else {
            result = (Self.summary(error), true, GitSync.isRejected(error))
            return
        }
        popover?.performClose(nil)
        GitFix(app).offer(error, recipe: "resolveConflicts", worktree: wid,
                          vars: ["base": String(localized: "the remote branch"), "files": String(localized: "see git status")])
        app.workbench.showPanel("git.changes")
    }

    /// Git's message in a few lines: the pieces of a long push or pull report that say why.
    private static func summary(_ error: String) -> String {
        if GitSync.isRejected(error) { return String(localized: "Push rejected: the remote has commits this branch doesn't. Pull first.") }
        let lines = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let useful = lines.filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
        return (useful.isEmpty ? lines : useful).prefix(3).joined(separator: "\n")
            .replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: "")
    }

    @objc private func commitPressed() {
        let text = message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.isEnabled, !text.isEmpty else { return }
        committing = true
        update()
        Task {
            defer {
                committing = false
                app.watchAgain(.git, wid)
                update()
            }
            // Read now, not from the last push: unread, nothing would look staged and every change would go in.
            guard let status = await app.call(GitStatus(id: wid)) else { return }
            let all = !status.contains { $0.staged && !$0.conflicted }
            let r = await app.tryCall(GitCommit(id: wid, message: text, all: all))
            if let e = r.error { GitFix(app).offer(e, recipe: "fixCommit", worktree: wid) } else { message.stringValue = "" }
        }
    }

    /// The local branches to switch to, and a new one; the remote ones are in Source Control.
    @objc private func switchMenu() {
        guard let info = app.git[wid]?.branches else { return }
        let m = NSMenu(), wid = wid
        for b in info.local {
            m.add(b) { [weak self] in self?.switchBranch(GitSwitch(id: wid, branch: b)) }.state = b == info.current ? .on : .off
        }
        m.addItem(.separator())
        m.add(String(localized: "Create Branch…")) { [weak self] in
            Task {
                let starts = String(localized: "Starts from \(info.current ?? "HEAD") and switches to it.")
                guard let name = await prompt(String(localized: "Create Branch"), starts), !name.isEmpty else { return }
                self?.switchBranch(GitSwitch(id: wid, branch: name, create: true))
            }
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: switchButton.bounds.height + 4), in: switchButton)
    }

    private func switchBranch(_ m: GitSwitch) {
        Task {
            await app.call(m)
            app.watchAgain(.git, m.id)   // the chip now, not on the next file event
        }
    }
}

extension SyncPopover: NSTextFieldDelegate {
    func controlTextDidChange(_ n: Notification) { showChanges() }
}
