import Foundation
import Network
import Observation

enum PlaylistDownloadStatus: Equatable {
    case waiting(String), resolving, downloading(Int?), lyrics, failed(String), removed, ready(String, String)
    var label: String {
        switch self {
        case .waiting(let text), .failed(let text): text
        case .resolving: "正在配對完整音源"
        case .downloading(let percent): percent.map { "正在下載 \($0)%" } ?? "正在下載"
        case .lyrics: "正在附加同步歌詞"
        case .removed: "檔案已手動移除；點此重新下載"
        case .ready(let provider, let quality): "已下載 · \(provider) · \(quality)"
        }
    }
}

@MainActor @Observable
final class YouTubePlaylistSync {
    private(set) var cache = YouTubePlaylistCache()
    private(set) var choices: [YouTubePlaylistChoice] = []
    private(set) var refreshing = false
    private(set) var loadingChoices = false
    private(set) var error: String?
    private(set) var choiceError: String?
    private(set) var active = true
    private(set) var networkAvailable = false
    private(set) var expensiveNetwork = false
    private(set) var readyCount = 0
    var automatic: Bool { didSet {
        UserDefaults.standard.set(automatic, forKey: "Folia.PlaylistAutomatic")
        if automatic { storageBlocked = false }
        stopDownloads(); pump()
    } }
    var wifiOnly: Bool { didSet { UserDefaults.standard.set(wifiOnly, forKey: "Folia.PlaylistWiFiOnly"); stopDownloads(); pump() } }
    @ObservationIgnored private let library: LocalLibrary
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var verified = false
    @ObservationIgnored private var syncTicket = UUID()
    @ObservationIgnored private var choiceTicket = UUID()
    @ObservationIgnored private var downloadTicket = UUID()
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    private var statuses: [String: PlaylistDownloadStatus] = [:]
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var storageBlocked = false
    @ObservationIgnored private var fingerprints: [String: String] = [:]
    @ObservationIgnored private var rowCounts: [String: Int] = [:]
    @ObservationIgnored private var readyIDs = Set<String>()

