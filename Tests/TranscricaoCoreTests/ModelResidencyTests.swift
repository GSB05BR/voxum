// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class CountingModel: ResidentModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0, _unloads = 0
    private var _active = 0, _maxConcurrent = 0
    var loadDelay: Double = 0
    var unloadDelay: Double = 0
    /// When set, load() throws it (after the delay) instead of loading.
    var loadError: Error?
    var loads: Int { lock.withLock { _loads } }
    var unloads: Int { lock.withLock { _unloads } }
    /// Highest number of load/unload calls running at the same time.
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }

    private func enter() {
        lock.withLock {
            _active += 1
            _maxConcurrent = max(_maxConcurrent, _active)
        }
    }

    private func exit() { lock.withLock { _active -= 1 } }

    func load() async throws {
        enter(); defer { exit() }
        if loadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(loadDelay * 1e9)) }
        if let loadError { throw loadError }
        lock.withLock { _loads += 1 }
    }

    func unload() async {
        enter(); defer { exit() }
        if unloadDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(unloadDelay * 1e9)) }
        lock.withLock { _unloads += 1 }
    }
}

final class ModelResidencyTests: XCTestCase {
    // timeScale 0.0001 → 5 min becomes 30 ms.
    func makeResidency(_ models: [ResidentModel]) -> ModelResidency {
        ModelResidency(models: models, timeScale: 0.0001)
    }

