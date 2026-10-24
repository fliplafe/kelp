import AppKit
import Core
import WorkbenchKit

/// Over the projects, a zone of its own for the agents that need you: a heading that never changes height ("NEEDS YOU 3",
/// the count in the colour of the most urgent), then one line an agent as its tab in the list is (its project's icon, its
/// own, its name, when, its mark: needs you orange, failed red, done a green ✓). A click opens the agent, which then leaves
/// the zone; the pointer resting on one shows what it said last. The heading's chevron folds the zone to the heading.
/// On macOS 26 the zone is glass, lit while one asks; earlier, a card with its edge drawn then.
/// The zone hangs over the top of the list: no project moves when one comes or goes. A new question flashes the heading.
/// Nothing needs you: how many work. No agents at all: the heading goes.
@MainActor
final class AgentSummary: NSView {
    /// The heading's place in the layout: the list starts under it, the agents hang over the list.
    let line = NSLayoutGuide()
    /// The list the agents hang over, inset by as much: what they cover can be scrolled out from under them.
    weak var list: NSScrollView? { didSet { list?.automaticallyAdjustsContentInsets = false; update() } }
    private static let most = 6   // shown; more: "+N" in the heading (⇧⌘U walks them all)
    private static let foldedKey = "sidebar.needsYouFolded"
    private let rows = (0..<AgentSummary.most).map { _ in Row() }
    private let card = NSVisualEffectView(), zone = NSView()
    /// The zone's glass, where there is (macOS 26): it stands for the card and the zone.
    private let glass: NSView? = {
        guard #available(macOS 26, *) else { return nil }
        let g = NSGlassEffectView()
        g.cornerRadius = 10
        return g
    }()
    private let header = Pressable()
    private let mark = StatusMark(size: 11)   // nothing needs you: the working one's
    private let title = NSTextField(labelWithString: "")
    private let more = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var height: NSLayoutConstraint?, lineHeight: NSLayoutConstraint?
    private let app: AppModel
    private var shown: [Session] = []
    /// Questions already shown or looked at: one that isn't flashes the heading as it comes in.
    private var seen: Set<String>?
    private var folded = UserDefaults.standard.bool(forKey: AgentSummary.foldedKey)
    private let peek = Peek()
    private var settleTimer: Timer?

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10
        layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -3)
        // Over the list the zone is a card of its own, the rows under it blurred out.
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        for v in [card, zone, header] as [NSView] {
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            v.layer?.masksToBounds = true
        }
        title.lineBreakMode = .byTruncatingTail; title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        more.font = .uiDigits(11, weight: .medium); more.textColor = .secondaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold); chevron.contentTintColor = .secondaryLabelColor
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.button)
        header.press = { [weak self] in self?.fold() }
        let heading = NSStackView(views: [mark, title, NSView(), more, chevron])
        heading.spacing = 6
        heading.detachesHiddenViews = true
        addLayoutGuide(line)
        for x in [glass, card, zone, header].compactMap { $0 } + rows { x.translatesAutoresizingMaskIntoConstraints = false; addSubview(x) }
        heading.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(heading)
        let h = heightAnchor.constraint(equalToConstant: 0), lh = line.heightAnchor.constraint(equalToConstant: 0)
        height = h; lineHeight = lh
        var all = [h, lh, line.topAnchor.constraint(equalTo: topAnchor),
                   line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
                   header.topAnchor.constraint(equalTo: line.topAnchor), header.bottomAnchor.constraint(equalTo: line.bottomAnchor),
                   header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
                   heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
                   heading.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
                   heading.centerYAnchor.constraint(equalTo: header.centerYAnchor)]
        for v in [glass, card, zone].compactMap({ $0 }) {
            all += [v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
                    v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor)]
        }
        for (i, r) in rows.enumerated() {   // one under another; a hidden one is 0 high
            all += [r.topAnchor.constraint(equalTo: i == 0 ? line.bottomAnchor : rows[i - 1].bottomAnchor),
                    r.leadingAnchor.constraint(equalTo: leadingAnchor), r.trailingAnchor.constraint(equalTo: trailingAnchor)]
        }
        NSLayoutConstraint.activate(all)
        track(owner: self) { [app] in app.sessions } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app] in app.workbench.focusedTab } changed: { [weak self] _ in self?.update() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }   // the layers' colours

    func update() {
        var inbox = Inbox(queue: AttentionQueue(app).sessions)
        let tab = app.workbench.focusedTab ?? ""
        if TabURI.scheme(tab) == "session" { inbox.viewing = [TabURI.body(tab)] }
        shown = inbox.shown
        settleTimer?.invalidate(); settleTimer = nil
        if let due = inbox.settlesAt {
            settleTimer = Timer.scheduledTimer(withTimeInterval: due.timeIntervalSinceNow, repeats: false) { [weak self] _ in   // main run loop
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let agents = app.sessions.filter { $0.agent != "shell" && $0.status != .exited }
        let asks = { (s: Session) in SidebarCell.shownStatus(s) != .done }
        let asking = shown.filter(asks)
        let questions = Set(inbox.queue.filter(asks).map(\.id))
        let new = seen.map { s in asking.filter { !s.contains($0.id) }.map(\.id) } ?? []
        seen = (seen ?? questions).union(asking.map(\.id)).union(inbox.viewing).intersection(questions)

        isHidden = agents.isEmpty && shown.isEmpty
        let n = folded ? 0 : min(shown.count, Self.most), row = TextSize.of(30)
        let hang = n == 0 ? 0 : row * CGFloat(n) + 4
        lineHeight?.constant = isHidden ? 0 : TextSize.of(28); height?.constant = isHidden ? 0 : TextSize.of(28) + hang
        hangOver(hang)
        let glassy = glass != nil
        for v in [card, zone] as [NSView] { v.isHidden = shown.isEmpty || glassy }
        glass?.isHidden = shown.isEmpty || !glassy
        layer?.shadowOpacity = shown.isEmpty || glassy ? 0 : 0.2
        if #available(macOS 26, *), let g = glass as? NSGlassEffectView {   // one asks: the glass lit, not coloured
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            g.tintColor = asking.isEmpty ? nil : NSColor.white.withAlphaComponent(dark ? 0.1 : 0.45)
        }
        // One that asks: the zone a shade lighter, its edge drawn.
        zone.layer?.backgroundColor = resolved(.labelColor.withAlphaComponent(asking.isEmpty ? 0.05 : 0.09))
        zone.layer?.borderColor = resolved(.labelColor.withAlphaComponent(asking.isEmpty ? 0.08 : 0.2)); zone.layer?.borderWidth = 1

        more.isHidden = folded || shown.count <= Self.most; more.stringValue = "+\(shown.count - Self.most)"
        chevron.isHidden = shown.isEmpty
        chevron.image = .symbol(folded ? "chevron.right" : "chevron.down")
        header.toolTip = shown.isEmpty ? nil : folded ? String(localized: "Expand") : String(localized: "Collapse")
        if shown.isEmpty {
            let busy = agents.filter { $0.status == .working }.count
            mark.status = busy > 0 ? .working : nil; mark.isHidden = busy == 0
            title.attributedStringValue = NSAttributedString(string: busy > 0 ? String(localized: "\(busy) working") : "",
                                                             attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.secondaryLabelColor])
            header.setAccessibilityLabel(title.stringValue)
        } else {
            mark.isHidden = true
            let t = NSMutableAttributedString(string: String(localized: "Needs You").uppercased(),
                                              attributes: [.font: NSFont.ui(11, weight: .bold), .foregroundColor: NSColor.labelColor, .kern: 0.5])
            let urgent = AgentStatus.mostUrgent(shown.map(SidebarCell.shownStatus)) ?? .done
            t.append(NSAttributedString(string: "  \(shown.count)",
                                        attributes: [.font: NSFont.uiDigits(11, weight: .bold), .foregroundColor: glassy ? .labelColor : Row.tint(urgent)]))
            title.attributedStringValue = t
            header.setAccessibilityLabel(String(localized: "\(shown.count) need you"))
        }

        for (i, r) in rows.enumerated() {
            r.isHidden = i >= n; r.height.constant = i < n ? row : 0
            guard i < n else { continue }
            let s = shown[i]
            r.show(s, app: app) { [app] in app.workbench.focus(session: s.id) }
            r.hover = { [weak self, weak r] on in
                guard let self, let r else { return }
                if on { peek.show(s, app: app, by: r) } else { peek.hide() }
            }
            if new.contains(s.id) {
                r.alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.3; r.animator().alphaValue = 1 }
            }
        }
        if n == 0 { peek.hide() }
        if !new.isEmpty { flash() }
    }

    /// The chevron: the zone down to its heading, or open again; kept across launches.
    private func fold() {
        guard !shown.isEmpty else { return }
        folded.toggle(); UserDefaults.standard.set(folded, forKey: Self.foldedKey)
        update()
    }

    /// A question came in: the heading lights up and fades back.
    private func flash() {
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = resolved(.labelColor.withAlphaComponent(0.3)); a.toValue = NSColor.clear.cgColor
        a.duration = 1.2; a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        header.layer?.add(a, forKey: "flash")
    }

    /// The rows under the agents keep their place: the list is inset by what hangs over it, without scrolling.
    private func hangOver(_ h: CGFloat) {
        guard let list, list.contentInsets.top != h else { return }
        let clip = list.contentView, y = clip.bounds.origin.y
        list.contentInsets.top = h
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(y, -h)))
        list.reflectScrolledClipView(clip)
    }
    override func scrollWheel(with e: NSEvent) { list?.scrollWheel(with: e) }   // it lies over the list: scrolling it is scrolling that

    /// "Needs permission to use Bash · fix-login": what happened before where.
    static func what(_ s: Session, app: AppModel) -> String {
        let place = app.worktree(s.worktreeId)?.displayName ?? ""
        let what = s.summary.isEmpty ? SidebarCell.shownStatus(s).words : s.summary   // paused with news: "Done", not "Paused"
        return what + (place.isEmpty ? "" : " · " + place)
    }
}

