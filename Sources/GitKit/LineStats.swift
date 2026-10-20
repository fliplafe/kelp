import Foundation

/// Lines added / removed in the working tree (staged, unstaged and new files) against HEAD, split by what kind of file.
public struct LineStats: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case code, tests, generated }
    public var added: [Kind: Int] = [:], removed: [Kind: Int] = [:]
    public var totalAdded: Int { added.values.reduce(0, +) }
    public var totalRemoved: Int { removed.values.reduce(0, +) }

    /// Lock files, build output and codegen count as generated; test folders and `*.test.*` / `*Tests.swift` as tests.
    public static func kind(_ path: String) -> Kind {
        let p = path.lowercased(), name = (p as NSString).lastPathComponent
        let locks: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "cargo.lock", "podfile.lock",
                                  "package.resolved", "go.sum", "poetry.lock", "composer.lock", "gemfile.lock", "uv.lock", "flake.lock"]
        if locks.contains(name) || p.hasPrefix("dist/") || p.hasPrefix("build/") || p.contains("/__generated__/") || p.contains("/generated/")
            || name.contains(".min.") || name.contains(".generated.") || name.hasSuffix(".pb.go") || name.hasSuffix(".g.dart") || name.hasSuffix(".snap") {
            return .generated
        }
        let dirs = p.split(separator: "/").dropLast()
        if dirs.contains(where: { ["test", "tests", "spec", "specs", "__tests__", "testing"].contains($0) || $0.hasSuffix("tests") })
            || name.contains(".test.") || name.contains(".spec.") || name.contains("_test.") || name.hasPrefix("test_")
            || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") {
            return .tests
        }
        return .code
    }
}

extension Git {
    public static func lineStats(_ cwd: String) throws -> LineStats {
        var s = LineStats()
        // No commit yet: there's no HEAD, the staged files are all there is.
        let tracked = try (try? run(["diff", "HEAD", "--numstat", "--no-renames", "-z"], cwd: cwd)) ?? run(["diff", "--cached", "--numstat", "--no-renames", "-z"], cwd: cwd)
        for line in tracked.split(separator: "\0") {
            let f = line.split(separator: "\t", maxSplits: 2)
            guard f.count == 3, let a = Int(f[0]), let d = Int(f[1]) else { continue }   // "-" = binary
            let k = LineStats.kind(String(f[2]))
            s.added[k, default: 0] += a; s.removed[k, default: 0] += d
        }
        // New files git doesn't track yet: their lines are all additions (small text files only).
        for p in try run(["ls-files", "--others", "--exclude-standard", "-z"], cwd: cwd).split(separator: "\0").prefix(500) {
            let url = URL(fileURLWithPath: cwd).appendingPathComponent(String(p))
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
                  let d = try? Data(contentsOf: url), !d.contains(0) else { continue }
            s.added[LineStats.kind(String(p)), default: 0] += d.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        return s
    }
}
