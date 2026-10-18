import AppKit
import WebKit
import Markdown
import Core

/// A rendered Jupyter notebook. Run All re-executes it in place; Open Kernel starts Jupyter Lab in this worktree
/// and shows it in the built-in browser, so the kernel stays alive next to your agents.
@MainActor
final class NotebookTab: NSViewController {
    let url: URL, path: String, worktreeId: String?
    private let web = WKWebView()
    private let status = NSTextField(labelWithString: "")
    var currentSession: () -> String? = { nil }

    init(url: URL, path: String, worktreeId: String?) {
        self.url = url; self.path = path; self.worktreeId = worktreeId
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        func b(_ t: String, _ sym: String, _ sel: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: sel); x.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            x.imagePosition = .imageLeading; x.bezelStyle = .texturedRounded; return x
        }
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [b("Run All", "play.fill", #selector(runAll)), b("Open Kernel", "server.rack", #selector(openKernel)),
                                      b("Ask Agent", "text.bubble", #selector(askAgent)), NSView(), status])
        bar.spacing = 6; bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        view = pinned(bar: bar, body: web)
        reload()
    }

    func reload() {
        guard let d = FileManager.default.contents(atPath: url.path), let body = NotebookHTML.render(d) else {
            web.loadHTMLString("<p style='font:13px -apple-system;color:#888;padding:20px'>This notebook can't be read (is it valid nbformat 4 JSON?).</p>", baseURL: nil); return
        }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        web.loadHTMLString(MarkdownHTML.page(body: body, baseURL: url.deletingLastPathComponent(), dark: dark), baseURL: url.deletingLastPathComponent())
        if let s = NotebookHTML.summary(d) { status.stringValue = "\(s.cells) cells · \(s.language)" }
    }

    private static func jupyter() -> String? {
        ["/opt/homebrew/bin/jupyter", "/usr/local/bin/jupyter", NSHomeDirectory() + "/.local/bin/jupyter"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @objc private func runAll() {
        guard let j = Self.jupyter() else { status.stringValue = "Jupyter not found — pip install jupyter"; return }
        status.stringValue = "Running…"
        let file = url
        Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: j)
            p.arguments = ["nbconvert", "--to", "notebook", "--execute", "--inplace", file.path]
            p.currentDirectoryURL = file.deletingLastPathComponent()
            let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            let ok = p.terminationStatus == 0
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            await MainActor.run { self.status.stringValue = ok ? "Ran all cells" : "Failed: \(msg)"; self.reload() }
        }
    }

    @objc private func openKernel() {
        guard let wid = worktreeId else { return }
        guard Self.jupyter() != nil else { status.stringValue = "Jupyter not found — pip install jupyter"; return }
        Task {
            guard let r = await AppModel.shared.call("session.create", .obj(["worktreeId": .string(wid), "command": .string("jupyter lab --no-browser '\(path.replacingOccurrences(of: "'", with: "'\\''"))'"),
                                                                            "title": "Jupyter", "openURLs": true])) else { return }
            if let s = try? r.decode(Core.Session.self) { AppModel.shared.sessions.append(s) }
            // Jupyter's URL arrives as a dev-server URL and opens in a browser tab
            status.stringValue = "Starting Jupyter Lab… it opens in the Browser tab"
        }
    }

    @objc private func askAgent() {
        guard let sid = currentSession() else { NSSound.beep(); return }
        Task { await AppModel.shared.call("session.send", .obj(["id": .string(sid), "text": .string("Look at the notebook \(path) (cells and outputs). "), "enter": false])) }
    }
}
