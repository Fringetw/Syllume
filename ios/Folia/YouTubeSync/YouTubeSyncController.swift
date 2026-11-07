import Foundation
import Observation

// Playlist changes cancel old work; only the active account/revision may publish or import audio.
@MainActor @Observable
final class YouTubeSyncController {
    private(set) var snapshot = YouTubeSyncSnapshot()
    private(set) var busy = false
    private(set) var phase = ""
    private(set) var error: String?
    private(set) var statuses: [String: String] = [:]
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let downloader = AudioDownloadService()
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
        cancel(); accountID = id; snapshot = YouTubeSyncSnapshot(); statuses = [:]; error = nil
        guard let id, UUID(uuidString: id) != nil else { return }
        let file = directory.appending(path: id + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { snapshot = try JSONDecoder().decode(YouTubeSyncSnapshot.self, from: Data(contentsOf: file)) }
            catch { error = "無法讀取已儲存的歌單，請重新選擇。" }
        }
    }

    func choose(_ choice: YouTubePlaylistChoice, connection: PlatformConnection, library: LocalLibrary, account: NavidromeAccount?) {
        cancel()
        snapshot.choice = choice; snapshot.songs = []; snapshot.lastSync = nil; error = nil; statuses = [:]
        do { try save() } catch { self.error = "無法保存歌單選擇，請確認可用空間。"; return }
        synchronize(connection: connection, library: library, account: account)
    }

    func cancel() {
        revision = UUID(); task?.cancel(); task = nil; busy = false; phase = ""; statuses = [:]
    }

    func localTrack(for song: SyncedYouTubeSong, library: LocalLibrary) -> Track? {
        snapshot.bindings[song.videoID].flatMap { library.availableTrack($0.trackID) }
    }

    func synchronize(connection: PlatformConnection, library: LocalLibrary, account: NavidromeAccount?) {
        guard !busy, connection.connected, connection.libraryID == accountID, let choice = snapshot.choice else { return }
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
                    entries += page.entries
                    cursor = page.next
                    if let cursor, !seenCursors.insert(cursor).inserted {
                        throw PlatformError.message("歌單分頁回應重複，已保留上次完整同步的內容。")
                    }
                } while cursor != nil
                var songs = entries.compactMap(SyncedYouTubeSong.init)
                let missing = Array(Set(songs.filter { $0.duration == nil }.map(\.videoID))).sorted()
                var durations: [String: Double] = [:]
                for start in stride(from: 0, to: missing.count, by: 50) {
                    durations.merge(try await connection.videoDurations(Array(missing[start..<min(start + 50, missing.count)])), uniquingKeysWith: { _, new in new })
                    try ensureCurrent(ticket, session: session, connection: connection)
                }
                for index in songs.indices where songs[index].duration == nil { songs[index].duration = durations[songs[index].videoID] }
                var next = snapshot; next.songs = songs; next.lastSync = Date()
                try save(next); snapshot = next; statuses = [:]
                var visited = Set<String>()
                for (index, song) in songs.enumerated() where visited.insert(song.videoID).inserted {
                    try ensureCurrent(ticket, session: session, connection: connection)
                    if localTrack(for: song, library: library) != nil { continue }
                    phase = "準備音樂 \(index + 1)／\(songs.count)"
                    statuses[song.videoID] = "正在比對完整音源…"
                    do {
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--youtube-sync-fixture"),
                           let file = Bundle.main.url(forResource: "tide", withExtension: "m4a") {
                            let candidate = DownloadAudioCandidate(url: file, title: song.title, artist: song.artist,
                                duration: 30, format: "m4a", bitrate: 128000, source: "Debug 本機夾具")
                            let track = try await library.importDownload(file, candidate: candidate)
                            try ensureCurrent(ticket, session: session, connection: connection)
                            snapshot.bindings[song.videoID] = YouTubeAudioBinding(trackID: track.id, quality: candidate.quality)
                            try save(); statuses[song.videoID] = nil; continue
                        }
                        #endif
                        if let existing = library.tracks.first(where: {
                            library.availableTrack($0.id) != nil && DownloadSongMatch.matches(song, title: $0.title, artists: [$0.artist ?? ""], duration: $0.duration)
                        }) {
                            snapshot.bindings[song.videoID] = YouTubeAudioBinding(trackID: existing.id, quality: "本機音檔")
                            try save(); continue
                        }
                        guard song.duration != nil else { statuses[song.videoID] = "無法確認歌曲長度，請附加音檔。"; continue }
                        let candidates = try await downloader.candidates(for: song, account: account)
                        try ensureCurrent(ticket, session: session, connection: connection)
                        var installed = false
                        for candidate in candidates {
                            do {
                                statuses[song.videoID] = "下載中 · " + candidate.quality
                                let file = try await downloader.download(candidate)
                                defer { try? FileManager.default.removeItem(at: file) }
                                try ensureCurrent(ticket, session: session, connection: connection)
                                let track = try await library.importDownload(file, candidate: candidate)
                                try ensureCurrent(ticket, session: session, connection: connection)
                                snapshot.bindings[song.videoID] = YouTubeAudioBinding(trackID: track.id, quality: candidate.quality)
                                try save(); installed = true; break
                            } catch is CancellationError { throw CancellationError() }
                            catch { statuses[song.videoID] = Self.message(error) }
                        }
                        if installed { statuses[song.videoID] = nil }
                        else if candidates.isEmpty { statuses[song.videoID] = "找不到同版本的完整音源，可附加音檔。" }
                    } catch is CancellationError { throw CancellationError() }
                    catch { statuses[song.videoID] = Self.message(error) }
                }
            } catch is CancellationError { }
            catch {
                guard revision == ticket else { return }
                self.error = Self.message(error)
            }
        }
    }

    func attach(_ url: URL, to song: SyncedYouTubeSong, library: LocalLibrary) async throws {
        cancel()
        let ticket = revision, id = accountID
        // Import the user's file once, retaining the existing local library's validation.
        let old = Set(library.tracks.map(\.id))
        if let warning = await library.importFiles([url]) { throw PlatformError.message(warning) }
        guard ticket == revision, id == accountID else { return }
        guard let track = library.tracks.first(where: { !old.contains($0.id) }) else { return }
        snapshot.bindings[song.videoID] = YouTubeAudioBinding(trackID: track.id, quality: "手動附加音檔")
        statuses[song.videoID] = nil; try save()
    }

    private func ensureCurrent(_ ticket: UUID, session: UUID, connection: PlatformConnection) throws {
        try Task.checkCancellation()
        guard revision == ticket, connection.sessionID == session, connection.libraryID == accountID else { throw CancellationError() }
    }

    private func save(_ value: YouTubeSyncSnapshot? = nil) throws {
        guard let accountID, UUID(uuidString: accountID) != nil else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value ?? snapshot).write(to: directory.appending(path: accountID + ".json"), options: .atomic)
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? PlatformError { return error.localizedDescription }
        if let error = error as? NavidromeError { return error.localizedDescription }
        if (error as NSError).domain == NSCocoaErrorDomain { return "無法保存或讀取音檔，請確認可用空間。" }
        return "音源讀取失敗，請確認網路後重新同步。"
    }
}
