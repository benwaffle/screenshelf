import Foundation
import NaturalLanguage

/// Turns text into unit-length sentence vectors with Apple's on-device NaturalLanguage embedding.
@MainActor
public final class Embedder {
    private let model: NLEmbedding?

    public init() {
        model = NLEmbedding.sentenceEmbedding(for: .english)
    }

    public var isAvailable: Bool { model != nil }

    public func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !trimmed.isEmpty, let vector = model.vector(for: trimmed) else { return nil }
        return normalized(vector.map(Float.init))
    }

    /// Bump when `vectors(for:)` changes, so stored vectors get rebuilt.
    public static let version = 2

    /// One vector per short descriptive field, then one per ~300-character chunk of OCR text. Sentence embeddings
    /// match best against short text, so fields are embedded separately instead of as one long description.
    public func vectors(for shot: Screenshot) -> (vectors: [[Float]], fieldCount: Int) {
        let fields = Self.fields(of: shot).compactMap(embed)
        let chunks = Self.chunks(of: shot.ocrLines).prefix(16).compactMap(embed)
        return (fields + chunks, fields.count)
    }

    static func fields(of shot: Screenshot) -> [String] {
        var fields: [String] = []
        if let title = shot.title { fields.append(title) }
        if let summary = shot.summary { fields.append(summary) }
        if !shot.notes.isEmpty { fields.append(shot.notes) }
        if !shot.tags.isEmpty { fields.append(shot.tags.joined(separator: ", ")) }
        if !shot.labels.isEmpty { fields.append(shot.labels.joined(separator: ", ")) }
        return fields
    }

    static func chunks(of lines: [OCRLine], targetLength: Int = 300) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if current.count + line.text.count > targetLength, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? line.text : " " + line.text
        }
        if current.count >= 12 { chunks.append(current) }
        return chunks
    }

    private func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
