import Foundation

public enum SocketError: Error { case path, socket(Int32), connect(Int32), bind(Int32) }

public enum Unix {
    static func addr(_ path: String) throws -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: a.sun_path)
        guard path.utf8.count < cap else { throw SocketError.path }
        withUnsafeMutableBytes(of: &a.sun_path) { b in
            for (i, c) in path.utf8.enumerated() { b[i] = c }
        }
        return a
    }

    public static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socket(errno) }
        var a = try addr(path)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { let e = errno; close(fd); throw SocketError.connect(e) }
        return fd
    }

    public static func listen(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socket(errno) }
        var a = try addr(path)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0, Darwin.listen(fd, 16) == 0 else { let e = errno; close(fd); throw SocketError.bind(e) }
        chmod(path, 0o600)   // the socket is the auth boundary locally
        return fd
    }

    /// Write all bytes, retrying on partial writes. Returns false if the peer is gone.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
                off += n
            }
            return true
        }
    }
}
