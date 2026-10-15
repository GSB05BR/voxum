// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Last N dictation results (and transcribed files), newest first, persisted as JSON. Used from
/// the main actor.
public final class HistoryStore {
    private let fileURL: URL
    private let limit: Int
    public private(set) var entries: [DictationResult] = []

    public init(fileURL: URL, limit: Int = 50) {
        self.fileURL = fileURL
        self.limit = limit
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([DictationResult].self, from: data) {
            entries = Array(decoded.prefix(limit))
        }
    }

    public func append(_ result: DictationResult) {
        entries.insert(result, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    /// Replaces the newest entry matching `isSame` (e.g. a transcribed file organized later); a
    /// no-op when it has left the history.
    public func update(_ result: DictationResult, where isSame: (DictationResult) -> Bool) {
        guard let index = entries.firstIndex(where: isSame) else { return }
        entries[index] = result
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("%@", "\(AppIdentity.name): failed to save history: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
