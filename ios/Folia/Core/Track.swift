import Foundation

// Queue entries retain stable IDs without persisting authenticated stream URLs.
struct Track: Codable, Identifiable, Equatable, Sendable {
    enum Source: String, Codable { case local, navidrome, demo, catalogue }

    let id: String
    let source: Source
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    var audioFile: String? = nil
    var lyricFile: String? = nil
    var artworkFile: String? = nil
    var coverID: String? = nil
    var playlistSong: SyncedYouTubeSong? = nil
    var preferredLocalID: String? = nil
    var recording: SubtitleSong? = nil
    var integrityChecked: Bool? = nil

    var subtitle: String {
        [artist, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static let demo = Track(id: "folia-demo", source: .demo, title: "潮汐之間",
                            artist: "Syllume 示範音軌", album: nil, duration: 30)
}
