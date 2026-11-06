import AVFoundation
import Foundation
import Observation

// Copies Files imports into the app sandbox and keeps a separate local catalog.
@MainActor @Observable
final class LocalLibrary {
    private(set) var tracks: [Track] = [] { didSet { rebuildIndex() } }
    private(set) var importInProgress = false
    private(set) var storageError: String?
    private let storage: URL
    private let lyricReader = LyricReader()
    @ObservationIgnored private var pendingAttachments: [String: UUID] = [:]
    @ObservationIgnored private var tracksByID: [String: Track] = [:]
    @ObservationIgnored private var downloadsByOrigin: [String: Track] = [:]

    init() {
        storage = URL.applicationSupportDirectory.appending(path: "FoliaMusic", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: index.path) {
                tracks = try JSONDecoder().decode([Track].self, from: Data(contentsOf: index))
            }
            removeOrphans()
        } catch {
            storageError = "無法讀取本機曲庫。"
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        downloadsByOrigin = Dictionary(tracks.compactMap { track in track.downloadOrigin.map { ($0, track) } },
                                       uniquingKeysWith: { first, _ in first })
    }

    func track(_ id: String) -> Track? { _ = tracks.count; return tracksByID[id] }
    func downloadedTrack(origin: String) -> Track? { _ = tracks.count; return downloadsByOrigin[origin] }

    static var downloadDirectory: URL { URL.documentsDirectory.appending(path: "Music", directoryHint: .isDirectory) }

    func assetURL(for track: Track) -> URL? {
        if let name = track.downloadedFile {
            guard PlaylistAudioRules.validBasename(name) else { return nil }
            let root = Self.downloadDirectory.resolvingSymlinksInPath()
            let url = root.appending(path: name).resolvingSymlinksInPath()
            guard url.deletingLastPathComponent() == root, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        return track.audioFile.map { folder(for: track.id).appending(path: $0) }
    }

    func registerDownload(_ file: URL, song: SubtitleSong, ext: String, duration: Double, lyrics: [LyricLine],
                          origin: String, provider: String, quality: String) throws -> Track {
        guard ["flac", "mp3", "m4a"].contains(ext), duration.isFinite, duration > 0, YouTubeVideo.validID(origin) else {
            throw PlaylistAudioError.invalidFile
        }
        let id = UUID().uuidString
        let root = Self.downloadDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var directory = root; try? directory.setResourceValues(excluded)
        let filename = PlaylistAudioRules.safeFilename(title: song.title, artist: song.artist, id: String(id.prefix(8)), ext: ext)
        guard PlaylistAudioRules.validBasename(filename) else { throw PlaylistAudioError.invalidFile }
        let target = root.appending(path: filename)
        let metadataFolder = folder(for: id)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        do {
            // The transfer is already validated. A unique name never overwrites a user's file.
            try FileManager.default.moveItem(at: file, to: target)
            var track = Track(id: id, source: .local, title: song.title, artist: song.artist, album: nil,
                              duration: duration, downloadedFile: filename, downloadOrigin: origin,
                              downloadProvider: provider, downloadQuality: quality)
            if !lyrics.isEmpty, let data = try? PlaylistAudioRules.fia(lyrics), data.count <= 8_000_000 {
                try data.write(to: metadataFolder.appending(path: "downloaded.fia"), options: .atomic)
                track.lyricFile = "downloaded.fia"
            }
            try save(tracks + [track])
            return track
        } catch {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: metadataFolder)
            throw error
        }
    }

    func artwork(for track: Track) -> Data? {
        guard let name = track.artworkFile else { return nil }
        return try? Data(contentsOf: folder(for: track.id).appending(path: name))
    }

    func lyrics(for track: Track) async throws -> LyricTimeline? {
        guard let name = track.lyricFile else { return nil }
        return try await lyricReader.timeline(at: folder(for: track.id).appending(path: name))
    }

