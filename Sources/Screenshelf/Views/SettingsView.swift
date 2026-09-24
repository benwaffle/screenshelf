import AppKit
import ShelfCore
import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @State private var selectedFolder: URL?

    var body: some View {
        @Bindable var library = library
        Form {
            Section {
                List(library.folders, id: \.self, selection: $selectedFolder) { folder in
                    Label(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                }
                .frame(minHeight: 90)
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Button("Remove") {
                        library.folders.removeAll { $0 == selectedFolder }
                        selectedFolder = nil
                    }
                    .disabled(selectedFolder == nil || library.folders.count <= 1)
                }
                Toggle("Include every image, not only screenshots", isOn: $library.includeAllImages)
                    .help("Off: only files macOS tagged as screenshots, or named like one")
            } header: {
                Text("Watched Folders")
            } footer: {
                Text("Screenshelf watches these folders and indexes new screenshots as they appear.")
                    .foregroundStyle(.secondary)
            }

            Section("On-Device Intelligence") {
                LabeledContent("Text recognition", value: "Vision")
                LabeledContent("Semantic search", value: library.embedder.isAvailable ? "NaturalLanguage embeddings" : "Unavailable")
                LabeledContent("Titles, summaries and Ask", value: Enricher.availabilityDescription)
                HStack {
                    Button("Analyze All Screenshots Again") {
                        library.reanalyze(library.screenshots.map(\.id))
                    }
                    Button("Show Library in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Database.defaultURL])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        guard panel.runModal() == .OK else { return }
        let new = panel.urls.filter { !library.folders.contains($0) }
        library.folders.append(contentsOf: new)
    }
}
