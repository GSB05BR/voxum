// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum Sounds {
    static func start() { play("Tink") }
    static func stop() { play("Pop") }

    private static func play(_ name: String) {
        guard Settings.shared.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
