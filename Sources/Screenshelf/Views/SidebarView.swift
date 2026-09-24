import ShelfCore
import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library
    @Bindable var browser: Browser
    @State private var renaming: Int64?
    @State private var draftName = ""

    var body: some View {
        List(selection: $browser.sidebar) {
            Section("Library") {
                row("All Screenshots", "photo.on.rectangle.angled", library.screenshots.count)
                    .tag(SidebarItem.all)
                row("Favorites", "star", library.screenshots.count(where: \.isFavorite))
                    .tag(SidebarItem.favorites)
                row("Last 7 Days", "clock", recentCount)
                    .tag(SidebarItem.recent)
            }

            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories, id: \.name) { category in
                        row(category.name, Category.symbol(for: category.name), category.count)
                            .tag(SidebarItem.category(category.name))
                    }
                }
            }

            Section("Collections") {
                row("All Collections", "square.stack.3d.up", library.collections.count + library.suggestions.count)
                    .tag(SidebarItem.collections)
                ForEach(library.collections) { collection in
                    collectionRow(collection)
                        .tag(SidebarItem.collection(collection.id))
                }
                if library.collections.isEmpty {
                    Text("Drag screenshots here after creating a collection")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                newCollection()
            } label: {
                Label("New Collection", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private func row(_ title: String, _ symbol: String, _ count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
    }

    @ViewBuilder
    private func collectionRow(_ collection: ShotCollection) -> some View {
        Group {
            if renaming == collection.id {
                TextField("Name", text: $draftName)
                    .onSubmit { commitRename(collection.id) }
                    .onExitCommand { renaming = nil }
            } else {
                row(collection.name, "rectangle.stack", library.membership[collection.id]?.count ?? 0)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let paths = Set(urls.map(\.path))
            let ids = library.screenshots.filter { paths.contains($0.path) }.map(\.id)
            // Dropping one screenshot from a multi-selection adds the whole selection.
            let all = ids.count == 1 && browser.selection.contains(ids[0]) ? Array(browser.selection) : ids
            library.add(all, to: collection.id)
            return !all.isEmpty
        }
        .contextMenu {
            Button("Rename") {
                draftName = collection.name
                renaming = collection.id
            }
            Button("Delete Collection", role: .destructive) {
                if browser.sidebar == .collection(collection.id) { browser.sidebar = .all }
                library.deleteCollection(collection.id)
            }
        }
    }

    private func newCollection() {
        guard let created = library.createCollection(named: "New Collection") else { return }
        draftName = created.name
        renaming = created.id
    }

    private func commitRename(_ id: Int64) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { library.renameCollection(id, to: name) }
        renaming = nil
    }

    private var recentCount: Int {
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 3600)
        return library.screenshots.count { $0.createdAt >= cutoff }
    }

    private var categories: [(name: String, count: Int)] {
        let counts = Dictionary(grouping: library.screenshots.compactMap(\.category), by: { $0 }).mapValues(\.count)
        // Break ties by name: dictionary order changes between renders, which made rows jump around.
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }
}
