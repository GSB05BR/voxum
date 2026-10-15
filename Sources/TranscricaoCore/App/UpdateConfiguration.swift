// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Automatic updates (spec §6): whether this run may start the updater, and the values the app,
/// `Resources/Info.plist` and `scripts/release.sh` must agree on (a test checks the Info.plist).
public enum UpdateConfiguration {
    /// The public GitHub repository (owner/name) that hosts the releases and the appcast.
    public static let repository = "GSB05BR/voxum"
    /// `SUFeedURL`: the appcast attached to the latest release.
    public static let feedURL = "https://github.com/\(repository)/releases/latest/download/appcast.xml"
    /// `SUScheduledCheckInterval`: one check a day.
    public static let checkInterval = 86_400
    /// `SUPublicEDKey` until the real key from Sparkle's `generate_keys` replaces it. The updater
    /// never starts with it, and `scripts/build-app.sh --release` / `scripts/release.sh` refuse it
    /// (they grep this exact literal).
    public static let publicKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    /// An EdDSA (ed25519) public key as Sparkle stores it: base64 of 32 bytes.
    public static func isValidPublicKey(_ key: String?) -> Bool {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              key != publicKeyPlaceholder, let data = Data(base64Encoded: key) else { return false }
        return data.count == 32
    }

    public enum StartDecision: Equatable {
        /// An installed app with a real key: start the updater (it checks on its own schedule).
        case start
        /// `<envPrefix>DATA_DIR` is set: a development run never checks nor writes update state.
        case developmentRun
        /// Not running from an .app bundle (`swift run`): nothing to update.
        case notAppBundle
        /// `SUPublicEDKey` missing, the placeholder or malformed: Sparkle would refuse to start
        /// (and say so in an alert at every launch).
        case noPublicKey
    }

    public static func decide(dataDirOverride: Bool, bundleURL: URL, publicKey: String?) -> StartDecision {
        if dataDirOverride { return .developmentRun }
        if bundleURL.pathExtension != "app" { return .notAppBundle }
        if !isValidPublicKey(publicKey) { return .noPublicKey }
        return .start
    }
}
