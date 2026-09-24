import AppKit
import ShelfCore
import SwiftUI

struct DetailView: View {
    @Environment(Library.self) private var library
    let shot: Screenshot
    @Bindable var browser: Browser

    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var showText = false
    @State private var similar: [Screenshot] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                image
                header
                actions
                if let summary = shot.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                chips
                collectionsSection
                notes
                textSection
                similarSection
            }
            .padding(16)
        }
        .onAppear {
            titleDraft = shot.title ?? ""
            notesDraft = shot.notes
        }
        .onChange(of: shot.title) { titleDraft = shot.title ?? "" }
        .task(id: titleDraft) {
            guard titleDraft != (shot.title ?? "") else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let isBlank = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            edit { $0.title = isBlank ? nil : titleDraft }
        }
        .task(id: notesDraft) {
            guard notesDraft != shot.notes else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            edit { $0.notes = notesDraft }
        }
        .task(id: "\(shot.id)|\(shot.stage.rawValue)") {
            similar = library.similar(to: shot)
        }
    }

    // MARK: Sections

    private var image: some View {
        let aspect = shot.pixelWidth > 0 && shot.pixelHeight > 0 ? Double(shot.pixelWidth) / Double(shot.pixelHeight) : 16.0 / 10.0
        return LiveTextImage(url: shot.url)
            .overlay { SearchHighlights(lines: matchingLines) }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
            }
            // Very tall screenshots would otherwise push everything else out of view.
            .frame(maxWidth: .infinity, maxHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $titleDraft, prompt: Text(shot.displayTitle), axis: .vertical)
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
            HStack(spacing: 6) {
                Text(shot.createdAt, format: .dateTime.weekday().month().day().year().hour().minute())
                if shot.pixelWidth > 0 {
                    Text("·")
                    Text(verbatim: "\(shot.pixelWidth) × \(shot.pixelHeight)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button(shot.filename) { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
                .buttonStyle(.link)
                .font(.caption)
                .help("Show in Finder")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(shot.url) }
            Button("Copy", systemImage: "doc.on.doc") { ShotActions.copyImage(shot) }
            ShareLink(item: shot.url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(shot.isFavorite ? "Unfavorite" : "Favorite", systemImage: shot.isFavorite ? "star.fill" : "star") {
                library.setFavorite([shot.id], !shot.isFavorite)
            }
            .foregroundStyle(shot.isFavorite ? .yellow : .primary)
            Menu {
                ShotMenu(ids: [shot.id], browser: browser)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var chips: some View {
        let hasChips = shot.category != nil || !shot.tags.isEmpty
        if hasChips {
            FlowLayout(spacing: 6) {
                if let category = shot.category {
                    Chip(text: category, symbol: Category.symbol(for: category), prominent: true) {
                        browser.query = ""
                        browser.sidebar = .category(category)
                    }
                }
                ForEach(shot.tags, id: \.self) { tag in
                    Chip(text: tag, symbol: nil, prominent: false) { browser.query = tag }
                }
            }
        } else if shot.stage < .enriched, Enricher.availability == .available {
            Label("Apple Intelligence will describe this soon", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var collectionsSection: some View {
        let mine = library.collections.filter { library.membership[$0.id]?.contains(shot.id) == true }
        if !mine.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(mine) { collection in
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.stack")
                        Text(collection.name)
                        Button {
                            library.remove([shot.id], from: collection.id)
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $notesDraft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 54)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var textSection: some View {
        if !shot.ocrText.isEmpty {
            DisclosureGroup(isExpanded: $showText) {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(shot.ocrText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    Button("Copy Text") { ShotActions.copyText(shot) }
                        .controlSize(.small)
                }
                .padding(.top, 6)
            } label: {
                Text("Text on Screen · \(shot.ocrLines.count) lines")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var similarSection: some View {
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Similar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(similar) { other in
                        Button {
                            browser.select(other.id)
                        } label: {
                            Thumbnail(path: other.path, maxPixelSize: 300)
                                .frame(height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(other.displayTitle)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    /// OCR lines containing any searched word, to highlight on the image.
    private var matchingLines: [OCRLine] {
        let words = browser.query.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return [] }
        return shot.ocrLines.filter { line in
            words.contains { line.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Applies `change` to the latest stored copy, so edits never clobber fresher indexing results.
    private func edit(_ change: (inout Screenshot) -> Void) {
        guard var latest = library.screenshot(shot.id) else { return }
        change(&latest)
        library.update(latest)
    }
}

private struct SearchHighlights: View {
    let lines: [OCRLine]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let rect = CGRect(
                    x: line.box.minX * geo.size.width,
                    y: (1 - line.box.maxY) * geo.size.height,
                    width: line.box.width * geo.size.width,
                    height: line.box.height * geo.size.height
                ).insetBy(dx: -3, dy: -2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(.yellow.opacity(0.28))
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct Chip: View {
    let text: String
    let symbol: String?
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(text)
            }
            .font(.caption.weight(prominent ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(prominent ? Color.accentColor : .primary)
            .background(prominent ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Lays children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

struct MultiSelectionView: View {
    @Environment(Library.self) private var library
    let shots: [Screenshot]
    let browser: Browser

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                ForEach(Array(shots.prefix(4).enumerated()), id: \.element.id) { index, shot in
                    Thumbnail(path: shot.path, maxPixelSize: 400)
                        .frame(width: 200, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(radius: 4, y: 2)
                        .rotationEffect(.degrees(Double(index) * 4 - 6))
                        .offset(x: CGFloat(index) * 8, y: CGFloat(index) * -6)
                }
            }
            .frame(height: 170)
            Text("\(shots.count) screenshots selected").font(.headline)
            VStack(spacing: 8) {
                Button("New Collection from Selection…") {
                    ShotActions.newCollection(with: Set(shots.map(\.id)), library: library, browser: browser)
                }
                Menu("Add to Collection") {
                    ForEach(library.collections) { collection in
                        Button(collection.name) { library.add(shots.map(\.id), to: collection.id) }
                    }
                }
                .disabled(library.collections.isEmpty)
                .fixedSize()
                Button("Move to Folder…") { ShotActions.move(Set(shots.map(\.id)), library: library) }
                Button("Move to Trash", role: .destructive) {
                    library.moveToTrash(shots.map(\.id))
                    browser.selection = []
                }
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
