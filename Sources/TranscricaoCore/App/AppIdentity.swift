// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The app's identity in one place. Renaming the app = `Resources/Info.plist` (name, executable,
/// bundle id, mic text), the product in `Package.swift`, and the constants here.
public enum AppIdentity {
    /// The name when there is no app bundle to read it from (tcli, tests).
    public static let fallbackName = "Voxum"
    /// User-visible name: the bundle's CFBundleDisplayName, else `fallbackName`.
    public static let name: String = name(infoDictionary: Bundle.main.infoDictionary)
    public static let bundleID = "io.github.gsb05br.voxum"
    /// Logger subsystem (`log show --predicate 'subsystem == "io.github.gsb05br.voxum"'`).
    public static let subsystem = bundleID
    /// `~/Library/Application Support/<folderName>`: models and history.
    public static let folderName = "Voxum"
    /// Development environment variables are `<envPrefix>DATA_DIR`, `<envPrefix>DEBUG_SHOW_PANEL`, …
    public static let envPrefix = "VOXUM_"
    /// Preferences suite used with `<envPrefix>DATA_DIR`, so dev runs never change the real ones.
    public static let devDefaultsDomain = bundleID + ".dev"

    /// The full name of a development environment variable (or stdout debug marker).
    public static func env(_ suffix: String) -> String { envPrefix + suffix }

    static func name(infoDictionary: [String: Any]?) -> String {
        guard let display = infoDictionary?["CFBundleDisplayName"] as? String, !display.isEmpty else { return fallbackName }
        return display
    }
}
