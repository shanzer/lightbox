import Foundation

/// Runs `work` and reports whether it finished inside `seconds`.
///
/// Every wait in a test needs a deadline that turns into a *failure*, not a
/// hang: a hung test takes the whole suite with it and is reported only by a
/// watchdog minutes later, with no indication of which test was at fault.
///
/// Written as a race between the work and a sleep rather than as a semaphore
/// wait, because a `DispatchSemaphore.wait` on a swift-testing thread blocks a
/// cooperative-pool thread. On a three-core CI runner three of those starve the
/// pool completely — which is exactly the failure this helper is here to catch,
/// so causing it while checking for it would be a poor trade.
func completes(within seconds: Double,
               _ work: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await work()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let finishedInTime = await group.next() ?? false
        group.cancelAll()
        return finishedInTime
    }
}
