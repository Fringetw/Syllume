import Foundation
@preconcurrency import JavaScriptCore

// Runs the bundled OpenCC conversion independently of WebKit and subtitle providers.
actor NativeSubtitleConverter {
    static let shared = NativeSubtitleConverter(bundleURL: Bundle.main.url(
        forResource: "subtitles", withExtension: "js", subdirectory: "SyllumeSubtitles"))
    private let bundleURL: URL?
    private var context: JSContext?

    init(bundleURL: URL?) { self.bundleURL = bundleURL }

    func convert(_ lines: [LyricLine], preferences: SubtitlePreferences) throws -> [LyricLine] {
        guard preferences.active, !lines.isEmpty else { return lines }
        try Task.checkCancellation()
        if context == nil {
            guard let bundleURL, let runtime = JSContext() else { throw SubtitleReadError("invalid-response") }
            let source = try String(contentsOf: bundleURL, encoding: .utf8)
            runtime.evaluateScript(source, withSourceURL: bundleURL)
            guard runtime.exception == nil else { throw SubtitleReadError("invalid-response") }
            context = runtime
        }
        guard let context, let function = context.objectForKeyedSubscript("FoliaConvertSubtitles"),
              !function.isUndefined else { throw SubtitleReadError("invalid-response") }
        let encoder = JSONEncoder()
        let input = try String(decoding: encoder.encode(lines), as: UTF8.self)
        let settings = try String(decoding: encoder.encode(preferences), as: UTF8.self)
        context.exception = nil
        guard let json = function.call(withArguments: [input, settings])?.toString(),
              context.exception == nil, json.utf8.count <= 16_000_000 else { throw SubtitleReadError("invalid-response") }
        try Task.checkCancellation()
        return try JSONDecoder().decode([LyricLine].self, from: Data(json.utf8))
    }
}
