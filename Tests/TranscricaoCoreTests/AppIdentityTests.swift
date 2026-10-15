// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class AppIdentityTests: XCTestCase {
    func testNameComesFromTheBundleDisplayName() {
        XCTAssertEqual(AppIdentity.name(infoDictionary: ["CFBundleDisplayName": "Outro"]), "Outro")
    }

    func testNameFallsBackWithoutABundleName() {
        XCTAssertEqual(AppIdentity.name(infoDictionary: nil), AppIdentity.fallbackName)
        XCTAssertEqual(AppIdentity.name(infoDictionary: [:]), AppIdentity.fallbackName)
        XCTAssertEqual(AppIdentity.name(infoDictionary: ["CFBundleDisplayName": ""]), AppIdentity.fallbackName)
    }

    func testDerivedNames() {
        XCTAssertEqual(AppIdentity.subsystem, AppIdentity.bundleID)
        XCTAssertEqual(AppIdentity.devDefaultsDomain, AppIdentity.bundleID + ".dev")
        XCTAssertEqual(AppIdentity.env("DATA_DIR"), AppIdentity.envPrefix + "DATA_DIR")
    }

    /// The constants and the bundle's Info.plist must agree (a rename touches both).
    func testInfoPlistMatchesTheConstants() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, AppIdentity.bundleID)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, AppIdentity.fallbackName)
        XCTAssertEqual(info["CFBundleName"] as? String, AppIdentity.fallbackName)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, AppIdentity.fallbackName)
        XCTAssertEqual(AppIdentity.name(infoDictionary: info), AppIdentity.fallbackName)
        // The microphone text never names the app (the system prompt above it already does), and
        // the base text is the English one, which languages without a translation show.
        let mic = try XCTUnwrap(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertFalse(mic.contains(AppIdentity.fallbackName), mic)
        let en = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Transcricao/Resources/en.lproj/InfoPlist.strings")),
            format: nil) as? [String: String])
        XCTAssertEqual(mic, en["NSMicrophoneUsageDescription"])
    }
}
