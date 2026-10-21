import Foundation

/// tmux sessions as Kelp terminals. The tab runs `tmux new-session -A -s <name>`, which attaches to that session or
/// starts it. tmux keeps the session, so the tab goes back to it after Kelp or its daemon restarts, and closing the
/// tab only detaches. A remote project's tmux runs on its host.
public enum Tmux {
    public struct Session: Codable, Sendable, Equatable {
        public var name: String, windows: Int, attached: Int
        /// When someone last typed in it or it printed something.
        public var activity: Date
        public init(name: String, windows: Int, attached: Int, activity: Date) {
            self.name = name; self.windows = windows; self.attached = attached; self.activity = activity
        }
    }

    public static func argv(_ name: String) -> [String] { ["tmux", "new-session", "-A", "-s", name] }

    /// The session a terminal's argv attaches to; nil for any other program.
    public static func session(_ argv: [String]) -> String? {
        argv.count == 5 && argv.prefix(4).elementsEqual(Self.argv("").prefix(4)) ? argv[4] : nil
    }

    /// A name tmux keeps as it is: it turns ":" and "." into "_" itself, and the tab has to find the session by that name.
    public static func name(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).map { $0 == ":" || $0 == "." || $0.isNewline ? "_" : $0 })
    }

    /// `tmux list-sessions -F` with this, one session a line.
    public static let format = "#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}"

    /// What that prints, the last used first. Lines that aren't sessions (a host's shell greeting) are skipped.
    public static func parse(_ out: String) -> [Session] {
        out.split(whereSeparator: \.isNewline).compactMap { line -> Session? in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 4, !f[0].isEmpty, let w = Int(f[1]), let a = Int(f[2]), let t = Double(f[3]) else { return nil }
            return Session(name: String(f[0]), windows: w, attached: a, activity: Date(timeIntervalSince1970: t))
        }.sorted { $0.activity > $1.activity }
    }

    /// `list-sessions` failed only because no tmux server runs there (it starts with the first session).
    public static func noServer(_ stderr: String) -> Bool {
        stderr.contains("no server running") || stderr.contains("error connecting to")
    }
}
