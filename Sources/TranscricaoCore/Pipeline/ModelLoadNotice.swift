// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the status line says while the models load at launch. A warm load takes ~3 s and says
/// nothing extra. The first load on a Mac (after a download, a new copy of the app or a macOS
/// update) makes CoreML compile Whisper for the Neural Engine, ~2 min with no progress to report:
/// past `slowAfter` the line explains the wait and shows a running clock, so the app never looks frozen.
public enum ModelLoadNotice {
    /// A warm load is ~3 s; past this the load is a first-time compile.
    public static let slowAfter: TimeInterval = 15
    /// The "up to 3 minutes" of the message; past it the message no longer promises a time.
    public static let estimate: TimeInterval = 180

    /// nil: keep the regular "Preparing models…" line. `knownFirstLoad`: Whisper was just
    /// downloaded, so the long load is certain and explained from the start.
    public static func message(elapsed: TimeInterval, knownFirstLoad: Bool) -> String? {
        guard knownFirstLoad || elapsed >= slowAfter else { return nil }
        let time = clock(elapsed)
        if elapsed >= estimate {
            return String(localized: "Still preparing the models for this Mac… \(time)", bundle: .main)
        }
        return String(localized: "Preparing the models for this Mac (usually only the first time; up to 3 minutes)… \(time)",
                      bundle: .main)
    }

    /// "m:ss", whole seconds rounded down; negative or invalid times read "0:00".
    public static func clock(_ elapsed: TimeInterval) -> String {
        let seconds = elapsed.isFinite ? max(0, Int(elapsed)) : 0
        let rest = seconds % 60
        return "\(seconds / 60):\(rest < 10 ? "0" : "")\(rest)"
    }
}
