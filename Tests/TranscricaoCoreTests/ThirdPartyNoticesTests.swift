// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

/// THIRD_PARTY_NOTICES.md (bundled in the app by build-app.sh) and the app's Credits window come from one
/// Swift source plus the license files of the SwiftPM checkouts; the file in the repository must be exactly
/// what they generate (regenerate with `swift run --disable-keychain tcli notices > THIRD_PARTY_NOTICES.md`).
final class ThirdPartyNoticesTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func notices() throws -> String {
        try read("THIRD_PARTY_NOTICES.md")
    }

    func testTheMarkdownFileMatchesTheSwiftSourceAndTheLicenseFiles() throws {
        XCTAssertEqual(try Self.notices(), try ThirdPartyNotices.markdown(reading: Self.read),
                       "THIRD_PARTY_NOTICES.md is stale: swift run --disable-keychain tcli notices > THIRD_PARTY_NOTICES.md")
    }

    static func resolvedLocations() throws -> [String] {
        let data = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
        return try pins.map { try XCTUnwrap($0["location"] as? String) }
    }

    /// Every package pinned in Package.resolved is credited, in the list and in the bundled notices.
    func testEveryResolvedPackageIsListedAndInTheNotices() throws {
        let locations = try Self.resolvedLocations()
        XCTAssertFalse(locations.isEmpty)
        let urls = Set(ThirdPartyNotices.libraries.map { normalized($0.url) })
        let notices = try Self.notices().lowercased()
        for location in locations {
            XCTAssertTrue(urls.contains(normalized(location)), "\(location) is missing from ThirdPartyNotices")
            XCTAssertTrue(notices.contains("- url: \(normalized(location))\n"), "\(location) is missing from THIRD_PARTY_NOTICES.md")
        }
    }

    /// Each library has its own license file, and the license it claims matches it.
    func testEveryLibraryHasItsLicenseText() throws {
        let apache = try squashed(Self.read(ThirdPartyNotices.apacheLicenseFile))
        XCTAssertTrue(apache.contains("Apache License Version 2.0, January 2004"))
        for c in ThirdPartyNotices.libraries {
            let file = try XCTUnwrap(c.licenseFile, "\(c.name) has no license file")
            let text = try squashed(ThirdPartyNotices.licenseText(of: c, reading: Self.read))
            if c.licenseLines != nil {
                // Code vendored inside a package: its header comment holds the copyright and license.
                XCTAssertTrue(text.contains("Copyright"), file)
                if c.license.hasPrefix("BSD") { XCTAssertTrue(text.contains("Redistributions in binary form must reproduce"), file) }
                if c.license == "Zlib" { XCTAssertTrue(text.contains("Permission is granted to anyone to use this software"), file) }
                continue
            }
            if c.license.hasPrefix("Apache-2.0") {
                // The same terms as the text printed once (the appendix and exception may follow).
                let terms = String(apache[..<apache.range(of: "END OF TERMS AND CONDITIONS")!.upperBound])
                XCTAssertTrue(text.contains(terms), "\(file) is not the Apache-2.0 text")
            } else if c.license == "MIT" {
                XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"), "\(file) is not an MIT license")
            }
            XCTAssertEqual(c.license.contains("Swift-exception"), text.contains("Runtime Library Exception"), file)
            for notice in c.notices { XCTAssertFalse(try Self.read(notice).isEmpty, notice) }
        }
    }

    /// Code vendored inside the shipped packages with its own license header (BSD, Zlib, MIT, Apache, SPDX): every
    /// copyright holder it names must be in THIRD_PARTY_NOTICES.md, so a new vendored file is not missed.
    /// Scans the shipped packages' checkouts, minus tests, docs and the targets that are not in the app.
    func testEveryVendoredLicenseHeaderIsInTheNotices() throws {
        let notices = try Self.notices().lowercased()
        let packages = Set(ThirdPartyNotices.libraries.filter(\.shipped).compactMap { c -> String? in
            guard let file = c.licenseFile, file.hasPrefix(".build/checkouts/") else { return nil }
            return file.split(separator: "/").prefix(3).joined(separator: "/")
        })
        // Not in the app: BoringSSL and XKCP are built only off Apple platforms, CryptoExtras is not a dependency,
        // and swift-collections' Utils are debugger fixtures.
        let notInTheApp = ["swift-crypto/Sources/CCryptoBoringSSL", "swift-crypto/Sources/CXKCP",
                           "swift-crypto/Sources/CryptoExtras", "swift-collections/Utils"]
        let skippedFolders: Set<String> = ["test", "tests", "Tests", "example", "examples", "Examples", "doc", "docs",
                                           "benchmarks", "Benchmarks", "python", "Plugins", ".github"]
        let extensions: Set<String> = ["h", "hpp", "c", "cc", "cpp", "m", "mm", "metal", "swift", "inc"]
        let phrases = ["Redistributions in binary form", "Permission is granted to anyone to use this software",
                       "Permission is hereby granted", "Licensed under the Apache License", "SPDX-License-Identifier"]
        var checked = 0
        var missing: [String] = []
        XCTAssertTrue(packages.contains(".build/checkouts/mlx-swift"), "\(packages)")
        for package in packages.sorted() {
            let base = Self.root.appendingPathComponent(package)
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in walker {
                let relative = String(url.path.dropFirst(base.path.count + 1))
                if skippedFolders.contains(url.lastPathComponent) || notInTheApp.contains(where: { (package + "/" + relative).hasSuffix($0) }) {
                    walker.skipDescendants()
                    continue
                }
                guard extensions.contains(url.pathExtension),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      phrases.contains(where: text.contains) else { continue }
                checked += 1
                for holder in Self.copyrightHolders(in: text) where !notices.contains(holder.lowercased()) {
                    missing.append("\(package)/\(relative): \(holder)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 10)
        XCTAssertEqual(missing, [], "Vendored code whose copyright holder is not in THIRD_PARTY_NOTICES.md: add it to ThirdPartyNotices")
    }

    /// The holders named by "Copyright …" lines (and SPDX-FileCopyrightText), without years, symbols and e-mails.
    static func copyrightHolders(in text: String) -> Set<String> {
        var holders: Set<String> = []
        for line in text.split(separator: "\n") {
            var s = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t/*!#"))
            guard let prefix = ["Copyright", "SPDX-FileCopyrightText:", "@copyright"].first(where: { s.hasPrefix($0) }) else { continue }
            s = String(s.dropFirst(prefix.count))
            for pattern in [#"(?i)copyright"#, #"(?i)\(c\)"#, "©", #"(?i)all rights reserved\.?"#, "<[^>]*>",
                            #"\b\d{4}(\s*[-,–]\s*(\d{2,4}|present))*\b"#, #"^\s*[-,]?\s*by\s"#] {
                s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
                s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;-"))
            }
            s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !s.isEmpty { holders.insert(s) }
        }
        return holders
    }

    /// The models the app downloads are credited.
    func testTheDownloadedModelsAreListed() throws {
        let urls = ThirdPartyNotices.models.map(\.url)
        let qwen = try XCTUnwrap(TextModelChoice.qwen3_4b.repoID)
        XCTAssertTrue(urls.contains("https://huggingface.co/\(qwen)"))
        XCTAssertTrue(urls.contains("https://huggingface.co/argmaxinc/whisperkit-coreml"))
        XCTAssertTrue(urls.contains("https://huggingface.co/openai/\(ModelCatalog.whisperTokenizerFolder)"))
    }

    func testTheRepositoryIsTheUpdateFeedsRepository() throws {
        let plist = Self.root.appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let feed = try XCTUnwrap(info["SUFeedURL"] as? String)
        XCTAssertTrue(feed.hasPrefix(ThirdPartyNotices.repositoryURL + "/"), feed)
    }

    private func normalized(_ url: String) -> String {
        var s = url.lowercased()
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    /// Whitespace-insensitive form (license files differ only in indentation and line breaks).
    private func squashed(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
