// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TranscricaoCore
import TranscricaoEngines

/// Runs model downloads one at a time with byte progress, cancel and a failure message. Shared by
/// the first-run window, the model switch in Ajustes and `prepareModels` (missing files).
@MainActor
final class ModelDownloads: ObservableObject {
    /// Non-nil while a download runs.
    @Published private(set) var progress: DownloadProgress?
    /// Last failure (cleared when a new download starts or on `clearFailure`).
    @Published private(set) var failure: String?

    private var task: Task<Void, Error>?

    var isRunning: Bool { progress != nil }

    /// Downloads the items that are still missing, in order. Throws `CancellationError` if
    /// cancelled (no failure message then) or the download error (also stored in `failure`).
    func run(_ items: [ModelDownloadItem]) async throws {
        if let previous = task { _ = await previous.result } // never two downloads into the same folder
        failure = nil
        progress = DownloadProgress(items: items)
        let job = Task { try await self.perform(items) }
        task = job
        defer {
            if task == job { task = nil }
            progress = nil
        }
        do {
            try await job.value
        } catch {
            if job.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                appLog("download cancelled")
                throw CancellationError()
            }
            appLog("download failed", error: error)
            failure = Self.message(for: error)
            throw error
        }
    }

    func cancel() { task?.cancel() }

    func clearFailure() { failure = nil }

    private func perform(_ items: [ModelDownloadItem]) async throws {
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            if !ModelDownloader.isOnDisk(item) {
                try await ModelDownloader.download(item) { [weak self] fraction in
                    Task { @MainActor in
                        // A late sample of a finished item must not move the next one.
                        guard let self, self.progress?.currentIndex == index else { return }
                        self.progress?.update(fraction: fraction)
                    }
                }
            }
            progress?.update(fraction: 1)
            progress?.finishCurrent()
        }
    }

    static func message(for error: Error) -> String {
        if isOffline(error) { return String(localized: "No internet connection. Check the network and try again.") }
        return String(localized: "Download failed (\(error.localizedDescription)).")
    }

    /// The hub libraries wrap the URL error (e.g. WhisperKit's "Model not found… Error: …"), so
    /// the whole chain of underlying errors is checked.
    static func isOffline(_ error: Error, depth: Int = 0) -> Bool {
        let offline: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                                 NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut,
                                 NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed,
                                 NSURLErrorInternationalRoamingOff]
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, offline.contains(ns.code) { return true }
        guard depth < 8 else { return false }
        var underlying = ns.underlyingErrors
        if underlying.isEmpty, let single = ns.userInfo[NSUnderlyingErrorKey] as? Error { underlying = [single] }
        return underlying.contains { isOffline($0, depth: depth + 1) }
    }
}

extension DownloadProgress {
    /// "Downloading Qwen3 4B (2 of 2)… 1.3 GB of 2.7 GB"
    var statusLine: String {
        let name = current?.title ?? items.last?.title ?? String(localized: "models")
        guard items.count > 1 else { return String(localized: "Downloading \(name)… \(text)") }
        let step = min(currentIndex + 1, items.count)
        return String(localized: "Downloading \(name) (\(step) of \(items.count))… \(text)")
    }
}
