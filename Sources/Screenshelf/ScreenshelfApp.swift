import ShelfCore
import SwiftUI

@main
struct ScreenshelfApp: App {
    @State private var library: Library

    init() {
        do {
            _library = State(initialValue: Library(database: try Database()))
        } catch {
            fatalError("Couldn't open the Screenshelf database: \(error)")
        }
    }

    var body: some Scene {
        Window("Screenshelf", id: "main") {
            ContentView()
                .environment(library)
                .task { library.start() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Folders") { library.rescan() }
                    .keyboardShortcut("r")
            }
            BrowserCommands()
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}

/// Find and thumbnail zoom, routed to the focused window's browser.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") { browser?.searchFocusRequests += 1 }
                .keyboardShortcut("f")
                .disabled(browser == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { browser?.zoom(by: 1.2) }
                .keyboardShortcut("=")
                .disabled(browser == nil)
            Button("Zoom Out") { browser?.zoom(by: 1 / 1.2) }
                .keyboardShortcut("-")
                .disabled(browser == nil)
            Divider()
        }
    }
}

struct BrowserFocusedValueKey: FocusedValueKey {
    typealias Value = Browser
}

extension FocusedValues {
    var browser: Browser? {
        get { self[BrowserFocusedValueKey.self] }
        set { self[BrowserFocusedValueKey.self] = newValue }
    }
}
