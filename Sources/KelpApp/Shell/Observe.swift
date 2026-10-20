import Foundation
import Observation

/// Calls `changed` now and whenever `value` changes (Observation for AppKit code).
@MainActor
func track<T: Equatable>(_ value: @escaping @MainActor () -> T, changed: @escaping @MainActor (T) -> Void) {
    var last: T?
    func track() {
        let v = withObservationTracking { value() } onChange: { DispatchQueue.main.async { MainActor.assumeIsolated { track() } } }
        if v != last { last = v; changed(v) }
    }
    track()
}
