import Foundation
import Core
import Agents
import AgentData

// Sessions: listing, attaching, typing into, stopping, reading.

extension SessionList: Handled {
    static var quick: Bool { true }
    func handle(_ d: Daemon) throws -> [Session] {
        let all = try d.store.sessions().map { s -> Session in d.sessions.existing(s.id)?.snapshot ?? s }
        return all.filter { worktreeId == nil || $0.worktreeId == worktreeId }
    }
}

extension SessionAttach: Handled {
    func handle(_ d: Daemon) throws -> Result { try handle(d, conn: -1) }
    func handle(_ d: Daemon, conn: Int) throws -> Result {
        if d.sessions.existing(id) == nil, try d.store.session(id)?.status == .exited {   // ended: what it last printed, from its log
            return Result(history: TerminalReplies.withoutQueries(try d.sessions.liveSessionOrLog(id, bytes: LiveSession.ringLimit)).base64EncodedString())
        }
        // Showing a tab isn't reading it: the app marks it read once it was looked at (or typed into).
        guard let history = try d.sessions.liveSession(id).attach(conn) else { throw Daemon.pausedAsAttached }
        return Result(history: history.base64EncodedString())
    }
}

extension SessionDetach: Handled {
    func handle(_ d: Daemon) throws -> Done { try handle(d, conn: -1) }
    func handle(_ d: Daemon, conn: Int) throws -> Done { d.sessions.existing(id)?.detach(conn); return Done() }
}

extension SessionWrite: SessionInput {
    static var inOrder: Bool { true }   // keystrokes
    func apply(to s: LiveSession) throws -> Done {
        let data: Data
        if let base64, let b = Data(base64Encoded: base64) { data = b } else if let text { data = Data(text.utf8) } else { throw RPCError.invalidParams("missing text") }
        // Keystrokes count as the user's typing; text goes to the program as it is.
        if base64 != nil { s.userInput(data) } else { s.write(data) }
        return Done()
    }
}

extension SessionSend: SessionInput {
    /// Two sends in a row reach the session in that order (`submit` only queues: nothing here waits on the agent).
    static var inOrder: Bool { true }
    func apply(to s: LiveSession) throws -> Done {
        // Still starting (woken just now, by this send or anyone else), a question open, an unread draft in the box, or
        // text still waiting ahead: queued, and typed once the program is ready for it (`LiveSession.submit`). A paused
        // one wakes on its lane, not on the reader thread (`SessionInput`).
        try s.submit(text, enter: enter != false)
        return Done()
    }
}

/// A running one only: a size never wakes a paused agent (a wake gets the size it's shown at anyway).
extension SessionResize: Handled {
    static var inOrder: Bool { true }
    func handle(_ d: Daemon) throws -> Done {
        let (c, r) = Sessions.Launch.size(cols: cols, rows: rows)
        d.sessions.existing(id)?.resize(cols: c, rows: r)
        return Done()
    }
}

/// Under its wake lock, as waking is: a paused session marked ended here can't be woken halfway through, nor this kill land
/// on the old copy while a wake starts a new one.
extension SessionKill: Handled {
    func handle(_ d: Daemon) throws -> Done {
        try d.sessions.wakeLocks.withLock(id) {
            if let ls = d.sessions.existing(id) { ls.pty.terminate() }
            else if var s = try d.store.session(id), s.status == .hibernated { s.status = .exited; d.sessions.publish(s) }   // don't wake just to kill
        }
        if let s = try d.store.session(id) { d.sessions.endOwnTmux(s) }
        return Done()
    }
}

extension SessionChoose: Handled {
    func handle(_ d: Daemon) throws -> Bool {
        guard let ls = d.sessions.existing(id), ls.choose(answer) != nil else { return false }
        d.sessions.publish(ls)
        return true
    }
}

