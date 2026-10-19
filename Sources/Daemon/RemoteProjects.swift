import Foundation
import Core
import GitKit

/// Remote projects (SSH): added by host and folder, their files read from the host. See `RemoteHost`.
extension Daemon {
    func handleRemote(_ method: String, _ p: JSONValue, conn: Int) throws -> JSONValue? {
        switch method {
        case "repo.addRemote":   // {host, path} → the project (its local folder stands for the one on the host)
            let host = try p.req("host").trimmingCharacters(in: .whitespaces), path = try p.req("path").trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(" ") else { throw RPCError.invalidParams("Enter the host, as you'd type it after ssh.") }
            guard path.hasPrefix("/") || path.hasPrefix("~") else { throw RPCError.invalidParams("Enter the folder's full path on \(host).") }
            let name = (path as NSString).lastPathComponent
            let folder = root.appendingPathComponent("remote/\(host.replacingOccurrences(of: "/", with: "_"))/\(name)")
            if let r = try store.repos().first(where: { $0.path == folder.path }) { return try .from(r) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func mark(_ r: RemoteHost) throws { try JSONEncoder().encode(r).write(to: folder.appendingPathComponent(RemoteHost.marker)) }
            // ~ as the host's shell spells it: ask git there where the repository's top is.
            try mark(RemoteHost(host: host, path: path))
            let top: String
            do { top = try Git.root(of: folder.path) }
            catch let e as GitError {
                try? FileManager.default.removeItem(at: folder)
                throw RPCError.invalidParams("Couldn't open \(path) on \(host): \(e.stderr.isEmpty ? "ssh failed" : e.stderr)")
            }
            try mark(RemoteHost(host: host, path: top))
            let r = Repo(name: name, path: folder.path, baseBranch: Git.defaultBranch(repo: folder.path))
            try store.save(r); try syncMainWorkspaces(); notify("event.changed", "repo")
            return try .from(r)
        case "files.readRemote":   // {path} in a remote project's folder → the file's text, read on the host
            guard let (_, remote, remotePath) = RemoteHost.containing(try p.req("path")) else { throw RPCError.invalidParams("Not in a remote project.") }
            return .string(try Git.run(remote.sshArgs(tty: false) + ["cat -- " + RemoteHost.quote(remotePath)], cwd: NSHomeDirectory(), executable: RemoteHost.ssh))
        default: return nil
        }
    }
}
