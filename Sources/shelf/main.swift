import Foundation
import ShelfCore

// Command-line access to the Screenshelf library, sharing the app's database.
//
//   shelf index                 scan folders and index everything pending
//   shelf list                  list screenshots with their titles and categories
//   shelf show <id>             print everything known about one screenshot
//   shelf search <query>        hybrid keyword + semantic search
//   shelf ask <question>        answer a question from the best-matching screenshots
//   shelf similar <id>          screenshots that look like, or are about the same thing as, <id>
//   shelf suggest               suggested collections, named by the on-device model
//   shelf watch                 keep running, indexing screenshots as they appear
//
// --folder PATH watches PATH instead of the app's folders (repeatable).

setlinebuf(stdout)

var args = Array(CommandLine.arguments.dropFirst())
var dbURL = Database.defaultURL
if let i = args.firstIndex(of: "--db"), i + 1 < args.count {
    dbURL = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...i + 1)
}
var folders: [URL] = []
while let i = args.firstIndex(of: "--folder"), i + 1 < args.count {
    folders.append(URL(fileURLWithPath: args[i + 1], isDirectory: true))
    args.removeSubrange(i...i + 1)
}
guard let command = args.first else {
    print("usage: shelf [--db PATH] [--folder PATH] index | list | show <id> | search <query> | ask <question> | similar <id> | watch")
    exit(2)
}
let rest = args.dropFirst().joined(separator: " ")

let library = Library(database: try Database(url: dbURL), folders: folders.isEmpty ? nil : folders)
library.start()

func line(_ shot: Screenshot) -> String {
    let category = shot.category.map { " [\($0)]" } ?? ""
    return "#\(shot.id) \(shot.displayTitle)\(category)  — \(shot.filename)"
}

switch command {
case "index":
    print("Indexing \(library.screenshots.count) screenshots in \(library.folders.map(\.path))")
    print("Model: \(Enricher.availabilityDescription)")
    let start = Date()
    await library.waitForIndexing()
    print("Done in \(Int(Date().timeIntervalSince(start)))s")
    if let error = library.lastError { print("Last error: \(error)") }

case "list":
    for shot in library.screenshots { print(line(shot)) }

case "show":
    guard let id = Int64(rest), let shot = library.screenshot(id) else { print("no such id"); exit(1) }
    print(line(shot))
    print("summary: \(shot.summary ?? "-")")
    print("tags: \(shot.tags.joined(separator: ", "))")
    print("labels: \(shot.labels.joined(separator: ", "))")
    print("stage: \(shot.stage)  size: \(shot.pixelWidth)x\(shot.pixelHeight)")
    print("--- text ---\n\(shot.ocrText)")

case "search":
    for hit in library.search(rest).prefix(15) {
        guard let shot = library.screenshot(hit.id) else { continue }
        let why = [hit.textMatch ? "text" : nil, hit.semanticSimilarity > 0 ? String(format: "sem %.2f", hit.semanticSimilarity) : nil]
            .compactMap { $0 }.joined(separator: ", ")
        print("\(line(shot))  (\(why))")
    }

case "ask":
    let sources = library.searchForQuestion(rest).prefix(6).compactMap { library.screenshot($0.id) }
    for (i, shot) in sources.enumerated() { print("[\(i + 1)] \(line(shot))") }
    var answer = ""
    for try await partial in Enricher.answer(rest, sources: Array(sources)) { answer = partial }
    print("\n\(answer)")

case "similar":
    guard let id = Int64(rest), let shot = library.screenshot(id) else { print("no such id"); exit(1) }
    print("Like: \(line(shot))")
    for other in library.similar(to: shot) { print("  \(line(other))") }

case "suggest":
    await library.waitForIndexing()
    library.refreshSuggestions()
    // refreshSuggestions names groups in the background; wait until every group has a name.
    for _ in 0..<120 where library.suggestions.isEmpty || library.suggestions.contains(where: { $0.title == nil }) {
        try await Task.sleep(for: .milliseconds(500))
    }
    for suggestion in library.suggestions {
        print("\(suggestion.title ?? "(unnamed)") — \(suggestion.ids.count) screenshots")
        for id in suggestion.ids { if let shot = library.screenshot(id) { print("    \(line(shot))") } }
    }

case "watch":
    print("Watching \(library.folders.map(\.path))")
    var known = Set(library.screenshots.map(\.id))
    while true {
        try await Task.sleep(for: .seconds(1))
        await library.waitForIndexing()
        let current = library.screenshots
        for shot in current where !known.contains(shot.id) && shot.stage > .discovered {
            print("indexed \(line(shot))")
            known.insert(shot.id)
        }
        known.formIntersection(current.map(\.id))
    }

default:
    print("unknown command \(command)")
    exit(2)
}
