import Foundation
import os
import Core
import GitKit
import Agents
import AgentData

/// The long-running process: owns PTYs, state and the JSON-RPC socket.
/// Running sessions and who is connected each keep their own lock; the order they're taken in is in `Clients`.
public final class Daemon: Sendable {
    public let store: Store
    var socketPath: String { root.appendingPathComponent("kelp.sock").path }
    let root: URL
    let clients = Clients()
    /// What start() opens and stop() closes: the socket, the flock on kelpd.lock (one daemon per KELP_HOME), the sources.
    private struct Running: @unchecked Sendable {   // the sources are only set up and cancelled, under `running`'s lock
        var listenFD: Int32 = -1, instanceLock: Int32 = -1
        var accept: DispatchSourceRead?, ticker: DispatchSourceTimer?, prune: DispatchSourceTimer?
    }
    private let running = OSAllocatedUnfairLock(initialState: Running())
    let settings: SettingsStore
    let agentUsage: AgentUsage   // what the agents left on disk: conversations, token usage, plan limits
    let offloads = Slots(Daemon.offloadLimit)   // what `offload` runs at once
    let forges: Forges   // pull requests by branch, running clones, the trackers' clients
    let lsp: LSPHost   // language servers: one per project and server command, shared by every client
    let watches: Watches   // what clients watch (watch.start), read while anyone does and pushed when it changed
    let sessions: Sessions   // which run, starting, waking, pausing and deleting them
    let settingsEvents = DispatchQueue(label: "kelp.settings-events")   // event.settings in order: the last one is the settings now
    let workspaces: Workspaces   // desks, the branches they follow, the .kelp.yaml files the user trusts
    var files: FileService { FileService(remotes: remotes) }   // files.*: read, written, moved here or on a remote project's host
    let remotes: Remotes   // which project folders stand for one on a host (only those in this home's remote/), and how to reach it

    public convenience init(root: URL, store: Store? = nil) throws { try self.init(root: root, store: store, lsp: LSPHost()) }

    init(root: URL, store: Store?, lsp: LSPHost) throws {
        signal(SIGPIPE, SIG_IGN)   // a client that hangs up mid-write fails that write; it must not end the process (kelpd does this too, tests host a Daemon themselves)
        self.root = root; self.lsp = lsp
        try Paths.ensure(root)
        self.store = try store ?? Store(path: root.appendingPathComponent("kelp.sqlite").path)
        self.settings = SettingsStore(root: root)
        self.remotes = Remotes(home: root)
        self.agentUsage = AgentUsage(root: root, settings: settings, store: self.store, remotes: remotes)
        self.forges = Forges(offloads: offloads)
        self.workspaces = Workspaces(root: root, store: self.store, remotes: remotes, deskAdded: { [clients] in clients.notify(ChangedEvent.worktree) })
        self.watches = Watches(store: self.store, clients: clients, remotes: remotes)
        self.sessions = Sessions(root: root, socketPath: root.appendingPathComponent("kelp.sock").path, store: self.store, remotes: remotes,
                                 settings: settings, agentUsage: agentUsage, clients: clients, watches: watches, offloads: offloads)
        // Remote projects' shared SSH connections; without it, they fail.
        do { try Paths.ensure(URL(fileURLWithPath: remotes.controlDir)) } catch { Log.start.error("no folder for ssh connections: \(error)") }
        watches.reading.withLock { $0.read = { [weak self] k, fast in await self?.sample(k, fast: fast) ?? (nil, nil) } }
        self.store.changed.withLock {
            $0.tell = { [weak self] c in
                self?.recordChanged(c)   // records go to the clients as they change
                switch c {   // and a project added, moved or removed is followed (watchHeads) from then on
                case .repo, .repoRemoved: self?.workspaces.watchHeads()
                default: break
                }
            }
        }
    }

    /// When this binary was built; the app compares it with the kelpd it ships to spot a stale daemon after an update.
    static let binaryMTime: Double = {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }()

