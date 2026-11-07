@preconcurrency import AVFoundation
@preconcurrency import Vision

// Recognize existing on-screen text locally; never synthesize a translation or song timing.
enum YouTubeCaptionOCR {
    static func read(_ url: URL, progress: @Sendable (Double) async -> Void) async throws -> [LyricLine] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 600 else { throw SubtitleReadError("video-too-long") }
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw SubtitleReadError("video-unavailable") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        return try await withTaskCancellationHandler {
            let recognizer = VNRecognizeTextRequest()
            recognizer.recognitionLevel = .accurate
            let supported = Set((try? recognizer.supportedRecognitionLanguages()) ?? [])
            let languages = ["zh-Hant", "zh-Hans", "ja-JP", "en-US"].filter(supported.contains)
            guard !languages.isEmpty else { throw SubtitleReadError("ocr-empty") }
            recognizer.recognitionLanguages = languages
            recognizer.usesLanguageCorrection = true
            recognizer.minimumTextHeight = 0.017
            recognizer.regionOfInterest = CGRect(x: 0.04, y: 0.02, width: 0.92, height: 0.58)
            let step = 0.65
            var rows: [LyricLine] = [], key = "", count = 0
            var pending: LyricLine?
            var last = 0.0
            let steps = Int(ceil(duration / step))
            for index in 0..<steps {
                try Task.checkCancellation()
                let position = Double(index) * step
                if index % 16 == 0 { await progress(position / duration) }
                guard let frame = try? await generator.image(at: CMTime(seconds: position, preferredTimescale: 600)) else { continue }
                try VNImageRequestHandler(cgImage: frame.image, orientation: .up).perform([recognizer])
                let time = max(last, frame.actualTime.seconds.isFinite ? frame.actualTime.seconds : position)
                last = time
                let observations = (recognizer.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                let text = observations.compactMap { item -> String? in
                    guard let top = item.topCandidates(1).first, top.confidence >= 0.4,
                          (2...96).contains(top.string.count) else { return nil }
                    return top.string
                }.prefix(6).joined(separator: "\n")
                let pair = YouTubeCaptionDecoders.bilingualCue(text)
                let chinese = pair?.chinese ?? text.split(whereSeparator: \.isNewline).map(String.init).filter {
                    $0.range(of: #"^[^\p{Hiragana}\p{Katakana}\p{Hangul}]*\p{Han}"#, options: .regularExpression) != nil
                        && $0.range(of: #"[\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) == nil
                }.joined(separator: "\n")
                let nextKey = DownloadSongMatch.normalized(chinese)
                if nextKey == key { count += 1; continue }
                if var row = pending, count >= 2, time - row.startTime <= 18 {
                    row.endTime = time; rows.append(row)
                }
                count = 1; key = nextKey
                pending = nextKey.count < 2 ? nil : LyricLine(startTime: time, endTime: time + step,
                    fullText: pair?.original ?? chinese, translation: pair == nil ? nil : chinese)
            }
            if var row = pending, count >= 2, duration - row.startTime <= 18 { row.endTime = duration; rows.append(row) }
            await progress(1)
            let distinct = Set(rows.map { DownloadSongMatch.normalized($0.translation ?? $0.fullText) })
            guard distinct.count >= 3 else { throw SubtitleReadError("ocr-empty") }
            return LyricTimeline(lines: rows).prepared(for: duration).lines
        } onCancel: { generator.cancelAllCGImageGeneration(); asset.cancelLoading() }
    }
}
