import Foundation

/// A group of related screenshots the library proposes as a collection.
public struct CollectionSuggestion: Identifiable, Sendable, Hashable {
    /// Stable for a given set of members, so titles and dismissals can be remembered.
    public var id: String
    /// Newest first.
    public var ids: [Int64]
    /// Written by the on-device model; nil until it has named the group.
    public var title: String?
}

enum Suggester {
    struct Item: Sendable {
        var id: Int64
        var date: Date
        /// Unit-length embedding of the screenshot's title.
        var title: [Float]
    }

    // Two screenshots are related when they were taken close together and are about the same thing (a Slack
    // thread captured over a minute), or are very close in meaning whenever they were taken (network tests
    // spread over weeks).
    static let burstWindow: TimeInterval = 20 * 60
    static let burstSimilarity: Float = 0.5
    static let topicSimilarity: Float = 0.78
    static let sizes = 3...40

    /// Connected groups of related screenshots, newest group first, each group newest first.
    @concurrent
    static func groups(_ items: [Item]) async -> [[Int64]] {
        let items = items.sorted { $0.date > $1.date }
        var parent = Array(items.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in items.indices {
            for j in (i + 1)..<items.count {
                let similarity = SearchEngine.dot(items[i].title, items[j].title)
                let close = items[i].date.timeIntervalSince(items[j].date) <= burstWindow
                if (close && similarity >= burstSimilarity) || similarity >= topicSimilarity {
                    parent[root(i)] = root(j)
                }
            }
        }
        // Indices are in newest-first order, so sorting them keeps each group newest first and lets groups be
        // ordered by their first member.
        return Dictionary(grouping: items.indices, by: root)
            .values
            .map { $0.sorted() }
            .filter { sizes.contains($0.count) }
            .sorted { $0[0] < $1[0] }
            .map { $0.map { items[$0].id } }
    }

    static func key(for ids: [Int64]) -> String {
        ids.sorted().map(String.init).joined(separator: ",")
    }
}