    public func start() throws {
        // One daemon per KELP_HOME: a second one (launchd's KeepAlive, a CLI that couldn't connect) would take the socket
        // over and mark the first one's running agents paused.
        let lockFD = open(root.appendingPathComponent("kelpd.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            throw RPCError.internalError("another kelpd is already running for \(root.path)")
        }
        running.withLock { $0.instanceLock = lockFD }
        // Sessions from a previous daemon run lost their PTYs; resumable ones come back as paused, the rest as exited.
        let manifests = AgentManifest.load(dir: root.appendingPathComponent("agents"))
        do {
            for var s in try store.sessions() where s.status != .exited {
                s.status = Sessions.resumable(s, manifests) ? .hibernated : .exited
                s.progress = nil   // what ran there isn't getting any further
                try store.save(s)
            }
        } catch { Log.store.error("couldn't mark the last run's sessions paused or ended: \(error)") }
        _ = Self.binaryMTime   // read now: after an update the file on disk is already the new one
        DispatchQueue.global().async { _ = LoginPath.value }   // warm up so the first agent doesn't wait for the shell
        // The usage index reads gigabytes the first time: do it in the background now, not when Usage is opened.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) { [self] in
            let since = Calendar.current.date(byAdding: .day, value: -89, to: Calendar.current.startOfDay(for: Date())) ?? Date()
            _ = agentUsage.usageIndex.rows(roots: agentUsage.agentRoots().claude.filter { FileManager.default.fileExists(atPath: $0.path) }, since: since)
        }
        let listenFD: Int32
        do { listenFD = try Unix.listen(socketPath) } catch {
            running.withLock { if $0.instanceLock >= 0 { close($0.instanceLock); $0.instanceLock = -1 } }   // not ours to keep
            throw error
        }
        // Accept and the ticker have queues of their own (serial queues get a thread even when every pooled one is held
        // by a slow git or ssh in `offload`), so new connections and status keep going whatever is stuck.
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: DispatchQueue(label: "kelp.accept"))
        src.setCancelHandler { close(listenFD) }   // after any accept still running, not under it
        src.setEventHandler { [self, weak src] in
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                // Out of fds, the socket stays readable and this would run again at once, spinning: wait for some to free.
                if errno == EMFILE || errno == ENFILE, let src { src.suspend(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { src.resume() } }
                return
            }
            if Unix.peerIsUs(fd) { Unix.noSigPipe(fd); serve(fd) } else { close(fd) }
        }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kelp.ticker"))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [self] in sessions.live.all.forEach { $0.tick() }; sessions.applyKeepAwake(); sessions.hibernateIdle(); pollSettings() }
        let prune = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        prune.schedule(deadline: .now() + 60, repeating: 86400)   // ended sessions past `keepEnded`
        prune.setEventHandler { [self] in sessions.pruneEnded() }
        running.withLock { $0.listenFD = listenFD; $0.accept = src; $0.ticker = t; $0.prune = prune }
        src.resume(); t.resume(); prune.resume()
        workspaces.headQueue.async { [weak self] in if self?.running.withLock({ $0.accept != nil }) == true { self?.workspaces.followHeads() } }   // not once stopped
        try? FileManager.default.removeItem(at: Paths.daemonError(in: root))   // an earlier failure is over
        Log.start.info("kelpd \(getpid()) serves \(self.socketPath, privacy: .public)")
    }

    public func stop() {
        let r = running.withLock { r in defer { r = Running() }; return r }
        r.accept?.cancel(); r.ticker?.cancel(); r.prune?.cancel()   // the accept source's cancel closes the socket
        if r.accept == nil, r.listenFD >= 0 { close(r.listenFD) }
        // Every program ends with the daemon, whole trees (a job in a process group of its own, an agent that ignores the
        // hangup), each recorded as pausing records it: a resumable agent comes back paused, not as a second copy.
        sessions.pauseAll()
        lsp.stopAll()
        watches.stopAll()
        workspaces.stopWatching()
        clients.everyone().forEach { $0.hangUp() }
        unlink(socketPath)
        if r.instanceLock >= 0 { close(r.instanceLock) }
    }

    // MARK: connections

    /// A request as it comes: JSON-RPC lets the id be a string too, and the reply carries it back as it came.
    struct Request: Decodable {
        let id: JSONValue?
        let method: String
        let params: JSONValue?
        var isNotification: Bool { id == nil || id == .null }
    }
    struct Reply: Encodable {
        var jsonrpc = "2.0"
        let id: JSONValue
        let result: JSONValue?
        let error: RPCError?
    }

    private func serve(_ fd: Int32) {
        let c = clients.add(fd: fd)
        Thread.detachNewThread { [self] in
            var lb = LineBuffer()
            var buf = [UInt8](repeating: 0, count: 65536)
            var spoke = false
            reading: while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                for line in lb.append(Data(buf[0..<n])) {
                    guard let req = try? JSONDecoder().decode(Request.self, from: line) else {
                        // Not a request: say so to whoever sent an id, rather than leave it waiting.
                        if let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"], id != .null, let d = try? Wire.line(
                            Reply(id: id, result: nil, error: RPCError(code: -32600, message: "invalid request"))) { c.send(d) }
                        continue
                    }
                    // A JSON-RPC client after all (it came in raw, Clients.add): events from now on.
                    if !spoke { spoke = true; if req.method != "session.stream" { clients.setRaw(c.id, false) } }
                    // Quick, and only right in the order they were sent (keystrokes, a setting dragged, two sends; a saved
                    // layout or a terminal size that finished second must not win over the newer one): applied here, one
                    // after another, calls and notifications alike (`Answered.inOrder`); a call's reply goes out in that order.
                    if let t = Self.methods[req.method] as? any Handled.Type, t.inOrder {
                        let id = req.id ?? .null, notification = req.isNotification, method = req.method
                        let reply: @Sendable (Swift.Result<Data, Error>) -> Void = { r in
                            if case .failure(let e) = r { Self.log(method, failed: e, notification: notification) }
                            guard !notification else { return }
                            switch r {
                            case .success(let d): c.send(Self.replyLine(id: id, result: d))
                            case .failure(let e): if let d = Self.errorLine(id: id, e) { c.send(d) }
                            }
                        }
                        // Input for a session answers once the session has it (`SessionInput`), maybe from its lane.
                        if let s = t as? any SessionInput.Type { s.answerInOrder(req.params ?? .null, sessions, done: reply) }
                        else { reply(Swift.Result { try answerNow(t, req.params ?? .null, conn: c.id) }) }
                        continue
                    }
                    // The one method by name: it ends JSON-RPC on this connection, which becomes a raw byte pipe (kelp attach).
                    if req.method == "session.stream" {
                        stream(c, session: req.params?["id"]?.string ?? "", size: req.params, leftover: lb.takeRemainder())
                        break reading
                    }
                    Task { await self.respond(req, conn: c) }
                }
            }
            clients.remove(c.id)   // first: an attach finishing now sees it gone (Clients.ifConnected)
            watches.drop(c.id)
            sessions.live.all.forEach { $0.detach(c.id) }
            lsp.closeAll(conn: c.id)   // its files: a server left with none stops a while later
            c.close()
        }
    }

    /// Raw attach (`kelp attach`, the libghostty terminal): history then live output as plain bytes; whatever the client
    /// writes is the user's typing. Terminal replies (DA, kitty keyboard) flow back the same way, so the agent sees a real terminal.
    /// `size`: the attaching terminal's cols / rows, so a paused agent wakes at the size it's shown at.
    /// An ended session shows what it last printed (from its log), then the attach ends.
    private func stream(_ c: Connection, session: String, size: JSONValue?, leftover: Data) {
        clients.setRaw(c.id, true)   // before waking: its status events must not land in the byte stream
        defer { clients.setRaw(c.id, false) }
        if sessions.existing(session) == nil, (try? store.session(session))?.status == .exited {
            c.send(TerminalReplies.withoutQueries((try? sessions.liveSessionOrLog(session, bytes: LiveSession.ringLimit)) ?? Data())); return
        }
        let (cols, rows) = Sessions.Launch.size(cols: size?["cols"]?.int, rows: size?["rows"]?.int)
        let ls: LiveSession
        do { ls = try sessions.liveSession(session, cols: cols, rows: rows) } catch {
            // One Kelp has that didn't wake says why (its agent's CLI gone, its folder deleted), here and in the log.
            guard (try? store.session(session)) != nil else { c.send(Data("kelp: no such session\r\n".utf8)); return }
            let why = (error as? RPCError)?.message ?? "\(error)"
            Log.session.error("\(session, privacy: .public) didn't wake for a terminal: \(why)")
            c.send(Data("kelp: \(why)\r\n".utf8)); return
        }
        // Queued under the session's lock: no live output gets ahead of it. One paused at this moment ends the attach,
        // as the pause does for those already attached (`letGo`).
        guard ls.attach(c.id, send: { c.send($0) }) != nil else { return }
        if !leftover.isEmpty { ls.userInput(leftover) }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c.fd, &buf, buf.count)
            if n <= 0 { break }
            ls.userInput(Data(buf[0..<n]))
        }
        ls.detach(c.id)
    }

    static let pausedAsAttached = RPCError.invalidParams("The session was paused as it was opened. Open it again.")

    private func respond(_ req: Request, conn c: Connection) async {
        let id = req.id ?? .null
        // Attach: the reply with the history is queued in the same step that subscribes, so no live output can reach this
        // connection ahead of it (the screen would show the newest bytes before the history they follow).
        // The one method that answers itself (SessionAttach's own handler serves an ended session): its reply has to be
        // queued inside the session's lock, which `Handled` can't express.
        if req.method == SessionAttach.name, !req.isNotification, let sid = (try? SessionAttach.decoded(req.params ?? .null))?.id,
           sessions.existing(sid) != nil || (try? store.session(sid))?.status == .hibernated,
           let ls = try? await offload({ [self] in try sessions.liveSession(sid) }) {
            // Only while it's still connected: one that closed while the session woke isn't subscribed (it would count as
            // watching for good, and the session would never pause).
            var attached = true
            clients.ifConnected(c.id) {
                attached = ls.attach(c.id) { history in
                    if let r = try? JSONEncoder().encode(SessionAttach.Result(history: history.base64EncodedString())) { c.send(Self.replyLine(id: id, result: r)) }
                } != nil
            }
            if !attached, let d = Self.errorLine(id: id, Self.pausedAsAttached) { c.send(d) }
            return
        }
        do {
            let r = try await answer(req.method, req.params ?? .null, conn: c.id)
            if !req.isNotification { c.send(Self.replyLine(id: id, result: r)) }
        } catch {
            Self.log(req.method, failed: error, notification: req.isNotification)
            if !req.isNotification, let d = Self.errorLine(id: id, error) { c.send(d) }
        }
    }

    /// A call's refusal went back to its caller; a notification's failure (a layout or UI state not saved) and anything
    /// unexpected has only the log.
    static func log(_ method: String, failed error: Error, notification: Bool) {
        if let e = error as? RPCError, !notification { Log.rpc.debug("\(method, privacy: .public) failed: \(e.message)") }
        else { Log.rpc.error("\(method, privacy: .public) failed: \((error as? RPCError)?.message ?? "\(error)")") }
    }

    /// A reply line around a result already encoded: the result isn't decoded and encoded again on its way out.
    static func replyLine(id: JSONValue, result: Data) -> Data {
        var d = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        d.append((try? JSONEncoder().encode(id)) ?? Data("null".utf8))
        d.append(Data(#","result":"#.utf8)); d.append(result); d.append(Data("}\n".utf8))
        return d
    }
    static func errorLine(id: JSONValue, _ error: Error) -> Data? {
        try? Wire.line(Reply(id: id, result: nil, error: (error as? RPCError) ?? .internalError("\(error)")))
    }

    func notify(_ e: some RPCEvent, to only: Set<Int>? = nil) { clients.notify(e, to: only) }

    func cwd(forWorktree id: String) throws -> Worktree { try workspaces.worktree(id) }
}
