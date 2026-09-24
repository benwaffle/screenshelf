import Foundation
import FoundationModels

public struct Enrichment: Sendable {
    public var title: String
    public var summary: String
    public var category: String
    public var tags: [String]
}

public struct Category: Sendable, Hashable {
    public var name: String
    public var symbol: String

    public static let all: [Category] = [
        Category(name: "Code", symbol: "chevron.left.forwardslash.chevron.right"),
        Category(name: "Terminal & Logs", symbol: "terminal"),
        Category(name: "Errors", symbol: "exclamationmark.triangle"),
        Category(name: "Chat & Messages", symbol: "bubble.left.and.bubble.right"),
        Category(name: "Email", symbol: "envelope"),
        Category(name: "Documents & Notes", symbol: "doc.text"),
        Category(name: "Web Pages", symbol: "safari"),
        Category(name: "Social Media", symbol: "person.2"),
        Category(name: "Shopping & Receipts", symbol: "cart"),
        Category(name: "Travel & Maps", symbol: "map"),
        Category(name: "Finance", symbol: "dollarsign.circle"),
        Category(name: "Charts & Dashboards", symbol: "chart.xyaxis.line"),
        Category(name: "Design & UI", symbol: "paintbrush"),
        Category(name: "Photos & Media", symbol: "photo"),
        Category(name: "Settings & System", symbol: "gearshape"),
        Category(name: "Calendar & Events", symbol: "calendar"),
        Category(name: "Other", symbol: "square.grid.2x2"),
    ]

    public static func symbol(for name: String) -> String {
        all.first { $0.name == name }?.symbol ?? "tag"
    }
}

/// Uses Apple's on-device foundation model to describe screenshots and answer questions about them.
///
/// The model reads text only, so it works from what Vision extracted: OCR text, detected labels, and the file name.
@MainActor
public enum Enricher {
    public static var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }

    public static var availabilityDescription: String {
        switch availability {
        case .available: "Apple Intelligence is ready"
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to get titles, summaries and Ask"
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple Intelligence"
        case .unavailable(.modelNotReady): "The on-device model is still downloading"
        case .unavailable: "The on-device model is unavailable"
        }
    }

    private static let instructions = """
        You organize a person's screenshots. For each screenshot you get the text recognized on screen (OCR; \
        it can be noisy and out of order), objects detected in the image, and the file name. \
        Work out what the screenshot shows: the app or website, what the person was looking at, and the key specifics \
        such as names, numbers, error codes, dates and places. Use only facts from the input. Do not invent details.
        """

    private static let schema: GenerationSchema = {
        let root = DynamicGenerationSchema(name: "ScreenshotDescription", properties: [
            .init(name: "title",
                  description: "A specific 3 to 7 word title, like 'Diameter CCR failure in SMF logs' or 'Flight confirmation SFO to JFK'",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "summary",
                  description: "One or two sentences on what the screenshot shows and the details someone would search for later",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "category",
                  schema: DynamicGenerationSchema(name: "Category", anyOf: Category.all.map(\.name))),
            .init(name: "tags",
                  description: "3 to 6 short lowercase search keywords: app names, topics, people, products",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1, maximumElements: 6)),
        ])
        // The schema is a fixed literal, so this cannot fail at runtime.
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    public static func describe(_ shot: Screenshot) async throws -> Enrichment {
        do {
            return try await describe(shot, ocrLimit: 3000)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return try await describe(shot, ocrLimit: 1000)
        }
    }

    private static func describe(_ shot: Screenshot, ocrLimit: Int) async throws -> Enrichment {
        let session = LanguageModelSession(instructions: instructions)
        let ocr = shot.ocrText.isEmpty ? "(no text on screen)" : String(shot.ocrText.prefix(ocrLimit))
        let prompt = """
            File name: \(shot.filename)
            Objects detected: \(shot.labels.isEmpty ? "none" : shot.labels.joined(separator: ", "))
            Text on screen:
            \(ocr)
            """
        let response = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0.2))
        let content = response.content
        return Enrichment(
            title: try content.value(String.self, forProperty: "title").trimmingCharacters(in: .whitespacesAndNewlines),
            summary: try content.value(String.self, forProperty: "summary").trimmingCharacters(in: .whitespacesAndNewlines),
            category: try content.value(String.self, forProperty: "category"),
            tags: try content.value([String].self, forProperty: "tags").map { $0.lowercased() }
        )
    }

    /// A short name for a collection holding `shots`, like "Spam service alert thread".
    public static func nameCollection(_ shots: [Screenshot]) async throws -> String {
        let listing = shots.prefix(10).map { shot in
            "- \(shot.displayTitle): \(shot.summary?.prefix(160) ?? "")"
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You name collections of screenshots. Reply with only the name: 2 to 5 words, title case, \
            specific to what the screenshots have in common, no quotes and no trailing punctuation.
            """)
        let response = try await session.respond(
            to: "Screenshots in the collection:\n\(listing)", options: GenerationOptions(temperature: 0.3))
        // The model sometimes lists several candidates, one per line, or shouts in capitals.
        let first = response.content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*\"'“”.")) }
            .first { !$0.isEmpty } ?? ""
        return first == first.uppercased() ? first.capitalized : first
    }

    /// Streams an answer to `question` grounded in `sources`. Sources are cited as [1], [2], … in source order.
    public static func answer(_ question: String, sources: [Screenshot]) -> AsyncThrowingStream<String, Error> {
        let context = sources.enumerated().map { index, shot in
            """
            [\(index + 1)] \(shot.displayTitle) (taken \(shot.createdAt.formatted(date: .abbreviated, time: .shortened)))
            \(shot.summary ?? "")
            Text on screen: \(shot.ocrText.prefix(700))
            """
        }.joined(separator: "\n\n")

        let session = LanguageModelSession(instructions: """
            You answer questions about a person's screenshots. Answer only from the screenshots given. \
            Cite the screenshots you used like [1] or [2]. If the answer is not in them, say you couldn't find it. \
            Keep answers short.
            """)
        let prompt = "Screenshots:\n\(context)\n\nQuestion: \(question)"

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
