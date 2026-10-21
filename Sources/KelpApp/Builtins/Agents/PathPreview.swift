import AppKit
import SwiftUI
import Core
import WorkbenchKit

/// Paths agents print, made useful: ⌘-click opens them (on their line), resting the pointer on one shows the file —
/// the changed lines when it has changes, the lines around the one named, or the picture.
@MainActor
enum TerminalPaths {
    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg", "ico"]

    /// "Sources/App.swift:12:5", "~/x.md", "a/src/x.ts" (a diff's) → an existing file and its line, from `cwd`.
    static func resolve(_ token: String, cwd: String) -> (path: String, line: Int?)? {
        guard !token.contains("://") || token.hasPrefix("file://") else { return nil }   // URLs are Ghostty's
        var t = token.hasPrefix("file://") ? (URL(string: token)?.path ?? token) : token
        if t.hasPrefix("@") { t.removeFirst() }   // "@src/x.ts" (an agent's mention)
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        let line = parts.count > 1 ? Int(parts[1]) : nil
        let raw = (String(parts[0]) as NSString).expandingTildeInPath
        guard raw.contains("/") || raw.contains(".") else { return nil }   // a word, not a path
        for p in [raw, raw.hasPrefix("a/") || raw.hasPrefix("b/") ? String(raw.dropFirst(2)) : nil].compactMap({ $0 }) {
            let abs = p.hasPrefix("/") ? p : (cwd as NSString).appendingPathComponent(p)
            var st = stat()   // a file: not a folder, nor a pipe or device (reading one to preview it would block)
            if stat(abs, &st) == 0, st.st_mode & S_IFMT == S_IFREG { return ((abs as NSString).standardizingPath, line) }
        }
        return nil
    }

    /// ⌘-click: in Kelp, on its line (the tab it's already in, if any); ⌥⌘-click: shown in the Finder. Not opened with its
    /// app: a program printed the path, and a .command file (or any script) would run there — from a cloned repo,
    /// without Gatekeeper's check.
    static func open(_ token: String, cwd: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard let f = resolve(token, cwd: cwd) else { return false }
        if flags.contains(.option) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]); return true }
        Workbench.open(TabURI.file(f.path) + (f.line.map { "#L\($0)" } ?? ""))
        return true
    }
}

/// The popover the terminal shows for a path under the pointer.
@MainActor
final class PathPreview {
    private let popover = NSPopover()
    init() { popover.behavior = .semitransient; popover.animates = false }

    func show(_ token: String?, rect: NSRect, in view: NSView, cwd: String, worktree: String?) {
        guard let token, let f = TerminalPaths.resolve(token, cwd: cwd) else { popover.close(); return }
        let model = PreviewModel(path: f.path, line: f.line, cwd: cwd)
        let host = NSHostingController(rootView: PathPreviewView(model: model))
        host.sizingOptions = .preferredContentSize   // placed and resized around the anchor (see HoverCard)
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        model.load(worktree: worktree)
    }
}

@MainActor
@Observable
final class PreviewModel {
    struct Line: Identifiable { let id: Int; let number: Int?; let text: String; let mark: Character }   // mark: + - or space
    let path: String, line: Int?, name: String, folder: String
    var lines: [Line] = []
    var image: NSImage?
    var changed = false

    init(path: String, line: Int?, cwd: String) {
        self.path = path; self.line = line
        name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent, root = (cwd as NSString).standardizingPath   // both without /private
        folder = dir.hasPrefix(root + "/") ? String(dir.dropFirst(root.count + 1)) : dir == root ? "" : (dir as NSString).abbreviatingWithTildeInPath
    }

    func load(worktree: String?) {
        if TerminalPaths.images.contains((path as NSString).pathExtension.lowercased()) { image = NSImage(contentsOfFile: path); return }
        lines = excerpt()
        guard let worktree, let c = AppModel.shared.client else { return }
        Task {
            // Uncommitted changes in it: show those (the hunk with the line asked about, else the first).
            let d = try? await c.call("git.diff", .obj(["id": .string(worktree), "source": "all", "file": .string(path)]), as: [FileDiff].self)
            guard let hunks = d?.first?.hunks, !hunks.isEmpty else { return }
            let h = hunks.first { h in line.map { l in h.lines.contains { $0.newLine == l } } ?? false } ?? hunks[0]
            changed = true
            lines = h.lines.prefix(16).enumerated().map { i, l in
                Line(id: i, number: l.newLine ?? l.oldLine, text: l.text, mark: l.kind == .add ? "+" : l.kind == .del ? "-" : " ")
            }
        }
    }

    /// Up to 14 lines around the line named (or the file's first), read from at most 256 KB of it.
    private func excerpt() -> [Line] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 262_144)) ?? Data()
        guard !data.contains(0) else { return [Line(id: 0, number: nil, text: String(localized: "Binary file"), mark: " ")] }
        let all = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let start = max(0, (line ?? 1) - 5)
        return all.indices.dropFirst(start).prefix(14).map { Line(id: $0, number: $0 + 1, text: all[$0], mark: " ") }
    }
}

struct PathPreviewView: View {
    let model: PreviewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(model.name).font(.headline)
                if !model.folder.isEmpty { Text(model.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 8)
                if model.changed { Text("Changed").font(.caption.weight(.medium)).foregroundStyle(.orange) }
            }
            if let img = model.image {
                Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 240)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.lines) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(l.number.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                            Text(l.mark == " " ? l.text : "\(l.mark) \(l.text)").lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(l.mark == "+" ? .green : l.mark == "-" ? .red : .primary)
                        }
                        .padding(.vertical, 1)
                        .background(l.number == model.line && l.mark == " " ? Color.accentColor.opacity(0.18) : .clear)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
            Text("⌘-click to open · ⌥⌘-click opens it in its app").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12).frame(width: 520, alignment: .leading)
    }
}
