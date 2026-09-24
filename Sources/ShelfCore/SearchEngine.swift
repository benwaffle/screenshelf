import Foundation

public struct SearchHit: Sendable, Hashable {
    public var id: Int64
    public var score: Double
    /// The query's words appear in the screenshot's text or metadata.
    public var textMatch: Bool
    /// Best cosine similarity between the query and any of the screenshot's text vectors.
    public var semanticSimilarity: Float
}

@MainActor
public enum SearchEngine {
    public enum Mode: Sendable {
        /// Typed into the search field: every word must match, and semantic matches must be close.
        case browse
        /// A natural-language question: any word can match, and looser semantic matches count.
        case question

        // Tuned against NLEmbedding's English sentence model on real screenshots, where unrelated text still
        // scores 0.4–0.55. Relevance is clearer relative to the best match than as an absolute number.

        /// Semantic matches must reach this cosine similarity…
        var floor: Float { self == .browse ? 0.45 : 0.35 }
        /// …and be within this much of the best semantic match.
        var margin: Float { self == .browse ? 0.08 : 0.15 }
    }

    /// OCR chunks are long and noisy, so their similarity is discounted against titles, summaries and tags.
    private static let chunkPenalty: Float = 0.08

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "at", "about", "did", "do", "does", "for", "from", "had", "has", "have", "how", "i",
        "in", "is", "it", "me", "my", "of", "on", "or", "show", "that", "the", "this", "to", "was", "were", "what",
        "when", "where", "which", "who", "why", "with",
    ]

    /// Hybrid search: keyword matches and semantic matches are ranked separately, then merged with reciprocal rank fusion.
    public static func search(
        _ query: String, in shots: [Screenshot], vectors: [Int64: ScreenshotVectors], embedder: Embedder,
        mode: Mode = .browse
    ) -> [SearchHit] {
        let words = query.lowercased()
            .split { $0.isWhitespace || $0 == "?" || $0 == "," }
            .map(String.init)
        let meaningful = words.filter { !stopwords.contains($0) }
        let tokens = meaningful.isEmpty ? words : meaningful
        guard !tokens.isEmpty else { return [] }

        let keyword = shots
            .compactMap { shot in
                keywordScore(tokens: tokens, phrase: query, shot: shot, requireAll: mode == .browse).map { (shot.id, $0) }
            }
            .sorted { $0.1 > $1.1 }

        var semantic: [(Int64, Float)] = []
        if let q = embedder.embed(query) {
            let scored = shots
                .compactMap { shot -> (Int64, Float)? in
                    guard let vs = vectors[shot.id] else { return nil }
                    let field = vs.fields.map { dot($0, q) }.max() ?? 0
                    let chunk = (vs.chunks.map { dot($0, q) }.max() ?? 0) - chunkPenalty
                    return (shot.id, max(field, chunk))
                }
                .sorted { $0.1 > $1.1 }
            let cutoff = max(mode.floor, (scored.first?.1 ?? 0) - mode.margin)
            semantic = scored.filter { $0.1 >= cutoff }
        }

        // Keyword matches weigh double, so exact text hits lead and semantic-only hits follow.
        var hits: [Int64: SearchHit] = [:]
        for (rank, (id, _)) in keyword.enumerated() {
            hits[id] = SearchHit(id: id, score: 2.0 / Double(60 + rank), textMatch: true, semanticSimilarity: 0)
        }
        for (rank, (id, similarity)) in semantic.prefix(60).enumerated() {
            var hit = hits[id] ?? SearchHit(id: id, score: 0, textMatch: false, semanticSimilarity: 0)
            hit.score += 1.0 / Double(60 + rank)
            hit.semanticSimilarity = similarity
            hits[id] = hit
        }
        return hits.values.sorted { $0.score > $1.score }
    }

    /// Screenshots that look like `shot` or are about the same thing, most similar first.
    public static func similar(
        to shot: Screenshot, in shots: [Screenshot], vectors: [Int64: ScreenshotVectors], limit: Int = 12
    ) -> [Int64] {
        guard let mine = vectors[shot.id] else { return [] }
        let others = shots.filter { $0.id != shot.id }

        let visual = others
            .compactMap { other -> (Int64, Float)? in
                guard let fp = vectors[other.id]?.featurePrint, fp.count == mine.featurePrint.count, !fp.isEmpty else { return nil }
                return (other.id, euclidean(fp, mine.featurePrint))
            }
            .sorted { $0.1 < $1.1 }

        let topical = others
            .compactMap { other -> (Int64, Float)? in
                guard let a = mine.fields.first, let b = vectors[other.id]?.fields.first else { return nil }
                return (other.id, dot(a, b))
            }
            .sorted { $0.1 > $1.1 }

        var scores: [Int64: Double] = [:]
        for (rank, (id, _)) in visual.enumerated() { scores[id, default: 0] += 1.0 / Double(20 + rank) }
        for (rank, (id, _)) in topical.enumerated() { scores[id, default: 0] += 1.0 / Double(20 + rank) }
        return scores.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// Matches in the title and tags count for more than matches in OCR text. With `requireAll`, every token has
    /// to appear somewhere; otherwise at least one does.
    static func keywordScore(tokens: [String], phrase: String, shot: Screenshot, requireAll: Bool) -> Double? {
        let fields: [(String, Double)] = [
            (shot.title ?? "", 5), (shot.tags.joined(separator: " "), 4), (shot.notes, 4),
            (shot.category ?? "", 3), (shot.summary ?? "", 3), (shot.labels.joined(separator: " "), 2),
            (shot.filename, 2), (shot.ocrText, 1),
        ]
        var total = 0.0
        for token in tokens {
            if let best = fields.filter({ contains($0.0, token) }).map(\.1).max() {
                total += best
            } else if requireAll {
                return nil
            }
        }
        guard total > 0 else { return nil }
        if tokens.count > 1, contains(shot.ocrText, phrase) || contains(shot.title ?? "", phrase) {
            total += 3
        }
        return total
    }

    /// True when `needle` appears in `haystack` starting at a word boundary, so "iperf" finds "iperf3"
    /// but "imsi" doesn't match inside "optimsite".
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if found.lowerBound == haystack.startIndex { return true }
            let before = haystack[haystack.index(before: found.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    nonisolated static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    nonisolated static func euclidean(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }
}
