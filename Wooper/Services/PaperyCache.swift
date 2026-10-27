import Foundation

/// Offline store for the lens sync: the latest device index plus every
/// article's text, refreshed while the phone has internet, so the reader can
/// be fully synced later with no connectivity at all (airplane, subway, tent).
///
/// Layout (Application Support/lens-cache/):
///   index.ndjson            — verbatim /api/device/index?format=ndjson body
///   articles/<id>-<textAt>.txt — one file per article text version
///
/// Also owns the queue of read-state changes collected from the reader while
/// offline; they flush to papery next time the network is around.
enum PaperyCache {
    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("lens-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var articlesDir: URL {
        let dir = root.appendingPathComponent("articles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: index

    static func saveIndex(_ data: Data) {
        try? data.write(to: root.appendingPathComponent("index.ndjson"), options: .atomic)
    }

    static func loadIndex() -> Data? {
        try? Data(contentsOf: root.appendingPathComponent("index.ndjson"))
    }

    // MARK: articles

    private static func articleURL(id: Int, textAt: UInt32) -> URL {
        articlesDir.appendingPathComponent("\(id)-\(textAt).txt")
    }

    static func article(id: Int, textAt: UInt32) -> Data? {
        try? Data(contentsOf: articleURL(id: id, textAt: textAt))
    }

    static func saveArticle(id: Int, textAt: UInt32, data: Data) {
        // Drop superseded versions of the same article first.
        if let files = try? FileManager.default.contentsOfDirectory(at: articlesDir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("\(id)-") {
                try? FileManager.default.removeItem(at: f)
            }
        }
        try? data.write(to: articleURL(id: id, textAt: textAt), options: .atomic)
    }

    /// Split a server bundle body (repeated <id u32 LE><len u32 LE><bytes>)
    /// into per-article cache files. `versions` maps id -> textAt.
    static func ingestBundle(_ data: Data, versions: [Int: UInt32]) {
        var pos = 0
        let bytes = [UInt8](data)
        while pos + 8 <= bytes.count {
            let id = Int(bytes[pos]) | Int(bytes[pos + 1]) << 8 | Int(bytes[pos + 2]) << 16 | Int(bytes[pos + 3]) << 24
            let len = Int(bytes[pos + 4]) | Int(bytes[pos + 5]) << 8 | Int(bytes[pos + 6]) << 16 | Int(bytes[pos + 7]) << 24
            pos += 8
            guard pos + len <= bytes.count else { break }
            if let textAt = versions[id] {
                saveArticle(id: id, textAt: textAt, data: data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + len)))
            }
            pos += len
        }
    }

    /// Reassemble bundle frames from cache for the requested articles.
    /// Returns the frame stream plus the ids that weren't cached.
    static func buildFrames(_ wanted: [(id: Int, textAt: UInt32)]) -> (frames: Data, missing: [Int]) {
        var frames = Data()
        var missing: [Int] = []
        for item in wanted {
            guard let body = article(id: item.id, textAt: item.textAt) else {
                missing.append(item.id)
                continue
            }
            var header = [UInt8](repeating: 0, count: 8)
            for i in 0..<4 { header[i] = UInt8((item.id >> (8 * i)) & 0xff) }
            let len = body.count
            for i in 0..<4 { header[4 + i] = UInt8((len >> (8 * i)) & 0xff) }
            frames.append(contentsOf: header)
            frames.append(body)
        }
        return (frames, missing)
    }