    func testEnsureLoadedLoadsOnce() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        try await r.ensureLoaded()
        try await r.ensureLoaded()
        XCTAssertEqual(m.loads, 1)
        let loaded = await r.isLoaded
        XCTAssertTrue(loaded)
    }

    func testConcurrentEnsureLoadedSharesOneLoad() async throws {
        let m = CountingModel(); m.loadDelay = 0.1
        let r = makeResidency([m])
        async let a: Void = try r.ensureLoaded()
        async let b: Void = try r.ensureLoaded()
        _ = try await (a, b)
        XCTAssertEqual(m.loads, 1)
    }

    func testNeverPolicyNeverUnloads() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        try await r.ensureLoaded()
        await r.noteActivity()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(m.unloads, 0)
    }

    func testUnloadsAfterIdleInterval() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        await r.setPolicy(.five)
        try await r.ensureLoaded()
        await r.noteActivity()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(m.unloads, 1)
        let loaded = await r.isLoaded
        XCTAssertFalse(loaded)
        // Next use reloads.
        try await r.ensureLoaded()
        XCTAssertEqual(m.loads, 2)
    }

    func testAfterUseUnloadsRightAfterTheLastUseOnly() async throws {
        let m = CountingModel()
        let r = ModelResidency(models: [m]) // real time: "after use" has no interval to scale
        await r.setPolicy(.afterUse)
        try await r.beginUse()
        await r.hold() // e.g. the next recording already started
        await r.endUse()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(m.unloads, 0, "still held")
        await r.endUse()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(m.unloads, 1)
        let loaded = await r.isLoaded
        XCTAssertFalse(loaded)
    }

    func testAfterUseIsStoredAndTitled() {
        XCTAssertEqual(IdleUnloadPolicy(rawValue: IdleUnloadPolicy.afterUse.rawValue), .afterUse)
        XCTAssertEqual(IdleUnloadPolicy.afterUse.interval, 0)
        XCTAssertEqual(IdleUnloadPolicy.afterUse.title, "Right after dictating")
        XCTAssertEqual(IdleUnloadPolicy.allCases.first, .never)
    }

    func testActivityPostponesUnload() async throws {
        let m = CountingModel()
        let r = ModelResidency(models: [m], timeScale: 0.001) // 5 min → 300 ms
        await r.setPolicy(.five)
        try await r.ensureLoaded()
        for _ in 0..<4 {
            await r.noteActivity()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertEqual(m.unloads, 0)
    }

    func testOnChangeReportsTransitions() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        let box = ChangeBox()
        await r.setOnChange { box.append($0) }
        try await r.ensureLoaded()
        await r.unloadNow()
        XCTAssertEqual(box.values, [.loading, .loaded, .unloaded])
    }

    func testFailedLoadReportsFailed() async throws {
        let m = CountingModel(); m.loadError = Boom()
        let r = makeResidency([m])
        let box = ChangeBox()
        await r.setOnChange { box.append($0) }
        do { try await r.ensureLoaded(); XCTFail("expected failure") } catch {}
        XCTAssertEqual(box.values, [.loading, .failed])
    }

    func testModelsLoadConcurrently() async throws {
        let a = CountingModel(); a.loadDelay = 0.3
        let b = CountingModel(); b.loadDelay = 0.3
        let r = makeResidency([a, b])
        let t0 = Date()
        try await r.ensureLoaded()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5, "serial load would take ≥ 0.6 s")
        XCTAssertEqual(a.loads, 1)
        XCTAssertEqual(b.loads, 1)
        let loaded = await r.isLoaded
        XCTAssertTrue(loaded)
    }

    func testFailedLoadLeavesNothingLoaded() async throws {
        let ok = CountingModel()
        let bad = CountingModel(); bad.loadDelay = 0.1; bad.loadError = Boom()
        let r = makeResidency([ok, bad])
        do { try await r.ensureLoaded(); XCTFail("expected failure") } catch {}
        XCTAssertEqual(ok.loads, 1)
        XCTAssertEqual(ok.unloads, 1, "the model that did load is released again")
        var loaded = await r.isLoaded
        XCTAssertFalse(loaded)
        // A retry loads both.
        bad.loadError = nil
        try await r.ensureLoaded()
        loaded = await r.isLoaded
        XCTAssertTrue(loaded)
        XCTAssertEqual(ok.loads, 2)
        XCTAssertEqual(bad.loads, 1)
    }

    func testUnloadNowDuringLoadUnloadsAfterIt() async throws {
        let m = CountingModel(); m.loadDelay = 0.2
        let r = makeResidency([m])
        let load = Task { try await r.ensureLoaded() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await r.unloadNow()
        _ = try? await load.value
        XCTAssertEqual(m.loads, 1)
        XCTAssertEqual(m.unloads, 1, "the unload must not be dropped while a load is in flight")
        let loaded = await r.isLoaded
        XCTAssertFalse(loaded)
    }

    func testHoldBlocksIdleUnloadWithoutLoading() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        await r.setPolicy(.five)
        await r.hold()
        XCTAssertEqual(m.loads, 0, "hold never loads")
        try await r.ensureLoaded()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(m.unloads, 0)
        await r.endUse()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(m.unloads, 1)
    }

    func testIdleDoesNotUnloadWhileInUse() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        await r.setPolicy(.five)
        try await r.beginUse()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(m.unloads, 0)
        await r.endUse()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(m.unloads, 1)
    }

    func testLoadDuringUnloadWaitsForUnload() async throws {
        let m = CountingModel()
        m.unloadDelay = 0.2
        let r = makeResidency([m])
        try await r.ensureLoaded()
        let u = Task { await r.unloadNow() }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await r.ensureLoaded()
        await u.value
        XCTAssertEqual(m.maxConcurrent, 1)
        XCTAssertEqual(m.loads, 2)
        let loaded = await r.isLoaded
        XCTAssertTrue(loaded)
    }

    func testEndUseWithoutBeginIsHarmless() async throws {
        let m = CountingModel()
        let r = makeResidency([m])
        await r.endUse()
        XCTAssertEqual(m.unloads, 0)
        let loaded = await r.isLoaded
        XCTAssertFalse(loaded)
    }
}

final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [ResidencyEvent] = []
    var values: [ResidencyEvent] { lock.withLock { _values } }
    func append(_ v: ResidencyEvent) { lock.withLock { _values.append(v) } }
}
