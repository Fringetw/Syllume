import Foundation
import Observation

// Imported playlists retain local edits while the original YouTube list stays read-only.
@MainActor @Observable
final class YouTubeSyncController {
    private(set) var snapshot = YouTubeSyncSnapshot()
    private(set) var busy = false
    private(set) var phase = ""
    private(set) var error: String?
    private(set) var statuses: [String: String] = [:]
    private(set) var downloading: String?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadRevision = UUID()
    @ObservationIgnored private let downloader = AudioDownloadService.shared
    @ObservationIgnored private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Folia/YouTubeSync", directoryHint: .isDirectory)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--youtube-sync-reset") {
            try? FileManager.default.removeItem(at: self.directory.appending(path: "021A0A60-4BED-4416-8784-A4C7416A4A11.json"))
        }
        #endif
    }

    func activate(_ connection: PlatformConnection) {
        let id = connection.connected ? connection.libraryID : nil
        guard id != accountID else { return }
        cancel(); cancelDownload(); accountID = id; snapshot = YouTubeSyncSnapshot(); statuses = [:]; error = nil
        guard let id, UUID(uuidString: id) != nil else { return }
        let file = directory.appending(path: id + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { snapshot = try JSONDecoder().decode(YouTubeSyncSnapshot.self, from: Data(contentsOf: file)) }
            catch { self.error = "無法讀取已儲存的歌單，請重新選擇。" }
        }
    }

    func choose(_ choice: YouTubePlaylistChoice, connection: PlatformConnection) {
        cancel()
        var next = snapshot, saved = snapshot.saved ?? [:]
        if let previous = snapshot.choice {
            saved[previous.id] = FoliaSavedPlaylist(choice: previous, songs: snapshot.songs, lastSync: snapshot.lastSync)
        }
        next.choice = choice; next.saved = saved
        next.songs = saved[choice.id]?.songs ?? []; next.lastSync = saved[choice.id]?.lastSync
        do { try save(next); error = nil; synchronize(connection: connection) }
        catch { self.error = "無法保存歌單選擇，請確認可用空間。" }
    }

    func cancel() {
        revision = UUID(); task?.cancel(); task = nil; busy = false; phase = ""
    }

    func localTrack(for song: SyncedYouTubeSong, library: LocalLibrary) -> Track? {
        (snapshot.bindings[song.videoID]?.trackID ?? song.localTrackID).flatMap(library.availableTrack)
    }

    func rename(_ name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit { $0.name = title.isEmpty ? nil : String(title.prefix(100)) }
    }
    func add(_ track: Track) { edit { $0.added.append(SyncedYouTubeSong(local: track)) } }
    func remove(_ song: SyncedYouTubeSong) {
        edit {
            if $0.added.contains(where: { $0.id == song.id }) { $0.added.removeAll { $0.id == song.id } }
            else { $0.removed.insert(song.id) }
            $0.order.removeAll { $0 == song.id }
        }
    }
    func reorder(_ rows: [SyncedYouTubeSong]) { edit { $0.order = rows.map(\.id) } }

    private func edit(_ change: (inout FoliaPlaylistEdits) -> Void) {
        guard let choice = snapshot.choice else { return }
        var next = snapshot, edits = snapshot.edits ?? [:], current = snapshot.currentEdits
        change(&current); edits[choice.id] = current; next.edits = edits
        do { try save(next); error = nil } catch { self.error = "無法儲存歌單編輯。" }
    }

    func synchronize(connection: PlatformConnection) {
        guard !busy, connection.connected, connection.libraryID == accountID,
              let choice = snapshot.choice, !choice.isLocal else { return }
        let ticket = UUID(), session = connection.sessionID
        revision = ticket; busy = true; phase = "正在同步歌單…"; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if revision == ticket { busy = false; phase = ""; task = nil } }
            do {
                var entries: [LibraryEntry] = [], cursor: String?, seenCursors = Set<String>()
                repeat {
                    let page = try await connection.page(choice.collection, cursor: cursor)
                    try ensureCurrent(ticket, session: session, connection: connection)
                    entries += page.entries; cursor = page.next
                    if entries.count > 10_000 || (cursor.map { !seenCursors.insert($0).inserted } ?? false) {
                        throw PlatformError.message("歌單太長或分頁回應重複，已保留上次同步的內容。")
                    }
                } while cursor != nil
                var songs = entries.compactMap(SyncedYouTubeSong.init)
                var durations: [String: Double] = [:]
                var portraits: [String: (name: String, url: URL)] = [:]
                for song in snapshot.songs {
                    if let duration = song.duration { durations[song.videoID] = duration }
                    if let channel = song.channelID, let image = song.avatarURL { portraits[channel] = (song.artist, image) }
                }
                let missing = Array(Set(songs.filter { $0.duration == nil && durations[$0.videoID] == nil }.map(\.videoID))).sorted()
                for start in stride(from: 0, to: missing.count, by: 50) {
                    let batch = Array(missing[start..<min(start + 50, missing.count)])
                    if let result = try? await connection.videoDurations(batch) { durations.merge(result, uniquingKeysWith: { _, new in new }) }
                    try ensureCurrent(ticket, session: session, connection: connection)
                }
                let channels = Array(Set(songs.compactMap(\.channelID).filter {
                    portraits[$0] == nil && $0.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil
                })).sorted()
                for start in stride(from: 0, to: channels.count, by: 50) {
                    if let result = try? await connection.channelPortraits(Array(channels[start..<min(start + 50, channels.count)])) {
                        portraits.merge(result, uniquingKeysWith: { _, new in new })
                    }
                    try ensureCurrent(ticket, session: session, connection: connection)
                }
                for index in songs.indices {
                    var song = songs[index]
                    song.duration = song.duration ?? durations[song.videoID]
                    if let channel = song.channelID, let portrait = portraits[channel],
                       !YouTubeCaptionDecoders.isTranslatedUpload(song.title),
                       DownloadSongMatch.versions(song.title).isEmpty {
                        let metadata = YouTubeCaptionDecoders.metadata(id: song.videoID, title: song.title,
                            artist: song.artist, duration: song.duration ?? 0)
                        if !DownloadSongMatch.artistKeys(metadata.artist).isDisjoint(with: DownloadSongMatch.artistKeys(portrait.name)) {
                            song.avatarURL = portrait.url
                        }
                    }
                    songs[index] = song
                }
                var next = snapshot; next.songs = songs; next.lastSync = Date(); next.attempts = nil
                try save(next)
            } catch is CancellationError { }
            catch { if revision == ticket { self.error = Self.message(error) } }
        }
    }

    func cancelDownload() {
        downloadRevision = UUID(); downloadTask?.cancel(); downloadTask = nil
        if let downloading { statuses[downloading] = nil }
        downloading = nil
    }

    func download(_ song: SyncedYouTubeSong, library: LocalLibrary, account: NavidromeAccount?) {
        guard downloading == nil, let accountID, YouTubeVideo.validID(song.videoID) else { return }
        let ticket = UUID()
        downloadRevision = ticket; downloading = song.videoID; statuses[song.videoID] = "正在搜尋最高可用音質…"
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { if downloadRevision == ticket { downloading = nil; downloadTask = nil } }
            @MainActor func check() throws {
                try Task.checkCancellation()
                guard downloadRevision == ticket, self.accountID == accountID else { throw CancellationError() }
            }
            @MainActor func bind(_ track: Track, _ quality: String) throws {
                try check()
                var next = snapshot
                next.bindings[song.videoID] = YouTubeAudioBinding(trackID: track.id, quality: quality)
                try save(next); statuses[song.videoID] = nil
            }
            @MainActor func install(_ candidate: DownloadAudioCandidate) async throws {
                try check()
                if let id = candidate.localTrackID, let track = library.availableTrack(id), track.id.hasPrefix("download-") {
                    _ = try await AudioIntegrity.inspect(candidate.url, expected: candidate.duration, decode: track.integrityChecked != true)
                    try bind(track, candidate.quality)
                    return
                }
                statuses[song.videoID] = "下載並檢查 · " + candidate.quality
                let file = candidate.url.isFileURL ? candidate.url : try await downloader.download(candidate)
                defer { if !candidate.url.isFileURL { try? FileManager.default.removeItem(at: file) } }
                try check()
                var resolved = candidate
                if resolved.recording == nil {
                    resolved.recording = SubtitleSong(id: song.videoID, source: "catalogue", title: candidate.title,
                        artist: candidate.artist, durationMs: candidate.duration * 1000)
                }
                resolved.recording?.originVideoID = song.videoID
                let track = try await library.importDownload(file, candidate: resolved)
                do { try bind(track, candidate.quality) }
                catch { try? library.remove(track.id); throw error }
            }
            do {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture"),
                   let file = Bundle.main.url(forResource: "tide", withExtension: "m4a") {
                    try await install(DownloadAudioCandidate(url: file, title: song.title, artist: song.artist, duration: 30,
                        format: "m4a", bitrate: 128000, source: "示範音軌"))
                    return
                }
                #endif
                let target = await downloader.withDuration(song)
                var candidates = library.matchingAudio(for: target)
                var failures: [String] = []
                do { candidates += try await downloader.candidates(for: target, account: account) }
                catch is CancellationError { throw CancellationError() }
                catch { failures.append(Self.message(error)) }
                for candidate in candidates.sorted(by: DownloadAudioCandidate.preferred) {
                    do { try await install(candidate); return }
                    catch is CancellationError { throw CancellationError() }
                    catch { failures.append(candidate.source + "：" + Self.message(error)) }
                }
                try check()
                statuses[song.videoID] = "正在檢查 YouTube 原影片的音訊…"
                do {
                    for candidate in try await downloader.youtube(target) {
                        do { try await install(candidate); return }
                        catch is CancellationError { throw CancellationError() }
                        catch { failures.append("YouTube：" + Self.message(error)) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("YouTube：" + Self.message(error)) }
                try check()
                statuses[song.videoID] = failures.last ?? "各來源沒有可儲存的完整音檔。可附加已有的音檔。"
            } catch is CancellationError { }
            catch { if downloadRevision == ticket { statuses[song.videoID] = Self.message(error) } }
        }
    }

    func attach(_ url: URL, to song: SyncedYouTubeSong, library: LocalLibrary) async throws {
        guard !library.importInProgress else { throw PlatformError.message("請等目前音檔匯入完成後重試。") }
        let id = accountID
        let old = Set(library.tracks.map(\.id))
        if let warning = await library.importFiles([url]) { throw PlatformError.message(warning) }
        guard id == accountID, let track = library.tracks.first(where: { !old.contains($0.id) }) else { return }
        var next = snapshot
        next.bindings[song.videoID] = YouTubeAudioBinding(trackID: track.id, quality: "手動附加音檔")
        try save(next); statuses[song.videoID] = nil
    }

    private func ensureCurrent(_ ticket: UUID, session: UUID, connection: PlatformConnection) throws {
        try Task.checkCancellation()
        guard revision == ticket, connection.sessionID == session, connection.libraryID == accountID else { throw CancellationError() }
    }

    private func save(_ value: YouTubeSyncSnapshot) throws {
        guard let accountID, UUID(uuidString: accountID) != nil else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appending(path: accountID + ".json"), options: .atomic)
        snapshot = value
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? SubtitleReadError { return error.explanation }
        if let error = error as? PlatformError { return error.localizedDescription }
        if let error = error as? NavidromeError { return error.localizedDescription }
        if (error as NSError).code == CocoaError.fileReadCorruptFile.rawValue { return "音檔無法完整解碼。" }
        if (error as NSError).domain == NSCocoaErrorDomain { return "無法保存或讀取音檔，請確認可用空間。" }
        return "來源連線或讀取失敗。"
    }
}
