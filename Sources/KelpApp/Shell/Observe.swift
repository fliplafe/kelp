import Foundation
import Observation

/// Calls `changed` now and whenever `value` changes (Observation for AppKit code). With an `owner` (a tab, say), it
/// stops once the owner is gone.
@MainActor
func track<T: Equatable>(owner: AnyObject? = nil, _ value: @escaping @MainActor () -> T, changed: @escaping @MainActor (T) -> Void) {
    Tracker(owner: owner, value: value, changed: changed).run()
}

/// One `track`: kept alive by the observation it registers, until its owner is gone.
@MainActor
private final class Tracker<T: Equatable> {
    weak var owner: AnyObject?
    let owned: Bool
    let value: @MainActor () -> T, changed: @MainActor (T) -> Void
    var last: T?

    init(owner: AnyObject?, value: @escaping @MainActor () -> T, changed: @escaping @MainActor (T) -> Void) {
        self.owner = owner; owned = owner != nil; self.value = value; self.changed = changed
    }

    func run() {
        if owned, owner == nil { return }
        // onChange runs wherever the change was made: the next look is on main, on the next run-loop turn.
        let v = withObservationTracking { value() } onChange: { [self] in DispatchQueue.main.async { self.run() } }
        if v != last { last = v; changed(v) }
    }
}
