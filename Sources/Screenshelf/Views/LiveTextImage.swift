import AppKit
import ImageIO
import SwiftUI
import VisionKit

/// Shows an image with system Live Text on top: select and copy text, and use detected links, dates and codes.
struct LiveTextImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LiveTextImageView { LiveTextImageView() }

    func updateNSView(_ view: LiveTextImageView, context: Context) {
        view.load(url)
    }
}

final class LiveTextImageView: NSView {
    private static let analyzer = ImageAnalyzer()

    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private var current: URL?
    private var loading: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        for view in [imageView, overlay] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .automatic
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func load(_ url: URL) {
        guard url != current else { return }
        current = url
        overlay.analysis = nil
        loading?.cancel()
        loading = Task {
            guard let cg = await Self.decode(url) else { return }
            guard !Task.isCancelled else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            imageView.image = image
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            let analysis = try? await Self.analyzer.analyze(cg, orientation: .up, configuration: configuration)
            guard !Task.isCancelled, current == url else { return }
            overlay.analysis = analysis
        }
    }

    /// Screenshots can be 6K wide; 3000px is plenty for an inspector-sized view and for Live Text.
    @concurrent
    private static func decode(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
