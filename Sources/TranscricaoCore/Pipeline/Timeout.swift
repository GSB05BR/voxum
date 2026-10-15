// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct TimeoutError: Error, Equatable {
    public init() {}
}

/// Single-shot latch so whichever of (work, timer) finishes first wins.
private final class OnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Holds the timer task so the work can cancel it once the work has finished.
/// If the work finishes before the timer is registered, the timer is cancelled on arrival.
private final class TimerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Task<Void, Never>?
    private var finished = false

    func register(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
            return
        }
        timer = task
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        let task = timer
        timer = nil
        lock.unlock()
        task?.cancel()
    }
}

/// Returns as soon as the timer fires even if `operation` ignores cancellation
/// (a task group would wait for the child; MLX generation may not stop instantly).
/// Non-finite or negative `seconds` time out immediately.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // Clamp so the nanosecond conversion can never trap (NaN, negative, or huge values).
    let safeSeconds = seconds.isFinite ? min(max(0, seconds), 1_000_000) : 0
    let nanos = UInt64(safeSeconds * 1_000_000_000)
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let latch = OnceLatch()
        let timerBox = TimerBox()
        let work = Task {
            do {
                let value = try await operation()
                if latch.claim() {
                    cont.resume(returning: value)
                    timerBox.finish()
                }
            } catch {
                if latch.claim() {
                    cont.resume(throwing: error)
                    timerBox.finish()
                }
            }
        }
        timerBox.register(Task {
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            if latch.claim() {
                work.cancel()
                cont.resume(throwing: TimeoutError())
            }
        })
    }
}