    /// Remove cached articles that the index no longer lists.
    static func prune(validIDs: Set<Int>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: articlesDir, includingPropertiesForKeys: nil)
        else { return }
        for f in files {
            let stem = f.deletingPathExtension().lastPathComponent
            guard let dash = stem.firstIndex(of: "-"), let id = Int(stem[..<dash]) else { continue }
            if !validIDs.contains(id) { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: offline read-state queue

    private static let pendingKey = "lensPendingReads"

    static func queuePendingRead(id: Int, read: Bool) {
        var queue = UserDefaults.standard.array(forKey: pendingKey) as? [[String: Any]] ?? []
        queue.removeAll { ($0["id"] as? Int) == id }
        queue.append(["id": id, "read": read])
        UserDefaults.standard.set(queue, forKey: pendingKey)
        lensLog("[lens] queued offline read state id=\(id) read=\(read)")
    }

    /// Push queued read states to papery; failures stay queued for next time.
    static func flushPendingReads() async {
        let queue = UserDefaults.standard.array(forKey: pendingKey) as? [[String: Any]] ?? []
        guard !queue.isEmpty else { return }
        var remaining: [[String: Any]] = []
        for item in queue {
            guard let id = item["id"] as? Int, let read = item["read"] as? Bool else { continue }
            do {
                try await PaperyService.setRead(id: id, read: read)
                lensLog("[lens] flushed queued read id=\(id)")
            } catch {
                remaining.append(item)
            }
        }
        UserDefaults.standard.set(remaining, forKey: pendingKey)
    }

    // MARK: full refresh (foreground + background task)

    /// Bring the whole cache current: index plus every article text we don't
    /// hold yet. Cheap when nothing changed (one small request).
    /// The index header line carries a volatile synced_at timestamp; compare
    /// only the entry lines when deciding whether server state actually moved.
    private static func indexBody(_ data: Data?) -> Data {
        guard let data, let nl = data.firstIndex(of: UInt8(ascii: "\n")) else { return data ?? Data() }
        return data[data.index(after: nl)...]
    }

    // Burst coalescing: rapid triggers (a run of in-app swipes, push + pull
    // -to-refresh together) collapse into one running refresh plus at most
    // one trailing re-run — instead of N index fetches and N reader visits.
    @MainActor private static var refreshInFlight = false
    @MainActor private static var refreshQueued = false

    static func refresh() async {
        let proceed = await MainActor.run { () -> Bool in
            if refreshInFlight {
                refreshQueued = true
                return false
            }
            refreshInFlight = true
            return true
        }
        guard proceed else { return }
        await performRefresh()
        let rerun = await MainActor.run { () -> Bool in
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                return true
            }
            return false
        }
        if rerun { await refresh() }
    }

    private static func performRefresh() async {
        do {
            let index = try await PaperyService.deviceIndexNDJSON()
            let changed = indexBody(index) != indexBody(loadIndex())
            saveIndex(index)

            var wanted: [(id: Int, textAt: UInt32)] = []
            var valid = Set<Int>()
            if let text = String(data: index, encoding: .utf8) {
                for line in text.split(separator: "\n").dropFirst() {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = obj["id"] as? Int else { continue }
                    let textAt = UInt32(obj["text_at"] as? Int ?? 0)
                    valid.insert(id)
                    guard textAt != 0 else { continue }
                    if article(id: id, textAt: textAt) == nil { wanted.append((id, textAt)) }
                }
            }
            prune(validIDs: valid)

            var fetched = 0
            var batch = wanted
            while !batch.isEmpty {
                let slice = Array(batch.prefix(25))
                batch.removeFirst(slice.count)
                let data = try await PaperyService.bundleData(ids: slice.map(\.id))
                ingestBundle(data, versions: Dictionary(uniqueKeysWithValues: slice.map { ($0.id, $0.textAt) }))
                fetched += slice.count
            }
            if fetched > 0 { lensLog("[lens] cache refreshed: \(fetched) new articles") }
            await flushPendingReads()
            if changed {
                // Server state moved since the cache last saw it — the reader
                // is stale no matter how we found out (push, pull-to-refresh,
                // in-app toggle). Don't rely on the push echo; nudge directly.
                lensLog("[lens] index changed; nudging reader")
                await MainActor.run {
                    LensSyncService.shared.markServerDirty()
                    LensSyncService.shared.syncNow()
                }
            }
        } catch {
            lensLog("[lens] cache refresh failed: \(error.localizedDescription)")
        }
    }
}