private extension NSView {
    /// A colour as this view's appearance draws it, for a layer.
    func resolved(_ c: NSColor) -> CGColor {
        var r = c.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { r = c.cgColor }
        return r
    }
}

/// A view a click or VoiceOver presses.
@MainActor
private class Pressable: NSView {
    var press: () -> Void = {}
    override func mouseDown(with e: NSEvent) { press() }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}

/// One agent in the zone, as its tab in the list is (its project's icon, its own, its name, when, its mark), done a green ✓.
@MainActor
private final class Row: Pressable {
    private let project = NSImageView(), icon = NSImageView(), mark = StatusMark(size: 14)
    private let name = NSTextField(labelWithString: ""), ago = NSTextField(labelWithString: "")
    var height: NSLayoutConstraint!
    /// The pointer came to rest on it (true) or left (false).
    var hover: (Bool) -> Void = { _ in }
    private var rest: Timer?

    init() {
        super.init(frame: .zero)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.usesSingleLineMode = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ago.font = .uiDigits(11); ago.textColor = .secondaryLabelColor
        ago.setContentHuggingPriority(.required, for: .horizontal); ago.setContentCompressionResistancePriority(.required, for: .horizontal)
        mark.doneTint = Self.tint(.done)
        for x in [project, icon, name, ago, mark] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; addSubview(x) }
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            project.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), project.centerYAnchor.constraint(equalTo: centerYAnchor),
            project.widthAnchor.constraint(equalToConstant: 16), project.heightAnchor.constraint(equalToConstant: 16),
            icon.leadingAnchor.constraint(equalTo: project.trailingAnchor, constant: 5), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            ago.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6), ago.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            mark.leadingAnchor.constraint(equalTo: ago.trailingAnchor, constant: 6), mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Needs you orange, failed red, done green.
    static func tint(_ s: AgentStatus) -> NSColor { s == .done ? .textGreen : s == .error ? .textRed : .textOrange }

    func show(_ s: Session, app: AppModel, press: @escaping () -> Void) {
        let repo = app.repo(app.worktree(s.worktreeId)?.repoId)
        if let repo { ProjectIcon.show(repo.path, in: project) } else { project.image = nil }
        project.contentTintColor = .secondaryLabelColor
        icon.image = app.catalog.icon(s.agent, size: 16); icon.contentTintColor = .secondaryLabelColor
        name.stringValue = app.catalog.displayName(s); name.font = .ui(13, weight: s.unread ? .semibold : .regular)
        ago.stringValue = shortAgo(s.statusAt ?? s.createdAt)
        mark.status = SidebarCell.shownStatus(s); mark.unread = true   // read or not, it's here to be seen
        setAccessibilityLabel([repo?.name, name.stringValue, AgentSummary.what(s, app: app)].compactMap { $0 }.joined(separator: ", "))
        self.press = press
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) {
        rest = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hover(true) } }
    }
    override func mouseExited(with e: NSEvent) {
        rest?.invalidate()
        rest = nil
        hover(false)
    }
    override func mouseDown(with e: NSEvent) {
        rest?.invalidate()
        hover(false)
        press()
    }
}

