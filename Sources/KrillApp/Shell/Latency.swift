import Foundation

/// The latency rule: a quick answer changes nothing on screen; "Loading…", a spinner or the stage appear only once
/// the wait is long enough to notice (a second). Cancel the task when the answer comes.
@MainActor @discardableResult
func whileSlow(after seconds: Double = 1, _ show: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        if !Task.isCancelled { show() }
    }
}
