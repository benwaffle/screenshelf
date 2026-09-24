import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct VisionResult: Sendable {
    public var lines: [OCRLine]
    public var labels: [String]
    public var featurePrint: [Float]
    public var pixelWidth: Int
    public var pixelHeight: Int

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

public enum VisionAnalyzer {
    /// Labels too generic to say anything about a screenshot.
    private static let ignoredLabels: Set<String> = ["screenshot", "document", "text", "structure", "material"]

    public static func analyze(_ url: URL) async throws -> VisionResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }

        var ocr = RecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = true
        ocr.automaticallyDetectsLanguage = true

        async let textObservations = ocr.perform(on: image)
        async let classifications = ClassifyImageRequest().perform(on: image)
        async let featurePrint = GenerateImageFeaturePrintRequest().perform(on: image)

        let lines = try await textObservations
            .map { OCRLine(text: $0.transcript, box: $0.boundingBox.cgRect) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted(by: readingOrder)

        let labels = try await classifications
            .filter { $0.confidence >= 0.3 && !ignoredLabels.contains($0.identifier) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(8)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }

        return VisionResult(
            lines: lines,
            labels: labels,
            featurePrint: floats(from: try await featurePrint),
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Top-to-bottom, then left-to-right. Lines whose vertical centers are within half a line height count as one row.
    private static func readingOrder(_ a: OCRLine, _ b: OCRLine) -> Bool {
        let tolerance = min(a.box.height, b.box.height) / 2
        if abs(a.box.midY - b.box.midY) > tolerance { return a.box.midY > b.box.midY }
        return a.box.minX < b.box.minX
    }

    private static func floats(from observation: FeaturePrintObservation) -> [Float] {
        let data = observation.data
        switch observation.elementType {
        case .double:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }.map(Float.init)
        default:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }
}
