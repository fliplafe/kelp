import Foundation
import Observation

/// Calls `changed` now and whenever `value` changes (Observation for AppKit code). With an `owner` (a tab, say), it
/// stops once the owner is gone.
@MainActor
func track<T: Equatable>(owner: AnyObject? = nil, _ value: @escaping @MainActor () -> T, changed: @escaping @MainActor (T) -> Void) {
    weak var alive = owner
    let owned = owner != nil
    var last: T?
    func track() {
        if owned, alive == nil { return }
        let v = withObservationTracking { value() } onChange: { DispatchQueue.main.async { MainActor.assumeIsolated { track() } } }
        if v != last { last = v; changed(v) }
    }
    track()
}
