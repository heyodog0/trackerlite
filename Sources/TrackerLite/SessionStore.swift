// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import Foundation

/// The entire persistence layer: one pretty-printed JSON file in iCloud Drive,
/// `~/Library/Mobile Documents/com~apple~CloudDocs/TrackerLite/data.json`, so
/// every Mac signed in to the same iCloud sees the same sessions.
///
/// No database and no permissions to grant — the file is readable and
/// hand-editable. Two Macs can both write it, so nothing here ever overwrites
/// blindly: each write first merges in whatever is on disk (see
/// TrackerData.merged), and iCloud's conflict copies are merged in too. Writes
/// happen on a background queue, and a burst of saves — e.g. typing a running
/// session's note — collapses into one write of the latest snapshot.
///
/// Without iCloud Drive it falls back to `~/Library/Application Support/
/// TrackerLite/data.json`, the pre-sync location.
final class SessionStore: @unchecked Sendable {
    static let localFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("TrackerLite", isDirectory: true)
    }()

    /// The iCloud Drive folder, when iCloud Drive is on.
    static let cloudFolder: URL? = {
        let drive = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("TrackerLite", isDirectory: true)
    }()

    static var folder: URL { cloudFolder ?? localFolder }
    static var fileURL: URL { folder.appendingPathComponent("data.json") }
    private static var localFileURL: URL { localFolder.appendingPathComponent("data.json") }

    private let queue = DispatchQueue(label: "com.heyodog0.trackerlite.store")
    // Touched only on `queue`.
    private var pending: TrackerData?
    private var writeScheduled = false
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadScheduled = false

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The synced file merged with any iCloud conflict copies — and, the first
    /// time on each Mac, with that Mac's pre-sync local file.
    func load() -> TrackerData {
        if Demo.on { return Demo.data }
        return queue.sync {
            var data = readMerged()
            let migratedKey = "migratedToICloud"
            if Self.cloudFolder != nil, !UserDefaults.standard.bool(forKey: migratedKey) {
                if let local = read(Self.localFileURL) { data = data.merged(with: local) }
                write(data)
                UserDefaults.standard.set(true, forKey: migratedKey)
            }
            return data
        }
    }

    /// Write off-main, merged with what's on disk.
    func save(_ data: TrackerData) {
        guard !Demo.on else { return }
        queue.async {
            // Latest snapshot wins. If a write is already queued it hasn't run
            // yet, so it will pick this one up.
            self.pending = data
            guard !self.writeScheduled else { return }
            self.writeScheduled = true
            self.queue.async { self.writePending() }
        }
    }

    /// Calls `changed` (on the main queue) with the file's contents whenever it
    /// changes on disk — another Mac's edits arriving through iCloud, or our own
    /// writes (which the caller's merge then finds already applied).
    func watch(_ changed: @escaping @Sendable (TrackerData) -> Void) {
        guard !Demo.on else { return }
        queue.async {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            // Watch the folder: iCloud and atomic writes replace the file itself.
            let fd = open(Self.folder.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: self.queue)
            src.setEventHandler { [weak self] in
                guard let self, !self.reloadScheduled else { return }
                // iCloud lands a file in a few steps; read once it settles.
                self.reloadScheduled = true
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    self.reloadScheduled = false
                    let data = self.readMerged()
                    DispatchQueue.main.async { changed(data) }
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            self.watcher = src
        }
    }

    // MARK: - on `queue`

    private func writePending() {
        writeScheduled = false
        guard let data = pending else { return }
        pending = nil
        write(readMerged().merged(with: data))
    }

    /// The file plus any conflict copies iCloud kept when both Macs wrote
    /// offline. Merging them in resolves the conflict.
    private func readMerged() -> TrackerData {
        var data = read(Self.fileURL) ?? TrackerData()
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: Self.fileURL) ?? []
        for version in conflicts {
            if let other = read(version.url) { data = data.merged(with: other) }
            version.isResolved = true
        }
        if !conflicts.isEmpty {
            try? NSFileVersion.removeOtherVersionsOfItem(at: Self.fileURL)
            write(data)
        }
        return data
    }

    private func read(_ url: URL) -> TrackerData? {
        var bytes: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) {
            bytes = try? Data(contentsOf: $0)
        }
        guard let bytes else { return nil }
        do {
            return try decoder.decode(TrackerData.self, from: bytes)
        } catch {
            // Don't clobber a file we can't read — park a copy so the data is
            // recoverable by hand.
            NSLog("TrackerLite: unreadable \(url.lastPathComponent) (\(error.localizedDescription)); backing it up")
            try? bytes.write(to: Self.folder.appendingPathComponent("data.corrupt.json"))
            return nil
        }
    }

    private func write(_ data: TrackerData) {
        guard let bytes = try? encoder.encode(data) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            var failure: Error?
            NSFileCoordinator().coordinate(writingItemAt: Self.fileURL, options: .forReplacing, error: nil) {
                do { try bytes.write(to: $0, options: .atomic) } catch { failure = error }
            }
            if let failure { throw failure }
        } catch {
            NSLog("TrackerLite: save failed: \(error.localizedDescription)")
        }
    }
}
