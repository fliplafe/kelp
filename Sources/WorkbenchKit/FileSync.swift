import Foundation

/// What a file tab does with its buffer when it saves or sees its file change: agents edit files under open tabs,
/// and neither side's edits may be lost silently.
public enum FileSync {
    /// The file on disk: gone (moved or deleted), or there with its text (nil when it isn't UTF-8).
    public enum Disk: Equatable, Sendable { case missing, present(String?) }

    public enum Action: Equatable, Sendable {
        case none
        /// Write the buffer.
        case write
        /// No local edits: take the disk's text.
        case follow(String)
        /// Both changed: ask (keep mine / use the disk's).
        case conflict(String)
        /// The file is gone: never write it back without asking.
        case missing
    }

    /// ⌘S, autosave, closing: `saved` is what the buffer was last loaded from or written as.
    public static func save(buffer: String, saved: String, disk: Disk) -> Action {
        guard buffer != saved else { return .none }
        switch disk {
        case .missing: return .missing
        case .present(let text?) where text != saved: return .conflict(text)
        case .present(nil): return .conflict("")   // not readable as text: someone wrote it another way; never written over unasked
        case .present: return .write
        }
    }

    /// The file changed on disk.
    public static func diskChanged(buffer: String, saved: String, disk: Disk) -> Action {
        switch disk {
        case .missing: return .missing
        case .present(let text?) where text != saved: return buffer == saved ? .follow(text) : .conflict(text)
        case .present(nil): return .conflict("")   // no longer text (another encoding, binary): ask, as save does
        case .present: return .none
        }
    }
}
