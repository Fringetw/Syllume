import Foundation

// Queue entries retain stable IDs without persisting authenticated stream URLs.
struct Track: Codable, Identifiable, Equatable, Sendable {
    enum Source: String, Codable { case local, navidrome, demo }

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
    var downloadedFile: String? = nil
    var downloadOrigin: String? = nil
    var downloadProvider: String? = nil
    var downloadQuality: String? = nil

    var subtitle: String {
        [artist, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static let demo = Track(id: "folia-demo", source: .demo, title: "潮汐之間",
                            artist: "Folia 示範音軌", album: nil, duration: 30)
}
