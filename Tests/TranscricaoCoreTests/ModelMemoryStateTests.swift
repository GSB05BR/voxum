// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class ModelMemoryStateTests: XCTestCase {
    func testFollowsResidencyEvents() {
        XCTAssertEqual(ModelMemoryState(.loading), .loading)
        XCTAssertEqual(ModelMemoryState(.loaded), .loaded)
        XCTAssertEqual(ModelMemoryState(.unloaded), .unloaded)
        XCTAssertEqual(ModelMemoryState(.failed), .unloaded)
    }

    /// Tests run without the app bundle, so the strings are the English source (keys of en.lproj).
    func testTitlesTellTheUserWhatHappensNext() {
        XCTAssertEqual(ModelMemoryState.loaded.title, "Models loaded in memory")
        XCTAssertEqual(ModelMemoryState.loading.title, "Loading models…")
        XCTAssertEqual(ModelMemoryState.unloaded.title, "Models inactive — they load when you dictate (~3 s)")
    }

    func testVoiceOnlyTitlesNameTheVoiceModel() {
        XCTAssertEqual(ModelMemoryState.loaded.title(voiceOnly: true), "Voice model loaded in memory")
        XCTAssertEqual(ModelMemoryState.loaded.title(voiceOnly: false), "Models loaded in memory")
        XCTAssertEqual(ModelMemoryState.loaded.title, ModelMemoryState.loaded.title(voiceOnly: false))
        for state in [ModelMemoryState.loaded, .loading, .unloaded] {
            XCTAssertFalse(state.title(voiceOnly: true).contains("Models"))
        }
    }
}
