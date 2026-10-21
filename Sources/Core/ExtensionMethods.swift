import Foundation

/// The extension library (`IDE.libraryIndex`): what it holds, from its index.json. Settings' `extensions.library` names
/// another index (a team's own library, a fork being tested).
public struct ExtensionLibrary: RPCMethod {
    public static let name = "extension.library"
    public typealias Result = [Entry]
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String, name: String, version: String
        public var description: String?, icon: String?
        /// Commands it needs on PATH (an extension without them stays inactive).
        public var requires: [String]?
        /// The reviewed folder on GitHub, at its commit: what `extension.fetch` takes.
        public var source: String
    }
    public init() {}
}

/// Downloads an extension from GitHub (`IDE.librarySource` reads the forms) into a new temporary folder named by its
/// id, with `.kelp-source.json` saying where it came from. Nothing is installed: the caller shows what it runs, then
/// moves it in (`IDE.installExtension`).
public struct ExtensionFetch: RPCMethod {
    public static let name = "extension.fetch"
    public struct Result: Codable, Sendable, Equatable {
        public var folder: String
        public init(folder: String) { self.folder = folder }
    }
    public var source: String
    public init(source: String) { self.source = source }
}
