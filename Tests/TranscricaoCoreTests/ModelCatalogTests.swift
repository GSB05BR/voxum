// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class ModelCatalogTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private let ptBR = Locale(identifier: "pt_BR")

    // MARK: Catalog

    func testCatalogIsQwenAndNoAIOnly() {
        XCTAssertEqual(TextModelChoice.allCases, [.qwen3_4b, .transcriptionOnly])
        XCTAssertEqual(TextModelChoice.recommended, .qwen3_4b)
        XCTAssertEqual(TextModelChoice.qwen3_4b.repoID, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertNil(TextModelChoice.transcriptionOnly.repoID)
        XCTAssertTrue(TextModelChoice.qwen3_4b.usesAI)
        XCTAssertFalse(TextModelChoice.transcriptionOnly.usesAI)
        XCTAssertFalse(TextModelChoice.allCases.contains { $0.title.lowercased().contains("gemma") })
    }

    // MARK: Migration of saved settings

    func testMigrationKeepsKnownChoices() {
        XCTAssertEqual(TextModelChoice.migrated(from: "mlx-community/Qwen3-4B-Instruct-2507-4bit"), .qwen3_4b)
        XCTAssertEqual(TextModelChoice.migrated(from: "sem-ia"), .transcriptionOnly)
    }

    func testSavedGemmaMigratesToQwen() {
        XCTAssertEqual(TextModelChoice.migrated(from: "mlx-community/gemma-4-e4b-it-4bit"), .qwen3_4b)
    }

    func testMissingOrUnknownMigratesToQwen() {
        XCTAssertEqual(TextModelChoice.migrated(from: nil), .qwen3_4b)
        XCTAssertEqual(TextModelChoice.migrated(from: ""), .qwen3_4b)
        XCTAssertEqual(TextModelChoice.migrated(from: "mlx-community/Qwen3-1.7B-4bit"), .qwen3_4b)
    }

    // MARK: RAM preset

    func testLowMemoryMacsPreselectFiveMinutes() {
        XCTAssertEqual(ModelCatalog.recommendedIdleUnload(physicalMemory: 8 * gib), .five)
        XCTAssertEqual(ModelCatalog.recommendedIdleUnload(physicalMemory: 16 * gib - 1), .five)
    }

    func testSixteenGigabytesAndUpKeepNever() {
        XCTAssertEqual(ModelCatalog.recommendedIdleUnload(physicalMemory: 16 * gib), .never)
        XCTAssertEqual(ModelCatalog.recommendedIdleUnload(physicalMemory: 48 * gib), .never)
        XCTAssertFalse(ModelCatalog.isLowMemory(physicalMemory: 16 * gib))
        XCTAssertTrue(ModelCatalog.isLowMemory(physicalMemory: 8 * gib))
    }

    // MARK: Download plan / sizes

    func testPlanDownloadsOnlyWhatIsMissing() {
        XCTAssertEqual(ModelDownloadPlan(text: .qwen3_4b, whisperOnDisk: false, textOnDisk: false).items,
                       [.whisper, .text(.qwen3_4b)])
        XCTAssertEqual(ModelDownloadPlan(text: .qwen3_4b, whisperOnDisk: true, textOnDisk: false).items,
                       [.text(.qwen3_4b)])
        XCTAssertEqual(ModelDownloadPlan(text: .qwen3_4b, whisperOnDisk: false, textOnDisk: true).items, [.whisper])
        XCTAssertTrue(ModelDownloadPlan(text: .qwen3_4b, whisperOnDisk: true, textOnDisk: true).isEmpty)
    }

    func testNoAIPlanNeverDownloadsATextModel() {
        XCTAssertEqual(ModelDownloadPlan(text: .transcriptionOnly, whisperOnDisk: false, textOnDisk: false).items,
                       [.whisper])
        XCTAssertTrue(ModelDownloadPlan(text: .transcriptionOnly, whisperOnDisk: true, textOnDisk: false).isEmpty)
    }

    func testTotalsMatchTheSpec() {
        let full = ModelDownloadPlan(text: .qwen3_4b, whisperOnDisk: false, textOnDisk: false)
        XCTAssertEqual(full.totalBytes, ModelCatalog.whisperBytes + TextModelChoice.qwen3_4b.downloadBytes)
        XCTAssertEqual(ByteText.approx(full.totalBytes, locale: ptBR), "2,7 GB")
        XCTAssertEqual(ByteText.approx(full.totalBytes, locale: Locale(identifier: "en_US")), "2.7 GB")
        XCTAssertEqual(ByteText.approx(ModelCatalog.whisperBytes), "620 MB")
        XCTAssertEqual(ByteText.approx(TextModelChoice.qwen3_4b.downloadBytes, locale: ptBR), "2,1 GB")
        let light = ModelDownloadPlan(text: .transcriptionOnly, whisperOnDisk: false, textOnDisk: false)
        XCTAssertEqual(ByteText.approx(light.totalBytes), "620 MB")
    }

    func testFreeSpaceCheckKeepsHeadroom() {
        let plan = ModelDownloadPlan(text: .qwen3_4b, whisperOnDisk: false, textOnDisk: false)
        XCTAssertTrue(plan.fits(freeBytes: plan.totalBytes + ModelDownloadPlan.headroomBytes))
        XCTAssertFalse(plan.fits(freeBytes: plan.totalBytes + ModelDownloadPlan.headroomBytes - 1))
        XCTAssertTrue(plan.fits(freeBytes: nil))
        XCTAssertTrue(ModelDownloadPlan(text: .qwen3_4b, whisperOnDisk: true, textOnDisk: true).fits(freeBytes: 0))
    }

    func testByteText() {
        XCTAssertEqual(ByteText.approx(0), "0 MB")
        XCTAssertEqual(ByteText.approx(3 * 1_048_576), "3 MB")
        XCTAssertEqual(ByteText.approx(312 * 1_048_576), "310 MB")
        XCTAssertEqual(ByteText.approx(Int64(gib)), "1 GB")
        XCTAssertEqual(ByteText.approx(Int64(gib) * 48 / 10, locale: ptBR), "4,8 GB")
    }

    /// The separator follows the UI language (its `.lproj`), like the localized "~2.4 GB of memory"
    /// strings, not the region: an English UI on a Portuguese region shows "2.1 GB", not "2,1 GB".
    func testByteTextFollowsTheUILanguage() {
        let size = TextModelChoice.qwen3_4b.downloadBytes
        let expected = ["en": "2.1 GB", "pt-BR": "2,1 GB", "es": "2,1 GB", "fr": "2,1 GB", "zh-Hans": "2.1 GB"]
        for (lproj, text) in expected {
            XCTAssertEqual(ByteText.approx(size, locale: ByteText.locale(forLocalizations: [lproj])), text, lproj)
        }
        XCTAssertEqual(ByteText.locale(forLocalizations: []).decimalSeparator, ".")
    }

    // MARK: Download progress

    func testProgressAccumulatesBytesAcrossItems() {
        var p = DownloadProgress(items: [.whisper, .text(.qwen3_4b)])
        XCTAssertEqual(p.completedBytes, 0)
        p.update(fraction: 0.5)
        XCTAssertEqual(p.completedBytes, ModelCatalog.whisperBytes / 2)
        p.finishCurrent()
        XCTAssertEqual(p.current, .text(.qwen3_4b))
        XCTAssertEqual(p.completedBytes, ModelCatalog.whisperBytes)
        p.update(fraction: 1)
        p.finishCurrent()
        XCTAssertNil(p.current)
        XCTAssertEqual(p.completedBytes, p.totalBytes)
        XCTAssertEqual(p.fraction, 1)
    }

    func testProgressNeverGoesBackwardsOrPastOne() {
        var p = DownloadProgress(items: [.whisper])
        p.update(fraction: 0.6)
        p.update(fraction: 0.2)
        XCTAssertEqual(p.currentFraction, 0.6)
        p.update(fraction: 7)
        XCTAssertEqual(p.currentFraction, 1)
    }

    // MARK: First run

    func testExistingInstallIsConfirmedSilently() {
        XCTAssertEqual(FirstRunDecision.decide(confirmed: false, chosenModelsOnDisk: true), .confirmSilently)
    }

    func testFreshInstallShowsTheChooser() {
        XCTAssertEqual(FirstRunDecision.decide(confirmed: false, chosenModelsOnDisk: false), .showChooser)
    }

    func testConfirmedNeverShowsTheChooserAgain() {
        XCTAssertEqual(FirstRunDecision.decide(confirmed: true, chosenModelsOnDisk: false), .proceed)
        XCTAssertEqual(FirstRunDecision.decide(confirmed: true, chosenModelsOnDisk: true), .proceed)
    }
}