/// What an agent said last, in a bubble beside its row: the last lines of its reply, else of what it printed.
@MainActor
private final class Peek {
    private let popover = NSPopover()
    private let text = NSTextField(wrappingLabelWithString: "")
    private var asked: String?
    private static let width: CGFloat = 320, pad = NSSize(width: 12, height: 10)

    init() {
        text.font = .ui(12); text.textColor = .labelColor
        let vc = NSViewController()
        vc.view = NSView()
        vc.view.addSubview(text)
        popover.contentViewController = vc
        popover.behavior = .applicationDefined
        popover.animates = false
    }

    func show(_ s: Session, app: AppModel, by row: NSView) {
        asked = s.id
        Task { @MainActor in
            var said = await app.quiet(SessionLastReply(id: s.id)) ?? nil
            if said?.isEmpty != false { said = await app.quiet(SessionRead(id: s.id, bytes: 4000)) }
            guard asked == s.id, row.window != nil else { return }   // the pointer left meanwhile
            let lines = (said ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var last = lines.isEmpty ? AgentSummary.what(s, app: app) : lines.suffix(8).joined(separator: "\n")
            if last.count > 700 { last = "…" + last.suffix(700) }
            let ago = shortAgo(s.statusAt ?? s.createdAt)
            fill(last + (ago.isEmpty ? "" : "\n— " + ago))
            popover.show(relativeTo: row.bounds, of: row, preferredEdge: .maxX)
        }
    }

    /// The bubble holds `said`, sized to it: a popover takes its content's size as set, it doesn't work it out.
    func fill(_ said: String) {
        text.stringValue = said
        let fit = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.width, height: .greatestFiniteMagnitude)) ?? .zero
        let w = min(Self.width, ceil(fit.width)), h = ceil(fit.height)
        text.frame = NSRect(x: Self.pad.width, y: Self.pad.height, width: w, height: h)
        popover.contentSize = NSSize(width: w + 2 * Self.pad.width, height: h + 2 * Self.pad.height)
    }

    func hide() { asked = nil; if popover.isShown { popover.close() } }
}
