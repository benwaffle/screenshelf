import Foundation

/// One line of recognized text. `box` is normalized to the image with a lower-left origin (Vision's convention).
public struct OCRLine: Codable, Sendable, Hashable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// How far through the indexing pipeline a screenshot has gone.
public enum AnalysisStage: Int, Sendable, Comparable {
    /// Discovered on disk, nothing extracted yet.
    case discovered = 0
    /// Vision has run: OCR text, labels, and a feature print exist.
    case analyzed = 1
    /// The on-device language model has written a title, summary, category, and tags.
    case enriched = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct Screenshot: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var path: String
    /// The file's inode number, used to follow a file across renames.
    public var fileNumber: UInt64
    public var createdAt: Date
    public var fileSize: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var ocrText: String
    public var ocrLines: [OCRLine]
    public var labels: [String]
    public var title: String?
    public var summary: String?
    public var category: String?
    public var tags: [String]
    public var notes: String
    public var isFavorite: Bool
    public var stage: AnalysisStage
    /// Set when the file is gone from disk. The row is kept so notes survive a file moving out and back.
    public var isMissing: Bool

    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { url.lastPathComponent }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return url.deletingPathExtension().lastPathComponent
    }

    public init(
        id: Int64 = 0, path: String, fileNumber: UInt64, createdAt: Date, fileSize: Int64,
        pixelWidth: Int = 0, pixelHeight: Int = 0, ocrText: String = "", ocrLines: [OCRLine] = [],
        labels: [String] = [], title: String? = nil, summary: String? = nil, category: String? = nil,
        tags: [String] = [], notes: String = "", isFavorite: Bool = false,
        stage: AnalysisStage = .discovered, isMissing: Bool = false
    ) {
        self.id = id
        self.path = path
        self.fileNumber = fileNumber
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.ocrText = ocrText
        self.ocrLines = ocrLines
        self.labels = labels
        self.title = title
        self.summary = summary
        self.category = category
        self.tags = tags
        self.notes = notes
        self.isFavorite = isFavorite
        self.stage = stage
        self.isMissing = isMissing
    }
}

/// Vectors used for similarity. Kept apart from `Screenshot` so SwiftUI diffing stays cheap.
public struct ScreenshotVectors: Sendable {
    /// Vision image feature print, for "looks like this" similarity.
    public var featurePrint: [Float]
    /// Unit-length sentence embeddings: first one per descriptive field (title, summary, tags…), then one per
    /// chunk of OCR text.
    public var text: [[Float]]
    /// How many leading entries of `text` are descriptive fields rather than OCR chunks.
    public var fieldCount: Int

    public init(featurePrint: [Float] = [], text: [[Float]] = [], fieldCount: Int = 0) {
        self.featurePrint = featurePrint
        self.text = text
        self.fieldCount = fieldCount
    }

    public var fields: ArraySlice<[Float]> { text.prefix(fieldCount) }
    public var chunks: ArraySlice<[Float]> { text.dropFirst(fieldCount) }
}

public struct ShotCollection: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var name: String
    public var createdAt: Date

    public init(id: Int64, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
