// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class UpdateConfigurationTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/Voxum.app")
    private let validKey = Data(repeating: 7, count: 32).base64EncodedString()

    func testOnlyA32ByteBase64KeyIsValid() {
        XCTAssertTrue(UpdateConfiguration.isValidPublicKey(validKey))
        XCTAssertFalse(UpdateConfiguration.isValidPublicKey(nil))
        XCTAssertFalse(UpdateConfiguration.isValidPublicKey(""))
        XCTAssertFalse(UpdateConfiguration.isValidPublicKey(UpdateConfiguration.publicKeyPlaceholder))
        XCTAssertFalse(UpdateConfiguration.isValidPublicKey(Data(repeating: 7, count: 31).base64EncodedString()))
        XCTAssertFalse(UpdateConfiguration.isValidPublicKey("not base64!"))
    }

    func testDevelopmentRunsNeverStartTheUpdater() {
        XCTAssertEqual(UpdateConfiguration.decide(dataDirOverride: true, bundleURL: app, publicKey: validKey), .developmentRun)
        let swiftRun = URL(fileURLWithPath: "/tmp/pkg/.build/debug")
        XCTAssertEqual(UpdateConfiguration.decide(dataDirOverride: false, bundleURL: swiftRun, publicKey: validKey), .notAppBundle)
    }

    func testThePlaceholderKeyNeverStartsTheUpdater() {
        XCTAssertEqual(UpdateConfiguration.decide(dataDirOverride: false, bundleURL: app,
                                                  publicKey: UpdateConfiguration.publicKeyPlaceholder), .noPublicKey)
        XCTAssertEqual(UpdateConfiguration.decide(dataDirOverride: false, bundleURL: app, publicKey: nil), .noPublicKey)
        XCTAssertEqual(UpdateConfiguration.decide(dataDirOverride: false, bundleURL: app, publicKey: validKey), .start)
    }

    /// Info.plist carries what Sparkle reads; it must agree with the constants and the spec.
    func testInfoPlistUpdateKeys() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        XCTAssertEqual(info["SUFeedURL"] as? String, UpdateConfiguration.feedURL)
        XCTAssertEqual(UpdateConfiguration.feedURL, "https://github.com/GSB05BR/voxum/releases/latest/download/appcast.xml")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, UpdateConfiguration.checkInterval)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        // The placeholder until the real key is filled in; never anything else that Sparkle would reject.
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertTrue(key == UpdateConfiguration.publicKeyPlaceholder || UpdateConfiguration.isValidPublicKey(key), key)
        // Sparkle compares the build number: an integer. The marketing version is x.y.z.
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotNil(Int(build), build)
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression), version)
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "14.0")
    }
}
