import Foundation
import Core
import Agents
import AgentData

// Sessions: listing, attaching, typing into, stopping, reading.

extension SessionList: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        let all = try d.store.sessions().map { s -> Session in d.existing(s.id)?.snapshot ?? s }
        return try .from(all.filter { worktreeId == nil || $0.worktreeId == worktreeId })
    }
}

extension SessionAttach: Handled {
    func handle(_ d: Daemon) throws -> JSONValue { try handle(d, conn: -1) }
    func handle(_ d: Daemon, conn: Int) throws -> JSONValue {
        if d.existing(id) == nil, try d.store.session(id)?.status == .exited {   // ended: what it last printed, from its log
            return .obj(["history": .string(TerminalReplies.withoutQueries(try d.liveSessionOrLog(id, bytes: LiveSession.ringLimit)).base64EncodedString())])
        }
        // Showing a tab isn't reading it: the app marks it read once it was looked at (or typed into).
        return .obj(["history": .string(try d.liveSession(id).attach(conn).base64EncodedString())])
    }
}

extension SessionDetach: Handled {
    func handle(_ d: Daemon) throws -> JSONValue { try handle(d, conn: -1) }
    func handle(_ d: Daemon, conn: Int) throws -> JSONValue { d.existing(id)?.detach(conn); return .null }
}

extension SessionWrite: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        let s = try d.liveSession(id)
        if let base64, let data = Data(base64Encoded: base64) { s.userInput(data) }
        else if let text { s.pty.write(Data(text.utf8)) }
        else { throw RPCError.invalidParams("missing text") }
        return .null
    }
}

extension SessionSend: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        // Still starting (woken just now, by this send or anyone else), a question open, an unread draft in the box, or
        // text still waiting ahead: queued, and typed once the program is ready for it (`LiveSession.submit`).
        try d.liveSession(id).submit(text, enter: enter != false)
        return .null
    }
}

/// A running one only: a size never wakes a paused agent (a wake gets the size it's shown at anyway).
extension SessionResize: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        let (c, r) = Daemon.Launch.size(cols: cols, rows: rows)
        d.existing(id)?.resize(cols: c, rows: r)
        return .null
    }
}

/// Under its wake lock, as waking is: a paused session marked ended here can't be woken halfway through, nor this kill land
/// on the old copy while a wake starts a new one.
extension SessionKill: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        try d.wakeLocks.withLock(id) {
            if let ls = d.existing(id) { ls.pty.terminate() }
            else if var s = try d.store.session(id), s.status == .hibernated { s.status = .exited; d.publish(s) }   // don't wake just to kill
        }
        return .null
    }
}

extension SessionChoose: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        guard let ls = d.existing(id), ls.choose(answer) != nil else { return .bool(false) }
        d.publish(ls)
        return .bool(true)
    }
}

extension AgentSetSecret: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        let account = AgentManifest.secretAccount(agent: agent, key: key)
        if let value, !value.isEmpty { try Keychain.set(value, account: account) } else { Keychain.delete(account) }
        return .null
    }
}

extension PortsList: Handled { func handle(_ d: Daemon) throws -> JSONValue { try .from(d.ports(worktree: worktreeId)) } }
extension SessionUsage: Handled { func handle(_ d: Daemon) throws -> JSONValue { try .from(d.usage()) } }

extension PortsStop: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        let pid = Int32(clamping: pid ?? 0)
        guard pid > 0, d.ports(worktree: worktreeId).contains(where: { $0.pid == pid }) else {
            throw RPCError.invalidParams("That process isn't running in this workspace.")
        }
        kill(pid, SIGTERM)
        return .null
    }
}

extension SessionBusy: Handled {
    func handle(_ d: Daemon) throws -> JSONValue { d.existing(id)?.pty.foregroundProgram.map { .string($0) } ?? .null }
}

extension Daemon {
    /// The last `bytes` a session printed as text. Lossy on purpose: a byte window can cut a UTF-8 sequence, and the rest
    /// of the text still matters.
    func printed(_ id: String, bytes: Int) throws -> JSONValue {
        // swiftlint:disable:next optional_data_string_conversion
        .string(StatusDetector.stripANSI(String(decoding: try liveSessionOrLog(id, bytes: bytes), as: UTF8.self)))
    }
}
extension SessionRead: Handled { func handle(_ d: Daemon) throws -> JSONValue { try d.printed(id, bytes: bytes ?? 8192) } }
extension SessionContext: Handled { func handle(_ d: Daemon) throws -> JSONValue { try d.printed(id, bytes: bytes ?? 24_000) } }

/// Never re-inserts a deleted one (publish only updates).
extension SessionMarkRead: Handled { func handle(_ d: Daemon) throws -> JSONValue { if let ls = d.existing(id), ls.setUnread(false) != nil { d.publish(ls) }; return .null } }
extension SessionMarkUnread: Handled { func handle(_ d: Daemon) throws -> JSONValue { if let ls = d.existing(id), ls.setUnread(true) != nil { d.publish(ls) }; return .null } }

extension SessionTurn: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        guard let ls = d.existing(id) else { return .null }
        return .obj(["turn": ls.lastTurn.flatMap { try? JSONValue.from($0) } ?? .null, "hasBase": .bool(ls.turnBase != nil)])
    }
}

extension SessionLastReply: Handled {
    func handle(_ d: Daemon) throws -> JSONValue {
        guard let t = d.existing(id).flatMap(d.transcript(of:)) else { return .null }
        return Daemon.lastReply(transcript: t).map { .string($0) } ?? .null
    }
}

extension Daemon {
    static let sessionMethods: [any Handled.Type] = [SessionList.self, SessionAttach.self, SessionDetach.self, SessionWrite.self, SessionSend.self,
        SessionResize.self, SessionKill.self, SessionChoose.self, AgentSetSecret.self, PortsList.self, PortsStop.self, SessionUsage.self,
        SessionBusy.self, SessionRead.self, SessionContext.self, SessionMarkRead.self, SessionMarkUnread.self, SessionTurn.self, SessionLastReply.self]
}
