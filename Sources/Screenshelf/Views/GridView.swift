import AppKit
import ShelfCore
import SwiftUI

struct GridView: View {
    @Environment(Library.self) private var library
    @Bindable var browser: Browser
    let items: [Screenshot]
    /// Group by month. Search results are shown ungrouped, in rank order.
    let grouped: Bool
    /// Thumbnail size when the current pinch began.
    @State private var pinchStartSize: Double?

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if let answer = browser.answer {
                            AnswerCard(answer: answer) {
                                browser.answerTask?.cancel()
                                browser.answer = nil
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18, pinnedViews: grouped ? [.sectionHeaders] : []) {
                            if grouped {
                                ForEach(months, id: \.start) { month in
                                    Section {
                                        cells(month.items)
                                    } header: {
                                        MonthHeader(date: month.start, count: month.items.count)
                                    }
                                }
                            } else {
                                cells(items)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { browser.selection = [] }
                    }
                    .onChange(of: browser.anchor) { _, id in
                        if let id { withAnimation(.snappy) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = pinchStartSize ?? browser.thumbnailSize
                    pinchStartSize = start
                    let size = start * value.magnification
                    browser.thumbnailSize = min(max(size, Browser.thumbnailSizes.lowerBound), Browser.thumbnailSizes.upperBound)
                }
                .onEnded { _ in pinchStartSize = nil }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let id = browser.anchor ?? browser.selection.first, let shot = library.screenshot(id) else { return .ignored }
            browser.quickLookURL = browser.quickLookURL == nil ? shot.url : nil
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .upArrow]) { _ in step(-1) }
        .onKeyPress(keys: [.rightArrow, .downArrow]) { _ in step(1) }
        .onKeyPress(keys: [.delete, .deleteForward]) { press in
            guard press.modifiers.contains(.command), !browser.selection.isEmpty else { return .ignored }
            library.moveToTrash(browser.selection)
            browser.selection = []
            return .handled
        }
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            browser.selection = Set(items.map(\.id))
            return .handled
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: browser.thumbnailSize, maximum: browser.thumbnailSize * 1.5), spacing: 16, alignment: .top)]
    }

    private var hitsByID: [Int64: SearchHit] {
        Dictionary(browser.hits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func cells(_ shots: [Screenshot]) -> some View {
        let hits = hitsByID
        let sources = browser.answer?.sources ?? []
        return ForEach(shots) { shot in
            ScreenshotCell(
                shot: shot,
                isSelected: browser.selection.contains(shot.id),
                size: browser.thumbnailSize,
                hit: browser.isSearching ? hits[shot.id] : nil,
                sourceNumber: sources.firstIndex(of: shot.id).map { $0 + 1 }
            )
            .id(shot.id)
            .onTapGesture { click(shot) }
            .draggable(shot.url) {
                Thumbnail(path: shot.path, maxPixelSize: 320)
                    .frame(width: 160, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .contextMenu {
                ShotMenu(ids: browser.selection.contains(shot.id) ? browser.selection : [shot.id], browser: browser)
            }
        }
    }

    private func click(_ shot: Screenshot) {
        let event = NSApp.currentEvent
        if event?.clickCount == 2 {
            NSWorkspace.shared.open(shot.url)
            return
        }
        let modifiers = event?.modifierFlags ?? []
        if modifiers.contains(.command) {
            if browser.selection.contains(shot.id) {
                browser.selection.remove(shot.id)
                if browser.anchor == shot.id { browser.anchor = browser.selection.first }
            } else {
                browser.selection.insert(shot.id)
                browser.anchor = shot.id
            }
        } else if modifiers.contains(.shift), let anchor = browser.anchor,
                  let from = items.firstIndex(where: { $0.id == anchor }),
                  let to = items.firstIndex(where: { $0.id == shot.id }) {
            browser.selection = Set(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            browser.select(shot.id)
        }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let current = browser.anchor.flatMap { id in items.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), items.count - 1) } ?? 0
        browser.select(items[next].id)
        if browser.quickLookURL != nil { browser.quickLookURL = items[next].url }
        return .handled
    }

    private var months: [(start: Date, items: [Screenshot])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: items) { calendar.dateInterval(of: .month, for: $0.createdAt)?.start ?? $0.createdAt }
        return groups.map { (start: $0.key, items: $0.value) }.sorted { $0.start > $1.start }
    }

    @ViewBuilder
    private var emptyState: some View {
        if browser.isSearching {
            ContentUnavailableView.search(text: browser.query)
        } else if library.screenshots.isEmpty {
            ContentUnavailableView(
                "No Screenshots Yet",
                systemImage: "camera.viewfinder",
                description: Text("Press ⇧⌘4 to take one, or add folders in Settings."))
        } else {
            ContentUnavailableView("Nothing Here", systemImage: "tray", description: Text("No screenshots in this view."))
        }
    }
}

private struct MonthHeader: View {
    let date: Date
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(date, format: .dateTime.month(.wide).year())
                .font(.title3.weight(.semibold))
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

struct ScreenshotCell: View {
    let shot: Screenshot
    let isSelected: Bool
    let size: Double
    let hit: SearchHit?
    /// Set when the current answer cites this screenshot.
    var sourceNumber: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Thumbnail(path: shot.path, maxPixelSize: size > 260 ? 900 : 600)
                .frame(height: size * 0.64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 3 : 0.5)
                }
                .overlay(alignment: .topLeading) {
                    if let sourceNumber {
                        Text("\(sourceNumber)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color.accentColor, in: Circle())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if shot.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let hit { MatchBadge(hit: hit).padding(6) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if shot.stage == .discovered {
                        ProgressView().controlSize(.mini).padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(shot.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let category = shot.category {
                        Image(systemName: Category.symbol(for: category))
                    }
                    Text(shot.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        }
        .contentShape(Rectangle())
    }
}

private struct MatchBadge: View {
    let hit: SearchHit

    var body: some View {
        HStack(spacing: 3) {
            if hit.textMatch { Image(systemName: "text.viewfinder") }
            if hit.semanticSimilarity > 0 { Image(systemName: "sparkles") }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .help(hit.textMatch ? "Matches the words on screen" : "Similar in meaning")
    }
}

/// Actions for one or more screenshots, used in context menus and the inspector.
struct ShotMenu: View {
    @Environment(Library.self) private var library
    let ids: Set<Int64>
    let browser: Browser

    var body: some View {
        let shots = ids.compactMap { library.screenshot($0) }
        Button("Open") { shots.forEach { NSWorkspace.shared.open($0.url) } }
        Button("Quick Look") { browser.quickLookURL = shots.first?.url }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(shots.map(\.url)) }
        Divider()
        if shots.count == 1, let shot = shots.first {
            Button("Copy Image") { ShotActions.copyImage(shot) }
            Button("Copy Text") { ShotActions.copyText(shot) }.disabled(shot.ocrText.isEmpty)
            Divider()
        }
        let allFavorite = shots.allSatisfy(\.isFavorite)
        Button(allFavorite ? "Unfavorite" : "Favorite") { library.setFavorite(ids, !allFavorite) }
        Menu("Add to Collection") {
            ForEach(library.collections) { collection in
                Button(collection.name) { library.add(ids, to: collection.id) }
            }
            if !library.collections.isEmpty { Divider() }
            Button("New Collection…") { ShotActions.newCollection(with: ids, library: library, browser: browser) }
        }
        if case .collection(let id) = browser.sidebar {
            Button("Remove from Collection") { library.remove(ids, from: id) }
        }
        Divider()
        Button("Move to Folder…") { ShotActions.move(ids, library: library) }
        Button("Analyze Again") { library.reanalyze(ids) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            library.moveToTrash(ids)
            browser.selection.subtract(ids)
        }
    }
}

enum ShotActions {
    static func copyImage(_ shot: Screenshot) {
        // Screenshots can be PNG, JPEG or HEIC; TIFF is what every app accepts as a pasted image.
        let item = NSPasteboardItem()
        if let data = NSImage(contentsOf: shot.url)?.tiffRepresentation {
            item.setData(data, forType: .tiff)
        }
        item.setString(shot.url.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    static func copyText(_ shot: Screenshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shot.ocrText, forType: .string)
    }

    static func move(_ ids: Set<Int64>, library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose a folder for \(ids.count == 1 ? "this screenshot" : "\(ids.count) screenshots")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        library.move(ids, to: folder)
    }

    static func newCollection(with ids: Set<Int64>, library: Library, browser: Browser) {
        let alert = NSAlert()
        alert.messageText = "New Collection"
        alert.informativeText = "Add \(ids.count == 1 ? "this screenshot" : "\(ids.count) screenshots") to a new collection."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = Enricher.availability == .available ? "Suggesting a name…" : "Collection name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // The main actor keeps running during the modal loop, so the suggestion can arrive while the alert is up.
        let naming = Task {
            let name = await library.suggestedName(for: ids)
            field.placeholderString = "Collection name"
            if let name, field.stringValue.isEmpty {
                field.stringValue = name
                field.currentEditor()?.selectAll(nil)
            }
        }
        defer { naming.cancel() }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if let created = library.createCollection(named: name.isEmpty ? "New Collection" : name, with: ids) {
            browser.sidebar = .collection(created.id)
        }
    }
}
