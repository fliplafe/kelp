import Foundation

/// A language from `contributes.languages`: the files it covers and the language server for them. `id` is the LSP languageId.
public struct LanguageSpec: Codable, Equatable, Sendable {
    public struct Server: Codable, Equatable, Sendable {
        public var command: String
        public var args: [String]?
        /// A shell command that installs `command`, offered when it isn't on PATH.
        public var install: String?

        public init(command: String, args: [String]? = nil, install: String? = nil) {
            self.command = command; self.args = args; self.install = install
        }
    }
    public var id: String
    public var extensions: [String]
    /// Whole file names, e.g. "Dockerfile".
    public var fileNames: [String]?
    public var server: Server?

    public init(id: String, extensions: [String], server: Server? = nil) {
        self.id = id; self.extensions = extensions; self.server = server
    }

    /// The language of `path`: the last of `specs` naming its file or extension (case-insensitive). A spec whose `id`
    /// comes again later is replaced by that later one.
    public static func find(_ path: String, in specs: [LanguageSpec]) -> LanguageSpec? {
        let name = (path as NSString).lastPathComponent, ext = (name as NSString).pathExtension.lowercased()
        var seen = Set<String>()
        return specs.reversed().filter { seen.insert($0.id).inserted }
            .first { $0.fileNames?.contains(name) == true || $0.extensions.contains { $0.lowercased() == ext } }
    }
}
