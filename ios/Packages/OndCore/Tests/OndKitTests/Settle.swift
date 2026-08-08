/// Waits for a model's reader task to catch up, polling until `condition` holds
/// or two seconds have passed.
///
/// The alternative — napping a fixed slice and then asserting — is a race the
/// test loses on a loaded machine. The models these suites drive publish from
/// their own `Task`, and under a parallel run of the whole package that task can
/// miss its slice entirely for tens of milliseconds, so the assertion reads the
/// state the model held *before* the stream produced anything. Polling makes the
/// wait as long as the machine needs and no longer.
///
/// Wait on something weaker than the assertion that follows — the state leaving
/// `.waiting`, say, rather than the exact value being checked — or the wait
/// swallows the failure the assertion exists to report.
///
/// Gives up rather than hanging, leaving the assertion to fail with its own
/// message and the actual state.
@MainActor
func settle(until condition: @MainActor () -> Bool) async throws {
    for _ in 0 ..< 400 {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
