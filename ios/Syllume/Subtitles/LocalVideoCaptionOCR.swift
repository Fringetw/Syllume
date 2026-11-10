@preconcurrency import AVFoundation
@preconcurrency import Vision
import Foundation

// Recognize existing on-screen text locally; never synthesize a translation or song timing.
enum LocalVideoCaptionOCR {
    private struct Cue {
        let text: String
        let translation: String?
        let key: String
    }

    static func read(_ url: URL, progress: @Sendable (Double) async -> Void) async throws -> [LyricLine] {
        guard url.isFileURL else { throw SubtitleReadError("video-unavailable") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 600 else { throw SubtitleReadError("video-too-long") }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw SubtitleReadError("video-unavailable") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        return try await withTaskCancellationHandler {
            try await scan(generator, duration: duration, progress: progress)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
            asset.cancelLoading()
        }
    }

    private static func scan(_ generator: AVAssetImageGenerator, duration: Double,
                             progress: @Sendable (Double) async -> Void) async throws -> [LyricLine] {
        let recognizer = try recognitionRequest()
        let step = 0.65
        let steps = Int(ceil(duration / step))
        var rows: [LyricLine] = []
        var pending: LyricLine?
        var key = "", count = 0, last = 0.0
        for index in 0..<steps {
            try Task.checkCancellation()
            let position = Double(index) * step
            if index % 16 == 0 { await progress(position / duration) }
            let stamp = CMTime(seconds: position, preferredTimescale: 600)
            guard let (image, actualTime) = try? await generator.image(at: stamp) else { continue }
            let seconds = actualTime.seconds
            let time = max(last, seconds.isFinite ? seconds : position)
            last = time
            let cue = try recognize(image, with: recognizer)
            let nextKey = cue?.key ?? ""
            if nextKey == key { count += 1; continue }
            if var row = pending, count >= 2, time - row.startTime <= 18 {
                row.endTime = time
                rows.append(row)
            }
            count = 1; key = nextKey
            pending = cue.map { LyricLine(startTime: time, endTime: time + step, fullText: $0.text, translation: $0.translation) }
        }
        if var row = pending, count >= 2, duration - row.startTime <= 18 {
            row.endTime = duration
            rows.append(row)
        }
        try Task.checkCancellation()
        await progress(1)
        let distinct = Set(rows.map { DownloadSongMatch.normalized($0.translation ?? $0.fullText) })
        guard distinct.count >= 3 else { throw SubtitleReadError("ocr-empty") }
        return LyricTimeline(lines: rows).prepared(for: duration).lines
    }

    private static func recognitionRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        let languages = ["zh-Hant", "zh-Hans", "ja-JP", "en-US"].filter { supported.contains($0) }
        guard languages.contains("zh-Hant") || languages.contains("zh-Hans") else { throw SubtitleReadError("ocr-empty") }
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.017
        request.regionOfInterest = CGRect(x: 0.04, y: 0.02, width: 0.92, height: 0.58)
        return request
    }

    private static func recognize(_ image: CGImage, with request: VNRecognizeTextRequest) throws -> Cue? {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        let sorted: [VNRecognizedTextObservation] = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        let recognized: [String] = sorted.compactMap { item in
            guard let top = item.topCandidates(1).first, top.confidence >= 0.4,
                  (2...96).contains(top.string.count) else { return nil }
            return top.string
        }
        let text = recognized.prefix(6).joined(separator: "\n")
        let pair = YouTubeCaptionDecoders.bilingualCue(text)
        let chinese = pair?.chinese ?? recognized.filter(isChineseRow).prefix(4).joined(separator: "\n")
        let key = DownloadSongMatch.normalized(chinese)
        guard key.count >= 2 else { return nil }
        return Cue(text: pair?.original ?? chinese, translation: pair == nil ? nil : chinese, key: key)
    }

    private static func isChineseRow(_ text: String) -> Bool {
        text.unicodeScalars.filter { $0.properties.isIdeographic }.count >= 2
            && text.range(of: #"[\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) == nil
    }
}
