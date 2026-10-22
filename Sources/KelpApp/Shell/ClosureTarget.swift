import AppKit

final class ClosureButton: NSButton {
    private var handler: (() -> Void)?
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero); self.title = title; handler = action; target = self; self.action = #selector(fire)
    }
    @objc private func fire() { handler?() }
}

/// A menu item's or control's action as a closure; AppKit sends actions on the main thread.
@MainActor
final class ClosureTarget: NSObject {
    let f: @MainActor () -> Void
    init(_ f: @escaping @MainActor () -> Void) { self.f = f }
    @objc func fire() { f() }
}
