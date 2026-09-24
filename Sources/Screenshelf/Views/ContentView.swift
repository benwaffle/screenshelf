import QuickLook
import ShelfCore
import SwiftUI

enum SidebarItem: Hashable {
    case all, favorites, recent
    case category(String)
    /// The overview of all collections and suggestions.
    case collections
    case collection(Int64)
    case suggestion(String)
}

/// An on-device model answer to the current query, grounded in the best-matching screenshots.
struct Answer {
    var query: String
    var text = ""
    /// Cited as [1], [2], … in this order.
    var sources: [Int64] = []
    var isStreaming = true
}

/// UI state for the main window.
@Observable
final class Browser {
    var sidebar: SidebarItem? = .all
    var selection: Set<Int64> = []
    /// The item a shift-click extends the selection from.
    var anchor: Int64?
    var query = ""
    var hits: [SearchHit] = []
    var thumbnailSize: Double = UserDefaults.standard.object(forKey: "thumbnailSize") as? Double ?? 220 {
        didSet { UserDefaults.standard.set(thumbnailSize, forKey: "thumbnailSize") }
    }
    static let thumbnailSizes: ClosedRange<Double> = 120...520
    var quickLookURL: URL?
    /// Incremented by the Find command; the window focuses its search field when this changes.
    var searchFocusRequests = 0
    var answer: Answer?
    @ObservationIgnored var answerTask: Task<Void, Never>?

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedQuery.isEmpty }

    private static let questionWords: Set<String> = [
        "who", "what", "what's", "whats", "when", "where", "why", "how", "which", "did", "does", "do", "is", "are",
        "was", "were", "can", "could", "should", "show", "find",
    ]

    /// Questions get an answer automatically; anything else is answered only when the user presses Return.
    static func looksLikeQuestion(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return query.hasSuffix("?") }
        return query.hasSuffix("?") || questionWords.contains(String(words[0]))
    }

    func select(_ id: Int64) {
        selection = [id]
        anchor = id
    }

    func zoom(by factor: Double) {
        thumbnailSize = min(max(thumbnailSize * factor, Self.thumbnailSizes.lowerBound), Self.thumbnailSizes.upperBound)
    }
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var browser = Browser()
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(browser: browser)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            Group {
                if browser.sidebar == .collections, !browser.isSearching {
                    CollectionsView(browser: browser)
                } else {
                    GridView(browser: browser, items: visibleItems, grouped: !browser.isSearching)
                        .safeAreaInset(edge: .top) { suggestionBanner }
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
        // The inspector shows whenever something is selected; closing it clears the selection.
        .inspector(isPresented: Binding(
            get: { !browser.selection.isEmpty },
            set: { if !$0 { browser.selection = [] } }
        )) {
            InspectorPane(browser: browser)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
        }
        .searchable(text: $browser.query, placement: .toolbar, prompt: "Search or ask about your screenshots")
        .searchFocused($searchFocused)
        .onChange(of: browser.searchFocusRequests) { searchFocused = true }
        .focusedSceneValue(\.browser, browser)
        .onSubmit(of: .search) { ask(browser.trimmedQuery) }
        .task(id: searchKey) {
            let query = browser.trimmedQuery
            if browser.answer?.query != query {
                browser.answerTask?.cancel()
                browser.answer = nil
            }
            guard !query.isEmpty else {
                browser.hits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let isQuestion = Browser.looksLikeQuestion(query)
            browser.hits = isQuestion ? library.searchForQuestion(query) : library.search(query)
            guard isQuestion else { return }
            // Wait for a pause in typing before starting the model.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            ask(query)
        }
        .onChange(of: browser.sidebar) {
            // Keep only selected screenshots that are still visible in the new scope.
            let visible = Set(visibleItems.map(\.id))
            browser.selection.formIntersection(visible)
        }
        .quickLookPreview($browser.quickLookURL, in: visibleItems.map(\.url))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                IndexingStatusView()
            }
        }
    }

    /// Streams an answer to `query` from the screenshots that best match it.
    private func ask(_ query: String) {
        guard !query.isEmpty, Enricher.availability == .available, browser.answer?.query != query else { return }
        browser.answerTask?.cancel()
        let sources = library.searchForQuestion(query).prefix(6).compactMap { library.screenshot($0.id) }
        browser.answer = Answer(query: query, sources: sources.map(\.id))
        guard !sources.isEmpty else {
            browser.answer?.text = "I couldn't find any screenshots about that."
            browser.answer?.isStreaming = false
            return
        }
        browser.answerTask = Task {
            do {
                for try await partial in Enricher.answer(query, sources: sources) {
                    guard !Task.isCancelled else { return }
                    browser.answer?.text = partial
                }
            } catch {
                guard !Task.isCancelled else { return }
                browser.answer?.text = "Couldn't answer: \(error.localizedDescription)"
            }
            browser.answer?.isStreaming = false
        }
    }

    @ViewBuilder
    private var suggestionBanner: some View {
        if case .suggestion(let id) = browser.sidebar, let suggestion = library.suggestions.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Suggested by Apple Intelligence")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") {
                    library.dismiss(suggestion)
                    browser.sidebar = .collections
                }
                Button("Keep as Collection") {
                    if let created = library.accept(suggestion) { browser.sidebar = .collection(created.id) }
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    /// Re-run the search when the query changes or indexing produces new data.
    private var searchKey: String {
        "\(browser.query)|\(library.status.waitingForVision)|\(library.status.waitingForModel)|\(library.screenshots.count)"
    }

    private var scoped: [Screenshot] {
        let all = library.screenshots
        switch browser.sidebar ?? .all {
        case .all, .collections:
            return all
        case .favorites:
            return all.filter(\.isFavorite)
        case .recent:
            let cutoff = Date.now.addingTimeInterval(-7 * 24 * 3600)
            return all.filter { $0.createdAt >= cutoff }
        case .category(let name):
            return all.filter { $0.category == name }
        case .collection(let id):
            let members = library.membership[id] ?? []
            return all.filter { members.contains($0.id) }
        case .suggestion(let id):
            let members = Set(library.suggestions.first { $0.id == id }?.ids ?? [])
            return all.filter { members.contains($0.id) }
        }
    }

    private var visibleItems: [Screenshot] {
        let base = scoped
        guard browser.isSearching else { return base }
        let inScope = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        return browser.hits.compactMap { inScope[$0.id] }
    }

    private var title: String {
        switch browser.sidebar ?? .all {
        case .all: "All Screenshots"
        case .favorites: "Favorites"
        case .recent: "Last 7 Days"
        case .category(let name): name
        case .collections: "Collections"
        case .collection(let id): library.collections.first { $0.id == id }?.name ?? "Collection"
        case .suggestion(let id): library.suggestions.first { $0.id == id }?.title ?? "Suggested Collection"
        }
    }

    private var subtitle: String {
        if browser.sidebar == .collections, !browser.isSearching {
            return "\(library.collections.count) collections · \(library.suggestions.count) suggested"
        }
        let count = visibleItems.count
        let noun = count == 1 ? "screenshot" : "screenshots"
        return browser.isSearching ? "\(count) \(noun) match “\(browser.query)”" : "\(count) \(noun)"
    }
}

struct InspectorPane: View {
    @Environment(Library.self) private var library
    let browser: Browser

    var body: some View {
        let selected = browser.selection.compactMap { library.screenshot($0) }
        if selected.count == 1, let shot = selected.first {
            DetailView(shot: shot, browser: browser)
                .id(shot.id)
        } else if selected.count > 1 {
            MultiSelectionView(shots: selected, browser: browser)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Select a screenshot to see its details, text, and similar shots."))
        }
    }
}

struct IndexingStatusView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let status = library.status
        if !status.isIdle {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.waitingForVision > 0
                         ? "Reading text · \(status.waitingForVision) left"
                         : "Describing with Apple Intelligence · \(status.waitingForModel) left")
                        .font(.caption.weight(.medium))
                    if let current = status.current {
                        Text(current).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            .padding(.horizontal, 6)
        }
    }
}