    func importFiles(_ urls: [URL]) async -> String? {
        guard !importInProgress else { return nil }
        if let storageError { return storageError }
        importInProgress = true
        defer { importInProgress = false }
        let sidecars = urls.filter { ["lrc", "fia"].contains($0.pathExtension.lowercased()) }
        let audio = urls.filter { !sidecars.contains($0) }
        var failures: [String] = []
        var usedSidecars = Set<URL>()
        for url in audio {
            let matches = sidecars.filter { $0.deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(url.deletingPathExtension().lastPathComponent) == .orderedSame }
            let preferred = matches.filter { $0.pathExtension.lowercased() == "fia" }
                + matches.filter { $0.pathExtension.lowercased() != "fia" }
            do {
                let invalidSidecar = try await importAudio(url, sidecars: preferred)
                usedSidecars.formUnion(matches)
                if let invalidSidecar { failures.append(invalidSidecar) }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        let unmatched = sidecars.filter { !usedSidecars.contains($0) }.map(\.lastPathComponent)
        var messages: [String] = []
        if !failures.isEmpty { messages.append("無法匯入 " + failures.joined(separator: "、")) }
        if !unmatched.isEmpty { messages.append("歌詞檔請從歌曲的選單附加，或與同名音檔一起匯入。") }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func importAudio(_ url: URL, sidecars: [URL]) async throws -> String? {
        let id = UUID().uuidString
        let folder = folder(for: id)
        let name = "audio." + url.pathExtension.lowercased()
        let destination = folder.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.coordinatedRead(url) { readable in
                    try FileManager.default.copyItem(at: readable, to: destination)
                }
            }.value
            let asset = AVURLAsset(url: destination)
            guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            let title = await Self.metadataString(.commonIdentifierTitle, in: metadata)
            let artist = await Self.metadataString(.commonIdentifierArtist, in: metadata)
            let album = await Self.metadataString(.commonIdentifierAlbumName, in: metadata)
            let seconds = (try? await asset.load(.duration))?.seconds
            var track = Track(id: id, source: .local, title: title ?? url.deletingPathExtension().lastPathComponent,
                              artist: artist, album: album, duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                              audioFile: name)
            if let artwork = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await artwork.load(.dataValue), data.count <= 8_000_000 {
                try data.write(to: folder.appending(path: "cover"), options: .atomic)
                track.artworkFile = "cover"
            }
            for sidecar in sidecars {
                if let data = try? await Self.readValidatedLyrics(sidecar) {
                    let name = "attached." + sidecar.pathExtension.lowercased()
                    try data.write(to: folder.appending(path: name), options: .atomic)
                    track.lyricFile = name
                    break
                }
            }
            let invalidSidecar = track.lyricFile == nil ? sidecars.first?.lastPathComponent : nil
            if track.lyricFile == nil, let text = try? await asset.load(.lyrics), text.utf8.count <= 8_000_000,
               !LyricTimeline(lrc: text).lines.isEmpty {
                let name = "embedded.lrc"
                try Data(text.utf8).write(to: folder.appending(path: name), options: .atomic)
                track.lyricFile = name
            }
            try save(tracks + [track])
            return invalidSidecar
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func attachLyrics(_ url: URL, to id: String) async throws {
        let revision = UUID()
        pendingAttachments[id] = revision
        defer {
            if pendingAttachments[id] == revision { pendingAttachments[id] = nil }
        }
        let data: Data
        do { data = try await Self.readValidatedLyrics(url) }
        catch {
            guard pendingAttachments[id] == revision else { return }
            throw error
        }
        guard pendingAttachments[id] == revision else { return }
        guard let position = tracks.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let ext = url.pathExtension.lowercased()
        let old = tracks[position].lyricFile
        let name = UUID().uuidString + "." + ext
        let destination = folder(for: id).appending(path: name)
        try data.write(to: destination, options: .atomic)
        var updated = tracks
        updated[position].lyricFile = name
        do { try save(updated) }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if let old { try? FileManager.default.removeItem(at: folder(for: id).appending(path: old)) }
    }

    func remove(_ id: String) throws {
        guard let removed = tracks.first(where: { $0.id == id }) else { return }
        let downloaded = removed.downloadedFile == nil ? nil : assetURL(for: removed)
        try save(tracks.filter { $0.id != id })
        pendingAttachments[id] = nil
        try? FileManager.default.removeItem(at: folder(for: id))
        if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
    }

    // A process can stop after copying files and before atomically updating the catalog.
    private func removeOrphans() {
        let manager = FileManager.default
        let liveIDs = Set(tracks.map(\.id))
        let folders = (try? manager.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)) ?? []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil
            && !liveIDs.contains(folder.lastPathComponent) {
            try? manager.removeItem(at: folder)
        }
        for track in tracks {
            let files = (try? manager.contentsOfDirectory(at: folder(for: track.id), includingPropertiesForKeys: nil)) ?? []
            for file in files where ["lrc", "fia"].contains(file.pathExtension.lowercased())
                && file.lastPathComponent != track.lyricFile {
                try? manager.removeItem(at: file)
            }
        }
    }

    private var index: URL { storage.appending(path: "catalog.json") }

    private func folder(for id: String) -> URL { storage.appending(path: id, directoryHint: .isDirectory) }

    private func save(_ updated: [Track]) throws {
        if storageError != nil { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(updated).write(to: index, options: .atomic)
        tracks = updated
    }

    private static func metadataString(_ key: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: key).first,
              let value = try? await item.load(.stringValue),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private actor LyricReader {
        func timeline(at url: URL) throws -> LyricTimeline {
            try Task.checkCancellation()
            return try LocalLibrary.parseLyrics(LocalLibrary.readLyricData(from: url), extension: url.pathExtension.lowercased())
        }
    }

    nonisolated private static func readValidatedLyrics(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let data = try Self.coordinatedRead(url, read: Self.readLyricData)
            guard try !Self.parseLyrics(data, extension: url.pathExtension.lowercased()).lines.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }.value
    }

    nonisolated private static func coordinatedRead<T>(_ url: URL, read: (URL) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try read(readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    nonisolated private static func readLyricData(from url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        guard data.count <= 8_000_000 else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    nonisolated private static func parseLyrics(_ data: Data, extension ext: String) throws -> LyricTimeline {
        if ext == "fia" { return try LyricTimeline(folia: data) }
        let utf16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard ext == "lrc", let text = String(data: data, encoding: utf16BOM ? .utf16 : .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return LyricTimeline(lrc: text)
    }
}
