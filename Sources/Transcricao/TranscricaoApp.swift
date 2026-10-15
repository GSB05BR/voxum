// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@main
enum TranscricaoMain {
    // Strong reference: NSApplication.delegate is weak.
    @MainActor static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
