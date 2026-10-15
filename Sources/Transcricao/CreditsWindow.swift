// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import TranscricaoCore

/// "Credits": the app's license and the third-party models and libraries, from the same Swift source
/// as THIRD_PARTY_NOTICES.md (`ThirdPartyNotices`). Opened from the main window and the app menu.
@MainActor
final class CreditsWindowController: NSObject, NSWindowDelegate {
    private static var shared: CreditsWindowController?
    private var window: NSWindow?

    static func show() {
        let controller = shared ?? CreditsWindowController()
        shared = controller
        controller.present()
    }

    private func present() {
        AppActivation.windowWillShow()
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: CreditsView()))
        w.title = String(localized: "Credits")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 520, height: 640))
        w.contentMinSize = NSSize(width: 420, height: 360)
        w.center()
        w.delegate = self
        return w
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { AppActivation.windowWillClose(window) }
    }
}

struct CreditsView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    Text(AppIdentity.name).font(.title2.weight(.semibold))
                    Text(verbatim: Updater.versionText).font(.callout).foregroundStyle(.secondary)
                    Text("\(AppIdentity.name) is free software, released under \(ThirdPartyNotices.projectLicense).")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = URL(string: ThirdPartyNotices.repositoryURL) {
                        Link(destination: url) { Text(verbatim: ThirdPartyNotices.repositoryURL) }
                    }
                    HStack {
                        Button("License text…") { BundledTextWindowController.show(.license) }
                            .disabled(!BundledTextWindowController.Document.license.isBundled)
                        Button("Third-party license texts…") { BundledTextWindowController.show(.notices) }
                            .disabled(!BundledTextWindowController.Document.notices.isBundled)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            Section {
                ForEach(ThirdPartyNotices.models, id: \.url) { row($0) }
            } header: {
                Text("Models")
            } footer: {
                Text("The models are not part of the app: they are downloaded from Hugging Face the first time they are needed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(ThirdPartyNotices.libraries, id: \.url) { row($0) }
            } header: {
                Text("Libraries")
            } footer: {
                Text("\(AppIdentity.name) uses these models and libraries under their own licenses. Their authors are not affiliated with \(AppIdentity.name) and do not endorse it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
    }

    private func row(_ component: ThirdPartyComponent) -> some View {
        LabeledContent {
            Text(verbatim: component.license).font(.callout.monospaced()).foregroundStyle(.secondary)
        } label: {
            if let url = URL(string: component.url) {
                Link(destination: url) { Text(verbatim: component.name) }
            } else {
                Text(verbatim: component.name)
            }
            Text(verbatim: component.copyright)
            if !component.shipped {
                Text("Only resolved while building; not part of the app.")
            }
        }
    }
}

/// A text file bundled by build-app.sh (the GPL, THIRD_PARTY_NOTICES.md with every third-party license
/// and NOTICE text), shown read-only in its own window. Unbundled runs (`swift run`) have neither file.
@MainActor
final class BundledTextWindowController: NSObject, NSWindowDelegate {
    enum Document: CaseIterable {
        case license, notices

        var url: URL? {
            switch self {
            case .license: Bundle.main.url(forResource: "LICENSE", withExtension: nil)
            case .notices: Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
            }
        }

        var isBundled: Bool { url != nil }

        var title: String {
            switch self {
            case .license: "GNU General Public License v3.0"
            case .notices: String(localized: "Third-party license texts")
            }
        }
    }

    private static var open: [Document: BundledTextWindowController] = [:]
    private let document: Document
    private var window: NSWindow?

    private init(_ document: Document) { self.document = document }

    static func show(_ document: Document) {
        let controller = open[document] ?? BundledTextWindowController(document)
        open[document] = controller
        controller.present()
    }

    private func present() {
        guard let url = document.url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            appLog("bundled text missing: \(document)")
            return
        }
        AppActivation.windowWillShow()
        let window = self.window ?? makeWindow(text)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(_ text: String) -> NSWindow {
        let view = ReadOnlyTextView(text: text, followsEnd: false, monospaced: true).padding(12)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = document.title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 720, height: 640))
        w.contentMinSize = NSSize(width: 420, height: 300)
        w.center()
        w.delegate = self
        return w
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { AppActivation.windowWillClose(window) }
    }
}