extension AgentSetSecret: Handled {
    func handle(_ d: Daemon) throws -> Done {
        let account = AgentManifest.secretAccount(agent: agent, key: key)
        if let value, !value.isEmpty { try Keychain.set(value, account: account) } else { Keychain.delete(account) }
        return Done()
    }
}

extension PortsList: Handled { func handle(_ d: Daemon) throws -> [Port] { d.ports(worktree: worktreeId) } }
extension SessionUsage: Handled { func handle(_ d: Daemon) throws -> [Usage] { d.usage() } }

extension PortsStop: Handled {
    func handle(_ d: Daemon) throws -> Done {
        let pid = Int32(clamping: pid ?? 0)
        guard pid > 0, d.ports(worktree: worktreeId).contains(where: { $0.pid == pid }) else {
            throw RPCError.invalidParams("That process isn't running in this workspace.")
        }
        kill(pid, SIGTERM)
        return Done()
    }
}

extension SessionBusy: Handled {
    func handle(_ d: Daemon) throws -> String? {
        guard let ls = d.sessions.existing(id) else { return nil }
        // In a terminal's own tmux session tmux is always in front: what runs is in its panes (closing ends them).
        if let name = Tmux.session(ls.snapshot.argv), Tmux.isOwn(name) { return d.sessions.tmuxBusy(name, cwd: ls.snapshot.cwd) }
        return ls.pty.foregroundProgram
    }
}

extension Daemon {
    /// The last `bytes` a session printed as text. Lossy on purpose: a byte window can cut a UTF-8 sequence, and the rest
    /// of the text still matters.
    func printed(_ id: String, bytes: Int) throws -> String {
        // swiftlint:disable:next optional_data_string_conversion
        StatusDetector.stripANSI(String(decoding: try sessions.liveSessionOrLog(id, bytes: bytes), as: UTF8.self))
    }
}
extension SessionRead: Handled { func handle(_ d: Daemon) throws -> String { try d.printed(id, bytes: bytes ?? 8192) } }
extension SessionContext: Handled { func handle(_ d: Daemon) throws -> String { try d.printed(id, bytes: bytes ?? 24_000) } }

/// Never re-inserts a deleted one (publish only updates).
extension SessionMarkRead: Handled {
    static var quick: Bool { true }
    func handle(_ d: Daemon) throws -> Done { if let ls = d.sessions.existing(id), ls.setUnread(false) != nil { d.sessions.publish(ls) }; return Done() }
}
extension SessionMarkUnread: Handled {
    static var quick: Bool { true }
    func handle(_ d: Daemon) throws -> Done { if let ls = d.sessions.existing(id), ls.setUnread(true) != nil { d.sessions.publish(ls) }; return Done() }
}

extension SessionTurn: Handled {
    static var quick: Bool { true }
    func handle(_ d: Daemon) throws -> Info? {
        guard let ls = d.sessions.existing(id) else { return nil }
        let turn = ls.lastTurn.map { t in Turn(files: t.files.map { .init(path: $0.path, added: $0.added, removed: $0.removed) }, seconds: t.seconds) }
        return Info(turn: turn, hasBase: ls.turnBase != nil)
    }
}

extension SessionLastReply: Handled {
    func handle(_ d: Daemon) throws -> String? {
        guard let t = d.sessions.existing(id).flatMap(d.agentUsage.transcript(of:)) else { return nil }
        return AgentUsage.lastReply(transcript: t)
    }
}

extension Daemon {
    static let sessionMethods: [any Handled.Type] = [SessionList.self, SessionAttach.self, SessionDetach.self, SessionWrite.self, SessionSend.self,
        SessionResize.self, SessionKill.self, SessionChoose.self, AgentSetSecret.self, PortsList.self, PortsStop.self, SessionUsage.self,
        SessionBusy.self, SessionRead.self, SessionContext.self, SessionMarkRead.self, SessionMarkUnread.self, SessionTurn.self, SessionLastReply.self]
}
