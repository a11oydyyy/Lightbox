import Foundation

/// Polls `condition` until it turns false or `timeout` passes, and reports whether it cleared.
/// For waiting on the app to reach a state (a folder load, a rename, a watcher event): the
/// budget is generous because parallel runs can slow that work well past a few seconds, and
/// a passing wait still returns as soon as the condition clears. Tests that assert how fast
/// something happens keep their own tight loops.
@discardableResult
func waitWhile(
    timeout: Duration = .seconds(30),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
