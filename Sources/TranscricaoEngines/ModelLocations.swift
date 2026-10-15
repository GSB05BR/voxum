// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os
import TranscricaoCore

private let engineLogger = Logger(subsystem: AppIdentity.subsystem, category: "engines")
/// Load-path diagnostics (never dictated text), prefixed with the app name; visible with
/// `log show --predicate 'subsystem == "<AppIdentity.subsystem>"'`.
func engineLog(_ message: String) { engineLogger.notice("\(AppIdentity.name, privacy: .public): \(message, privacy: .public)") }
/// An error's domain and code are public; its description (it can hold model paths) is private.
func engineLog(_ message: String, error: Error) {
    let ns = error as NSError
    engineLogger.notice("\(AppIdentity.name, privacy: .public): \(message, privacy: .public) (\(ns.domain, privacy: .public) \(ns.code, privacy: .public): \(String(describing: error), privacy: .private))")
}

public enum ModelLocations {
    /// Development override: `VOXUM_DATA_DIR=/some/empty/dir` (`AppIdentity.env("DATA_DIR")`) makes the app (and tcli) keep its
    /// models and history there instead (e.g. to test the first-run download without touching the
    /// real models); the app then also uses a separate UserDefaults suite (see `Settings`).
    /// Unset in normal use. Documented in docs/BUILD.md.
    public static let dataDirOverride: URL? = {
        guard let path = ProcessInfo.processInfo.environment[AppIdentity.env("DATA_DIR")], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }()

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    /// ~/Library/Application Support/Voxum (`AppIdentity.folderName`)
    static var defaultAppSupport: URL {
        applicationSupport.appendingPathComponent(AppIdentity.folderName, isDirectory: true)
    }
    /// ~/Library/Application Support/Voxum, or `VOXUM_DATA_DIR`.
    public static var appSupport: URL { dataDirOverride ?? defaultAppSupport }
    public static var root: URL { ensure(appSupport.appendingPathComponent("Models", isDirectory: true)) }
    public static var whisper: URL { ensure(root.appendingPathComponent("whisperkit", isDirectory: true)) }
    public static var hub: URL { ensure(root.appendingPathComponent("hub", isDirectory: true)) }
    public static var history: URL { ensure(appSupport).appendingPathComponent("history.json") }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
