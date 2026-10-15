// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

/// Every `<lang>.lproj` of the app has every key of `en.lproj`, no extra key, and the same format
/// placeholders (`%@`, `%lld`… in any order with `%1$@`). Keys used by the code but missing from
/// `en.lproj` are found by `scripts/check-strings.sh`.
///
/// Every language is complete: none of its tables may be empty (a stub) or miss a key. A
/// translator checks their folder with `swift test --filter LocalizationCompletenessTests`.
final class LocalizationCompletenessTests: XCTestCase {
    static let tables = ["Localizable", "InfoPlist"]

    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Transcricao/Resources")

    static func languages() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: resources.path)
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }

    static func table(_ lang: String, _ name: String) throws -> [String: String] {
        let url = resources.appendingPathComponent("\(lang).lproj/\(name).strings")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: String], "\(lang)/\(name).strings is not a strings table")
    }

    /// No table of `lang` has a key yet.
    static func isStub(_ lang: String) throws -> Bool {
        try tables.allSatisfy { try table(lang, $0).isEmpty }
    }

    /// Placeholders as (argument position, conversion): "%2$@ … %1$lld" → [(1, "lld"), (2, "@")].
    static func placeholders(_ s: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSaAp%])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var next = 1
        var found: [String] = []
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let conversion = String(s[Range(m.range(at: 3), in: s)!])
            if conversion == "%" { continue } // "%%" is a literal percent sign
            let length = Range(m.range(at: 2), in: s).map { String(s[$0]) } ?? ""
            let position: Int
            if let r = Range(m.range(at: 1), in: s) { position = Int(s[r])! } else { position = next; next += 1 }
            found.append("\(position):\(length)\(conversion)")
        }
        return found.sorted()
    }

    func testPlaceholderParsing() {
        XCTAssertEqual(Self.placeholders("Downloading %@ (%lld of %lld)… %@"), ["1:@", "2:lld", "3:lld", "4:@"])
        XCTAssertEqual(Self.placeholders("%2$@ de %1$@"), ["1:@", "2:@"])
        XCTAssertEqual(Self.placeholders("%lld%%"), ["1:lld"])
        XCTAssertNotEqual(Self.placeholders("%@ of %lld"), Self.placeholders("%lld of %@"))
    }

    func testTheV1LanguagesHaveFolders() throws {
        XCTAssertEqual(try Self.languages(), ["en", "es", "fr", "pt-BR", "zh-Hans"])
        XCTAssertFalse(try Self.isStub("en"))
        XCTAssertFalse(try Self.isStub("pt-BR"))
    }

    func testNoStubsLeft() throws {
        for lang in try Self.languages() { XCTAssertFalse(try Self.isStub(lang), "\(lang).lproj is a stub") }
    }

    func testEnglishIsTheBase() throws {
        let en = try Self.table("en", "Localizable")
        XCTAssertGreaterThan(en.count, 100)
        for (key, value) in en {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(Self.placeholders(value), Self.placeholders(key), "en value of \"\(key)\"")
        }
        XCTAssertNotNil(try Self.table("en", "InfoPlist")["NSMicrophoneUsageDescription"])
    }

    func testEveryLanguageMatchesEnglish() throws {
        let translated = try Self.languages().filter { $0 != "en" }
        XCTAssertEqual(translated, ["es", "fr", "pt-BR", "zh-Hans"])
        for name in Self.tables {
            let en = try Self.table("en", name)
            for lang in translated {
                let table = try Self.table(lang, name)
                let missing = Set(en.keys).subtracting(table.keys).sorted()
                let extra = Set(table.keys).subtracting(en.keys).sorted()
                XCTAssertEqual(missing, [], "\(lang)/\(name): missing keys")
                XCTAssertEqual(extra, [], "\(lang)/\(name): keys not in en")
                for (key, value) in table where en[key] != nil {
                    XCTAssertFalse(value.isEmpty, "\(lang): empty \"\(key)\"")
                    XCTAssertEqual(Self.placeholders(value), Self.placeholders(en[key]!),
                                   "\(lang): placeholders of \"\(key)\"")
                }
            }
        }
    }

    /// The app's name comes in as an argument (AppIdentity.name), never as text in a table.
    func testNoTableWritesTheAppName() throws {
        for lang in try Self.languages() {
            for name in Self.tables {
                for (key, value) in try Self.table(lang, name) {
                    XCTAssertFalse(value.contains(AppIdentity.fallbackName), "\(lang)/\(name): \"\(key)\"")
                    XCTAssertFalse(key.contains(AppIdentity.fallbackName), "\(lang)/\(name): \"\(key)\"")
                }
            }
        }
    }
}