    var isFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--playlist-sync-fixture")
        #else
        false
        #endif
    }
    var connectionIdentity: String? { identity }
    #if DEBUG
    var fixtureFileCount: Int { Set(cache.entries.compactMap { track(for: $0)?.id }).count }
    #endif

    init(library: LocalLibrary) {
        self.library = library
        root = URL.applicationSupportDirectory.appending(path: "FoliaPlaylistSync", directoryHint: .isDirectory)
        automatic = UserDefaults.standard.object(forKey: "Folia.PlaylistAutomatic") as? Bool ?? true
        wifiOnly = UserDefaults.standard.object(forKey: "Folia.PlaylistWiFiOnly") as? Bool ?? true
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { self.error = "無法儲存播放清單設定。" }
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied, expensive = path.isExpensive
            Task { @MainActor in
                guard let self else { return }
                self.networkAvailable = available; self.expensiveNetwork = expensive
                if !available || (self.wifiOnly && expensive) { self.stopDownloads() }
                else { self.pump() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Folia.PlaylistNetwork"))
    }

    deinit { monitor.cancel(); syncTask?.cancel(); downloadTask?.cancel() }

    func activate(_ account: String?) {
        let account = isFixture ? "fixture" : account.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        guard identity != account else { return }
        cancelSync(); stopDownloads(); verified = false
        if let old = identity, old != account {
            // Disconnecting clears private YouTube metadata, while the user's music files remain.
            try? FileManager.default.removeItem(at: root.appending(path: old + ".json"))
            try? FileManager.default.removeItem(at: root.appending(path: old + ".bindings.jsonl"))
        }
        identity = account; cache = YouTubePlaylistCache(); choices = []; statuses = [:]; failedAt = [:]; error = nil
        fingerprints = [:]; rowCounts = [:]; readyIDs = []; readyCount = 0
        guard let account else { return }
        #if DEBUG
        if isFixture, ProcessInfo.processInfo.arguments.contains("--playlist-sync-reset") {
            try? FileManager.default.removeItem(at: root.appending(path: account + ".json"))
            try? FileManager.default.removeItem(at: root.appending(path: account + ".bindings.jsonl"))
        }
        #endif
        do {
            let file = root.appending(path: account + ".json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 8_000_000 else { throw PlaylistAudioError.invalidFile }
                let saved = try JSONDecoder().decode(YouTubePlaylistCache.self, from: data)
                guard saved.entries.count <= 10_000, saved.choice?.valid != false else { throw PlaylistAudioError.invalidFile }
                cache = saved
            }
            let journal = root.appending(path: account + ".bindings.jsonl")
            if FileManager.default.fileExists(atPath: journal.path) {
                let data = try Data(contentsOf: journal)
                guard data.count <= 32_000_000 else { throw PlaylistAudioError.invalidFile }
                for line in data.split(separator: 10) {
                    if let saved = try? JSONDecoder().decode(BindingRecord.self, from: Data(line)),
                       YouTubeVideo.validID(saved.videoID) { cache.bindings[saved.videoID] = saved.binding }
                }
            }
        } catch { self.error = "無法讀取先前的清單，請重新選擇播放清單。" }
        reindex()
    }

    func setActive(_ value: Bool) {
        active = value
        if !value { cancelSync(); stopDownloads() } else { pump() }
    }

    @discardableResult func select(_ choice: YouTubePlaylistChoice) -> Bool {
        guard choice.valid, identity != nil else { return false }
        cancelSync(); stopDownloads(); verified = false
        var next = cache
        next.choice = choice; next.entries = []; next.syncedAt = nil
        do { try writeMetadata(next); cache = next; reindex(); statuses = [:]; failedAt = [:]; error = nil; return true }
        catch { self.error = "無法儲存這次選擇，請重試。"; return false }
    }

    func loadChoices(_ connection: PlatformConnection) async {
        guard identity != nil else { return }
        let ticket = UUID(), account = identity
        choiceTicket = ticket; loadingChoices = true; choiceError = nil
        defer { if choiceTicket == ticket { loadingChoices = false } }
        do {
            let lists: [YouTubePlaylistChoice]
            #if DEBUG
            if isFixture {
                lists = [YouTubePlaylistChoice(id: "fixture-second", title: "夜間播放清單")]
            } else {
                lists = try await readChoices(connection)
            }
            #else
            lists = try await readChoices(connection)
            #endif
            guard !Task.isCancelled, identity == account, choiceTicket == ticket else { return }
            choices = [.liked] + lists
        } catch {
            guard !Task.isCancelled, identity == account, choiceTicket == ticket else { return }
            choices = [.liked]; choiceError = "其他清單讀取失敗，請重試。"
        }
    }

    private func readChoices(_ connection: PlatformConnection) async throws -> [YouTubePlaylistChoice] {
        var result: [YouTubePlaylistChoice] = [], cursor: String?, seen = Set<String>()
        repeat {
            let page = try await connection.page(.playlists, cursor: cursor)
            try Task.checkCancellation()
            result += page.entries.map { .init(id: $0.id, title: $0.title) }
            guard result.count <= 10_000 else { throw PlatformError.message("播放清單數量超過可讀取上限。") }
            cursor = page.next
            if let cursor, !seen.insert(cursor).inserted { throw PlaylistAudioError.unavailable }
        } while cursor != nil
        return result
    }

    func synchronize(_ connection: PlatformConnection) async {
        guard active, identity != nil, let choice = cache.choice else { return }
        if let syncTask { await syncTask.value; return }
        let ticket = UUID(), account = identity
        syncTicket = ticket; refreshing = true; error = nil
        let work = Task { [weak self] in
            guard let self else { return }
            defer { if syncTicket == ticket { syncTask = nil; refreshing = false } }
            do {
                let entries: [LibraryEntry]
                #if DEBUG
                if isFixture { entries = fixtureEntries(choice) }
                else { entries = try await readEntries(choice, connection: connection) }
                #else
                entries = try await readEntries(choice, connection: connection)
                #endif
                try Task.checkCancellation()
                guard identity == account, syncTicket == ticket, cache.choice == choice else { return }
                var next = cache; next.entries = entries; next.syncedAt = Date()
                try writeMetadata(next)
                if cache.entries != entries { stopDownloads() }
                cache = next; reindex(); verified = true
                pump()
            } catch {
                guard !Task.isCancelled, identity == account, syncTicket == ticket else { return }
                self.error = (error as? PlatformError)?.errorDescription ?? "同步失敗，已保留上次載入的清單與音樂檔。"
            }
        }
        syncTask = work
        await work.value
    }

    private func readEntries(_ choice: YouTubePlaylistChoice, connection: PlatformConnection) async throws -> [LibraryEntry] {
        var rows: [LibraryEntry] = [], cursor: String?, seen = Set<String>(), rowIDs = Set<String>()
        repeat {
            let page = try await connection.page(choice.collection, cursor: cursor)
            try Task.checkCancellation()
            rows += page.entries.filter { rowIDs.insert($0.id).inserted }
            guard rows.count <= 10_000 else { throw PlatformError.message("這份清單超過 10,000 個項目的上限。") }
            cursor = page.next
            if let cursor, !seen.insert(cursor).inserted { throw PlaylistAudioError.unavailable }
        } while cursor != nil
        var ids: [String] = [], videos = Set<String>()
        for row in rows {
            if let id = PlaylistAudioRules.videoID(row), videos.insert(id).inserted { ids.append(id) }
        }
        var details: [String: LibraryEntry] = [:]
        for start in stride(from: 0, to: ids.count, by: 50) {
            let page = try await connection.youtubeDetails(Array(ids[start..<min(start + 50, ids.count)]))
            try Task.checkCancellation()
            for item in page { if let id = PlaylistAudioRules.videoID(item) { details[id] = item } }
        }
        return rows.map { row in
            guard let id = PlaylistAudioRules.videoID(row), let detail = details[id] else { return row }
            return LibraryEntry(id: row.id, title: detail.title, subtitle: detail.subtitle, url: row.url, duration: detail.duration)
        }
    }

    func track(for entry: LibraryEntry) -> Track? {
        guard let id = PlaylistAudioRules.videoID(entry), let binding = cache.bindings[id],
              binding.fingerprint == fingerprints[id], let track = library.track(binding.trackID),
              library.assetURL(for: track) != nil else { return nil }
        return track
    }

    func status(for entry: LibraryEntry) -> PlaylistDownloadStatus {
        guard let id = PlaylistAudioRules.videoID(entry) else { return .failed("無法讀取這個項目的歌曲資訊。") }
        if let track = track(for: entry) {
            return .ready(track.downloadProvider == "qq" ? "QQ 音樂" : "網易雲", track.downloadQuality ?? "原始音檔")
        }
        if let binding = cache.bindings[id], binding.fingerprint == fingerprints[id] { return .removed }
        if storageBlocked { return .waiting("儲存空間不足，釋放空間後可點此重試") }
        if !automatic { return .waiting("自動下載已暫停") }
        if !verified { return .waiting("等待同步") }
        if !active { return .waiting("返回 App 後接續下載") }
        if !isFixture, !networkAvailable { return .waiting("等待網路") }
        if !isFixture, wifiOnly && expensiveNetwork { return .waiting("等待 Wi-Fi") }
        return statuses[id] ?? .waiting("等待下載")
    }

    func retry(_ entry: LibraryEntry) {
        guard let id = PlaylistAudioRules.videoID(entry) else { return }
        if cache.bindings[id] != nil, track(for: entry) == nil {
            do { try appendBinding(.init(videoID: id, binding: .init(fingerprint: "", trackID: "", provider: "", quality: ""))) }
            catch { self.error = "無法儲存重新下載設定，請確認儲存空間。"; return }
            cache.bindings[id] = nil
        }
        failedAt[id] = nil; statuses[id] = nil; storageBlocked = false; error = nil
        if readyIDs.remove(id) != nil { readyCount = max(0, readyCount - (rowCounts[id] ?? 0)) }
        pump()
    }

    func retryPending() { storageBlocked = false; failedAt = [:]; statuses = [:]; error = nil; pump() }

    private func reindex() {
        fingerprints = [:]; rowCounts = [:]; readyIDs = []; readyCount = 0
        for entry in cache.entries {
            guard let id = PlaylistAudioRules.videoID(entry) else { continue }
            rowCounts[id, default: 0] += 1
            if fingerprints[id] == nil { fingerprints[id] = PlaylistAudioRules.fingerprint(entry) }
        }
        for (id, fingerprint) in fingerprints {
            if let binding = cache.bindings[id], binding.fingerprint == fingerprint,
               let track = library.track(binding.trackID), library.assetURL(for: track) != nil {
                readyIDs.insert(id); readyCount += rowCounts[id] ?? 0
            }
        }
    }

    private func pump() {
        guard downloadTask == nil, automatic, active, verified, identity != nil, !storageBlocked,
              isFixture || (networkAvailable && (!wifiOnly || !expensiveNetwork)) else { return }
        var videos = Set<String>()
        let pending = cache.entries.filter { entry in
            guard let id = PlaylistAudioRules.videoID(entry), videos.insert(id).inserted,
                  track(for: entry) == nil else { return false }
            if let binding = cache.bindings[id], binding.fingerprint == fingerprints[id] { return false }
            return Date().timeIntervalSince(failedAt[id] ?? .distantPast) >= 3600
        }
        guard !pending.isEmpty else { return }
        let ticket = UUID(), account = identity
        downloadTicket = ticket
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { if downloadTicket == ticket { downloadTask = nil; pump() } }
            for entry in pending {
                guard !Task.isCancelled, downloadTicket == ticket, account == identity,
                      let id = PlaylistAudioRules.videoID(entry) else { return }
                do {
                    if let existing = reusable(entry) {
                        try bind(existing, entry: entry); continue
                    }
                    statuses[id] = .resolving
                    #if DEBUG
                    if isFixture { try await downloadFixture(entry); continue }
                    #endif
                    try await download(entry, ticket: ticket)
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, downloadTicket == ticket, account == identity else { return }
                    let problem = error as? PlaylistAudioError ?? .unavailable
                    statuses[id] = .failed(problem.localizedDescription); failedAt[id] = Date()
                    if problem == .storage { storageBlocked = true; self.error = problem.localizedDescription; break }
                }
            }
        }
    }

    private func reusable(_ entry: LibraryEntry) -> Track? {
        guard let id = PlaylistAudioRules.videoID(entry), let old = library.downloadedTrack(origin: id),
              library.assetURL(for: old) != nil, let requested = PlaylistAudioRules.song(entry),
              PlaylistAudioRules.matches(SubtitleSong(id: old.id, source: "local", title: old.title,
                  artist: old.artist ?? "", durationMs: (old.duration ?? 0) * 1000), requested: requested) else { return nil }
        return old
    }

    private func download(_ entry: LibraryEntry, ticket: UUID) async throws {
        guard let id = PlaylistAudioRules.videoID(entry) else { throw PlaylistAudioError.noMatch }
        let sources = try await PlaylistAudioSources.shared.resolve(entry)
        var best: (URL, DownloadableAudio, InspectedPlaylistAudio)?
        var failure: Error = PlaylistAudioError.noAudio
        var blocked = Set<String>()
        defer { if let file = best?.0 { try? FileManager.default.removeItem(at: file) } }
        for source in sources {
            try Task.checkCancellation()
            if blocked.contains(source.provider) { continue }
            if let best, source.qualityRank <= best.2.rank { break }
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            do {
                let transfer = PlaylistAudioTransfer(source: source, wifiOnly: wifiOnly) { [weak self] percent in
                    Task { @MainActor in
                        guard let self, self.downloadTicket == ticket else { return }
                        self.statuses[id] = .downloading(percent)
                    }
                }
                let file = try await transfer.run(); temporary = file
                try Task.checkCancellation()
                let checked = try await InspectedPlaylistAudio.inspect(file, source: source)
                try Task.checkCancellation()
                if best == nil || checked.rank > best!.2.rank {
                    if let old = best?.0 { try? FileManager.default.removeItem(at: old) }
                    best = (file, source, checked); temporary = nil
                }
                if checked.rank >= source.qualityRank { break }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
                if error as? PlaylistAudioError == .rateLimited {
                    blocked.insert(source.provider)
                    await PlaylistAudioSources.shared.coolDown(source.provider)
                }
            }
        }
        guard let chosen = best else { throw failure }
        statuses[id] = .lyrics
        let lyrics = await PlaylistAudioSources.shared.lyrics(chosen.1)
        try Task.checkCancellation()
        guard downloadTicket == ticket else { throw CancellationError() }
        let track = try library.registerDownload(chosen.0, song: chosen.1.song, ext: chosen.1.fileExtension,
            duration: chosen.2.duration, lyrics: lyrics, origin: id, provider: chosen.1.provider, quality: chosen.2.quality)
        do { try bind(track, entry: entry) }
        catch { try? library.remove(track.id); throw PlaylistAudioError.storage }
    }

    private struct BindingRecord: Codable { let videoID: String; let binding: PlaylistAudioBinding }

    private func bind(_ track: Track, entry: LibraryEntry) throws {
        guard let id = PlaylistAudioRules.videoID(entry) else { throw PlaylistAudioError.noMatch }
        let binding = PlaylistAudioBinding(fingerprint: PlaylistAudioRules.fingerprint(entry), trackID: track.id,
            provider: track.downloadProvider ?? "", quality: track.downloadQuality ?? "")
        try appendBinding(.init(videoID: id, binding: binding))
        cache.bindings[id] = binding; statuses[id] = nil; failedAt[id] = nil
        if readyIDs.insert(id).inserted { readyCount += rowCounts[id] ?? 0 }
    }

    private func appendBinding(_ record: BindingRecord) throws {
        guard let identity else { throw CancellationError() }
        let file = root.appending(path: identity + ".bindings.jsonl")
        var data = try JSONEncoder().encode(record); data.append(10)
        if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic); return }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 8_000_000 {
            var bindings = cache.bindings
            if record.binding.trackID.isEmpty { bindings[record.videoID] = nil }
            else { bindings[record.videoID] = record.binding }
            let current = Set(cache.entries.compactMap(PlaylistAudioRules.videoID))
            let keys = bindings.keys.sorted { left, right in
                if current.contains(left) != current.contains(right) { return current.contains(left) }
                return left < right
            }.prefix(20_000)
            var compact = Data(), kept: [String: PlaylistAudioBinding] = [:]
            for key in keys {
                guard let binding = bindings[key] else { continue }
                compact.append(try JSONEncoder().encode(BindingRecord(videoID: key, binding: binding))); compact.append(10)
                kept[key] = binding
            }
            try compact.write(to: file, options: .atomic); cache.bindings = kept
            return
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if last?.first != 10 { try handle.write(contentsOf: Data([10])) }
        }
        try handle.write(contentsOf: data)
    }

    private func writeMetadata(_ next: YouTubePlaylistCache) throws {
        guard let identity else { throw CancellationError() }
        var metadata = next; metadata.bindings = [:]
        let data = try JSONEncoder().encode(metadata)
        guard data.count <= 8_000_000 else { throw PlaylistAudioError.storage }
        try data.write(to: root.appending(path: identity + ".json"), options: .atomic)
    }

    private func cancelSync() { syncTicket = UUID(); syncTask?.cancel(); syncTask = nil; refreshing = false; choiceTicket = UUID(); loadingChoices = false }
    private func stopDownloads() {
        downloadTicket = UUID(); downloadTask?.cancel(); downloadTask = nil
        statuses = statuses.filter { if case .failed = $0.value { return true }; return false }
    }

    #if DEBUG
    private func fixtureEntries(_ choice: YouTubePlaylistChoice) -> [LibraryEntry] {
        let other = choice.id != YouTubePlaylistChoice.liked.id
        let entry = LibraryEntry(id: other ? "fixture-row-second" : "fixture-row-liked", title: other ? "夜色的回聲" : "潮汐之間",
            subtitle: "Folia 測試", url: URL(string: "https://music.youtube.com/watch?v=" + (other ? "bbbbbbbbbbb" : "aaaaaaaaaaa"))!,
            duration: 30)
        if other { return [entry] }
        return [entry, LibraryEntry(id: "fixture-row-duplicate", title: entry.title, subtitle: entry.subtitle,
                                   url: entry.url, duration: entry.duration),
            LibraryEntry(id: "fixture-unavailable", title: "暫時找不到音源", subtitle: "Folia 測試",
                         url: URL(string: "https://music.youtube.com/watch?v=zzzzzzzzzzz")!, duration: 30)]
    }

    private func downloadFixture(_ entry: LibraryEntry) async throws {
        guard let id = PlaylistAudioRules.videoID(entry), let source = Bundle.main.url(forResource: "tide", withExtension: "m4a") else {
            throw PlaylistAudioError.invalidFile
        }
        if id == "zzzzzzzzzzz" { throw PlaylistAudioError.noAudio }
        let copied = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        try FileManager.default.copyItem(at: source, to: copied)
        defer { try? FileManager.default.removeItem(at: copied) }
        let song = SubtitleSong(id: id, source: "fixture", title: entry.title, artist: entry.subtitle, durationMs: 30_000)
        let inspected = try await InspectedPlaylistAudio.inspect(copied, source: DownloadableAudio(provider: "netease",
            song: song, url: URL(string: "https://m1.music.126.net/fixture.m4a")!, fileExtension: "m4a", qualityRank: 20, bitrate: 0))
        try Task.checkCancellation()
        let lyricFile = Bundle.main.url(forResource: "tide", withExtension: "lrc")
        let lines = lyricFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { LyricTimeline(lrc: $0).lines } ?? []
        let track = try library.registerDownload(copied, song: song, ext: "m4a", duration: inspected.duration, lyrics: lines,
            origin: id, provider: "netease", quality: "本機測試音檔 · " + inspected.quality)
        do { try bind(track, entry: entry) }
        catch { try? library.remove(track.id); throw error }
    }
    #endif
}
