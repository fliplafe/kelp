import Foundation
import Core

extension Daemon {
    static let extensionMethods: [any Handled.Type] = [ExtensionLibrary.self, ExtensionFetch.self]
}

extension ExtensionLibrary: Handled {
    func handle(_ d: Daemon) throws -> Result { try IDE.library(index: d.settings["extensions.library"]?.string ?? IDE.libraryIndex) }
}

extension ExtensionFetch: Handled {
    func handle(_ d: Daemon) throws -> Result { Result(folder: try IDE.fetchExtension(source).path) }
}
