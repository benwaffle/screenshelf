import ShelfCore
import SwiftUI

/// Collections and Apple Intelligence suggestions, each shown as a stack of its newest screenshots.
struct CollectionsView: View {
    @Environment(Library.self) private var library
    let browser: Browser

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 24, alignment: .top)]

    var body: some View {
        if library.collections.isEmpty && library.suggestions.isEmpty {
            ContentUnavailableView(
                "No Collections Yet",
                systemImage: "square.stack.3d.up",
                description: Text("Select screenshots and choose Add to Collection. Suggestions appear here as related screenshots pile up."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !library.collections.isEmpty {
                        section("Your Collections") {
                            ForEach(library.collections) { collection in
                                let ids = newestFirst(library.membership[collection.id] ?? [])
                                StackCard(paths: paths(ids), title: collection.name, count: ids.count)
                                    .onTapGesture { browser.sidebar = .collection(collection.id) }
                                    .contextMenu {
                                        Button("Delete Collection", role: .destructive) { library.deleteCollection(collection.id) }
                                    }
                            }
                        }
                    }
                    if !library.suggestions.isEmpty {
                        section("Suggested", symbol: "sparkles") {
                            ForEach(library.suggestions) { suggestion in
                                StackCard(paths: paths(suggestion.ids), title: suggestion.title, count: suggestion.ids.count) {
                                    Button("Keep") {
                                        if let created = library.accept(suggestion) { browser.sidebar = .collection(created.id) }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(suggestion.title == nil)
                                    Button("Dismiss", systemImage: "xmark") { library.dismiss(suggestion) }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                        .help("Dismiss suggestion")
                                }
                                .onTapGesture { browser.sidebar = .suggestion(suggestion.id) }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func section(_ title: String, symbol: String? = nil, @ViewBuilder cards: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.tint) }
                Text(title)
            }
            .font(.title3.weight(.semibold))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28, content: cards)
        }
    }

    private func newestFirst(_ ids: Set<Int64>) -> [Int64] {
        ids.compactMap { library.screenshot($0) }.sorted { $0.createdAt > $1.createdAt }.map(\.id)
    }

    private func paths(_ ids: [Int64]) -> [String] {
        ids.prefix(3).compactMap { library.screenshot($0)?.path }
    }
}

/// Up to three thumbnails fanned out like a pile of prints, with a title underneath.
struct StackCard<Actions: View>: View {
    let paths: [String]
    let title: String?
    let count: Int
    @ViewBuilder var actions: () -> Actions

    // Back cards sit up and to the side of the front card, tilted a little.
    private static var placements: [(angle: Double, x: CGFloat, y: CGFloat, scale: CGFloat)] {
        [(0, 0, 0, 1), (-4, -10, -8, 0.95), (5, 12, -14, 0.9)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                ForEach(Array(paths.enumerated().reversed()), id: \.element) { index, path in
                    let placement = Self.placements[index]
                    Thumbnail(path: path, maxPixelSize: 500)
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .scaleEffect(placement.scale)
                        .rotationEffect(.degrees(placement.angle))
                        .offset(x: placement.x, y: placement.y)
                }
                if paths.isEmpty {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary)
                        .frame(height: 140)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? "Naming…")
                        .font(.headline)
                        .foregroundStyle(title == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Text("\(count) screenshots")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                actions()
            }
        }
        .contentShape(Rectangle())
    }
}

extension StackCard where Actions == EmptyView {
    init(paths: [String], title: String?, count: Int) {
        self.init(paths: paths, title: title, count: count) { EmptyView() }
    }
}

struct AnswerCard: View {
    let answer: Answer
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                if answer.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading your screenshots…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(LocalizedStringKey(answer.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Numbers refer to the badges on the screenshots below. Apple Intelligence can make mistakes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        }
    }
}
