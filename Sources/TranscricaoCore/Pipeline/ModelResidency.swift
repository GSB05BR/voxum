// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum IdleUnloadPolicy: Int, CaseIterable, Codable, Sendable {
    /// `afterUse`: the models are released as soon as the last dictation ends and load again
    /// when the dictation key is pressed (in parallel with speech, ~3 s). Raw values are minutes (stored setting).
    case never = 0, afterUse = -1, five = 5, fifteen = 15, thirty = 30

    public var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .afterUse: 0
        default: TimeInterval(rawValue * 60)
        }
    }

    public var title: String {
        switch self {
        case .never: String(localized: "Never", bundle: .main)
        case .afterUse: String(localized: "Right after dictating", bundle: .main)
        default: String(localized: "\(rawValue) min", bundle: .main)
        }
    }
}

/// Residency transitions reported through `setOnChange`.
public enum ResidencyEvent: Equatable, Sendable {
    /// A load started (launch, retry, model switch or reload after idle unload).
    case loading
    case loaded
    case unloaded
    /// A load failed; nothing stays loaded.
    case failed
}

/// Keeps the models in memory, optionally evicting them after a period without
/// dictation. `timeScale` shrinks the idle interval for tests.
///
/// A run brackets its work with `beginUse()` / `endUse()`: while at least one
/// use is active the models are never idle-unloaded. Loads and unloads are
/// strictly ordered: `ensureLoaded()` waits for an in-flight unload to finish.
public actor ModelResidency {
    private let models: [ResidentModel]
    private let timeScale: Double
    private var policy: IdleUnloadPolicy = .never
    private var loadTask: Task<Void, Error>?
    private var unloadTask: Task<Void, Never>?
    private var unloadSeq = 0
    private var idleTask: Task<Void, Never>?
    /// Bumped whenever a pending idle timer must be treated as stale.
    private var idleGeneration = 0
    private var inUse = 0
    private var onChange: (@Sendable (ResidencyEvent) -> Void)?
    public private(set) var isLoaded = false

    public init(models: [ResidentModel], timeScale: Double = 1) {
        self.models = models
        self.timeScale = timeScale
    }

    public func setOnChange(_ handler: @escaping @Sendable (ResidencyEvent) -> Void) {
        onChange = handler
    }

    public func setPolicy(_ newPolicy: IdleUnloadPolicy) {
        policy = newPolicy
        noteActivity()
    }

    /// Loads every model once; concurrent callers share the same load.
    public func ensureLoaded() async throws {
        if let pending = unloadTask { await pending.value }
        if isLoaded { return }
        if let running = loadTask { return try await running.value }
        // performLoad runs on this actor; it cannot start before loadTask is assigned below.
        let task = Task { try await self.performLoad() }
        loadTask = task
        try await task.value
    }

    /// Loads all models concurrently. On any failure, waits for the others and releases the ones
    /// that did load, so "not loaded" always means nothing is resident. Commits `isLoaded` itself
    /// (before the task completes) so an `unloadNow` waiting on this load sees the outcome.
    private func performLoad() async throws {
        onChange?(.loading)
        let models = self.models
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for model in models { group.addTask { try await model.load() } }
                try await group.waitForAll()
            }
        } catch {
            for model in models { await model.unload() } // no-op for models that never loaded
            loadTask = nil
            onChange?(.failed)
            throw error
        }
        loadTask = nil
        isLoaded = true
        onChange?(.loaded)
        noteActivity()
    }

    /// Loads the models if needed and holds them until the matching `endUse()`.
    public func beginUse() async throws {
        try await ensureLoaded()
        // An unloadNow (model switch) may have slipped in after the load completed: load again.
        while !isLoaded { try await ensureLoaded() }
        inUse += 1
        cancelIdle()
    }

    /// Takes a lease without loading (e.g. while recording, so an idle unload cannot fire mid-take).
    public func hold() {
        inUse += 1
        cancelIdle()
    }

    /// Releases one lease taken by `beginUse()` or `hold()`; the idle countdown restarts when the last one ends.
    public func endUse() {
        inUse = max(0, inUse - 1)
        if inUse == 0 { noteActivity() }
    }

    /// Restarts the idle countdown (call on every dictation).
    public func noteActivity() {
        cancelIdle()
        guard isLoaded, inUse == 0, let interval = policy.interval else { return }
        let nanos = UInt64(interval * timeScale * 1_000_000_000)
        let generation = idleGeneration
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.idleFired(generation)
        }
    }

    public func unloadNow() async {
        cancelIdle()
        // Never drop an unload because a load is in flight (e.g. switching models during a
        // reload): let it finish, then unload what it loaded.
        if let running = loadTask { _ = try? await running.value }
        if let pending = unloadTask {
            await pending.value
            return
        }
        guard isLoaded else { return }
        isLoaded = false
        onChange?(.unloaded)
        let models = self.models
        let task = Task {
            for model in models { await model.unload() }
        }
        unloadSeq += 1
        let seq = unloadSeq
        unloadTask = task
        await task.value
        // A newer unload may have replaced this one; only clear our own handle.
        if seq == unloadSeq { unloadTask = nil }
    }

    private func cancelIdle() {
        idleTask?.cancel()
        idleTask = nil
        idleGeneration += 1
    }

    /// Runs when an idle timer elapses; ignored if activity or a use happened since it was armed.
    private func idleFired(_ generation: Int) async {
        guard generation == idleGeneration, inUse == 0 else { return }
        await unloadNow()
    }
}
