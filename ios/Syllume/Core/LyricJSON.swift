import Foundation

// Preserve Folium fields (harmony, syllables, ruby, alternate texts and segmentation) across the bridge.
enum LyricJSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([LyricJSON]), object([String: LyricJSON]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([LyricJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: LyricJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    var text: String? { if case .string(let text) = self { return text }; return nil }
}

struct LyricKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension LyricWord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LyricKey.self)
        let extra = try Dictionary(uniqueKeysWithValues: c.allKeys.filter { !["text", "startTime", "endTime"].contains($0.stringValue) }
            .map { ($0.stringValue, try c.decode(LyricJSON.self, forKey: $0)) })
        self.init(text: try c.decode(String.self, forKey: LyricKey("text")),
                  startTime: try c.decode(Double.self, forKey: LyricKey("startTime")),
                  endTime: try c.decode(Double.self, forKey: LyricKey("endTime")), extra: extra)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: LyricKey.self)
        for (key, value) in extra { try c.encode(value, forKey: LyricKey(key)) }
        try c.encode(text, forKey: LyricKey("text"))
        try c.encode(startTime, forKey: LyricKey("startTime"))
        try c.encode(endTime, forKey: LyricKey("endTime"))
    }
}

extension LyricLine {
    var translationText: String? {
        extra["displayTranslation"]?.text ?? translation ?? alternateText(role: "translation")
    }
    var romanizationText: String? { romanization ?? alternateText(role: "romanization") }
    private func alternateText(role: String) -> String? {
        guard case .array(let texts)? = extra["alternateTexts"] else { return nil }
        for value in texts {
            if case .object(let text) = value, text["role"]?.text == role,
               let value = text["text"]?.text, !value.isEmpty { return value }
        }
        return nil
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: LyricKey.self)
        let known = ["startTime", "endTime", "fullText", "translation", "romanization", "words"]
        let extra = try Dictionary(uniqueKeysWithValues: c.allKeys.filter { !known.contains($0.stringValue) }
            .map { ($0.stringValue, try c.decode(LyricJSON.self, forKey: $0)) })
        self.init(startTime: try c.decode(Double.self, forKey: LyricKey("startTime")),
                  endTime: try c.decode(Double.self, forKey: LyricKey("endTime")),
                  fullText: try c.decode(String.self, forKey: LyricKey("fullText")),
                  translation: try c.decodeIfPresent(String.self, forKey: LyricKey("translation")),
                  romanization: try c.decodeIfPresent(String.self, forKey: LyricKey("romanization")),
                  words: try c.decodeIfPresent([LyricWord].self, forKey: LyricKey("words")) ?? [], extra: extra)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: LyricKey.self)
        for (key, value) in extra { try c.encode(value, forKey: LyricKey(key)) }
        try c.encode(startTime, forKey: LyricKey("startTime"))
        try c.encode(endTime, forKey: LyricKey("endTime"))
        try c.encode(fullText, forKey: LyricKey("fullText"))
        try c.encodeIfPresent(translation, forKey: LyricKey("translation"))
        try c.encodeIfPresent(romanization, forKey: LyricKey("romanization"))
        try c.encode(words, forKey: LyricKey("words"))
    }
}
