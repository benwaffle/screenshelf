import Foundation
import Observation

public struct IndexStatus: Sendable, Equatable {
    public var waitingForVision = 0
    public var waitingForModel = 0
    public var current: String?

    public var isIdle: Bool { current == nil }
}

/// The screenshot library: finds screenshots on disk, indexes them in the background, and owns all edits.
@MainActor
@Observable
public final class Library {
    /// Screenshots present on disk, newest first.
    public private(set) var screenshots: [Screenshot] = []
    public private(set) var collections: [ShotCollection] = []
    /// Collection id → screenshot ids.
    public private(set) var membership: [Int64: Set<Int64>] = [:]
    public private(set) var status = IndexStatus()
    /// Groups of related screenshots proposed as collections, newest first.
    public private(set) var suggestions: [CollectionSuggestion] = []
    public private(set) var lastError: String?

    public var folders: [URL] {
        didSet {
            if persistsFolders { UserDefaults.standard.set(folders.map(\.path), forKey: "folders") }
            rescan()
            watchFolders()
        }
    }

    public var includeAllImages: Bool {
        didSet {
            UserDefaults.standard.set(includeAllImages, forKey: "includeAllImages")
            rescan()
        }
    }

    @ObservationIgnored public let embedder = Embedder()
    @ObservationIgnored public private(set) var vectors: [Int64: ScreenshotVectors] = [:]
    @ObservationIgnored private let db: Database
    /// Every row, including files that are currently missing from disk.
    @ObservationIgnored private var rows: [Int64: Screenshot] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var watchers: [FolderWatcher] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private let persistsFolders: Bool
    @ObservationIgnored private var suggesting: Task<Void, Never>?
    /// Model-written names, keyed by suggestion id, so a group is only named once.
    @ObservationIgnored private var suggestionTitles: [String: String] =
        UserDefaults.standard.dictionary(forKey: "suggestionTitles") as? [String: String] ?? [:]
    @ObservationIgnored private var dismissedSuggestions: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "dismissedSuggestions") ?? [])

    /// With `folders`, the library watches those for this session only instead of the saved folders.
    public init(database: Database, folders: [URL]? = nil) {
        db = database
        persistsFolders = folders == nil
        let saved = UserDefaults.standard.stringArray(forKey: "folders") ?? []
        self.folders = folders
            ?? (saved.isEmpty ? [Scanner.systemScreenshotFolder] : saved.map { URL(fileURLWithPath: $0, isDirectory: true) })
        includeAllImages = UserDefaults.standard.object(forKey: "includeAllImages") as? Bool ?? true
    }

    // MARK: Lifecycle

    /// Loads the database, syncs it with disk, starts watching folders, and starts background indexing.
    /// Later calls do nothing.
    public func start() {
        guard !started else { return }
        started = true
        attempt {
            for (shot, vecs) in try db.allScreenshots() {
                rows[shot.id] = shot
                vectors[shot.id] = vecs
            }
            collections = try db.allCollections()
            membership = try db.collectionMembership()
        }
        if UserDefaults.standard.integer(forKey: "embeddingVersion") != Embedder.version {
            reembedAll()
            UserDefaults.standard.set(Embedder.version, forKey: "embeddingVersion")
        }
        rescan()
        watchFolders()
    }

    public func screenshot(_ id: Int64) -> Screenshot? { rows[id] }

    /// Syncs the database with what's on disk and indexes anything new.
    public func rescan() {
        let scan = Scanner.scan(folders: folders, includeAllImages: includeAllImages)
        let files = scan.files
        let unreadable = Set(scan.unreadable.map(\.standardizedFileURL.path))
        let byPath = Dictionary(rows.values.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        let foundPaths = Set(files.map(\.path))
        var vanished = rows.values.filter { shot in
            !foundPaths.contains(shot.path) && !shot.isMissing
                && !unreadable.contains(shot.url.deletingLastPathComponent().standardizedFileURL.path)
        }
        var missingByFileNumber = Dictionary(
            rows.values.filter { $0.isMissing || !foundPaths.contains($0.path) }.map { ($0.fileNumber, $0.id) },
            uniquingKeysWith: { a, _ in a })

        attempt {
            for file in files {
                if let id = byPath[file.path], var shot = rows[id] {
                    let changed = shot.fileSize != file.fileSize
                    guard changed || shot.isMissing else { continue }
                    shot.isMissing = false
                    if changed {
                        shot.fileSize = file.fileSize
                        shot.stage = .discovered
                    }
                    try save(shot)
                } else if file.fileNumber != 0, let id = missingByFileNumber[file.fileNumber], var shot = rows[id] {
                    // Same inode under a new name: the file was renamed or moved between watched folders.
                    missingByFileNumber[file.fileNumber] = nil
                    vanished.removeAll { $0.id == id }
                    shot.path = file.path
                    shot.isMissing = false
                    try save(shot)
                } else {
                    var shot = Screenshot(path: file.path, fileNumber: file.fileNumber, createdAt: file.createdAt, fileSize: file.fileSize)
                    shot.id = try db.insert(shot)
                    rows[shot.id] = shot
                }
            }
            for var shot in vanished {
                shot.isMissing = true
                try save(shot)
            }
        }
        publish()
        startIndexing()
    }

    // MARK: Indexing

    /// Starts the background indexer if it isn't running. Vision runs on every screenshot first so search works
    /// quickly, then the language model enriches them one at a time.
    public func startIndexing() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.indexUntilDone()
            self?.worker = nil
            self?.refreshSuggestions()
        }
    }

    /// Waits for the background indexer to finish everything pending.
    public func waitForIndexing() async {
        await worker?.value
    }

    private func indexUntilDone() async {
        while let (shot, stage) = nextPending(), !Task.isCancelled {
            status.current = shot.displayTitle
            await advance(shot, from: stage)
            refreshStatus()
        }
        status.current = nil
    }

    /// Runs the screenshots through Vision and the language model again.
    public func reanalyze(_ ids: some Sequence<Int64>) {
        attempt {
            for id in ids {
                guard var shot = rows[id] else { continue }
                shot.stage = .discovered
                try save(shot)
            }
        }
        publish()
        startIndexing()
    }

    private var modelIsAvailable: Bool { Enricher.availability == .available }

    private func nextPending() -> (Screenshot, AnalysisStage)? {
        let present = screenshots
        if let shot = present.first(where: { $0.stage == .discovered }) { return (shot, .discovered) }
        if modelIsAvailable, let shot = present.first(where: { $0.stage == .analyzed }) { return (shot, .analyzed) }
        return nil
    }

    private func refreshStatus() {
        status.waitingForVision = screenshots.count { $0.stage == .discovered }
        status.waitingForModel = modelIsAvailable ? screenshots.count { $0.stage == .analyzed } : 0
    }

    private func advance(_ shot: Screenshot, from stage: AnalysisStage) async {
        var shot = shot
        switch stage {
        case .discovered:
            do {
                let result = try await VisionAnalyzer.analyze(shot.url)
                shot.ocrLines = result.lines
                shot.ocrText = result.text
                shot.labels = result.labels
                shot.pixelWidth = result.pixelWidth
                shot.pixelHeight = result.pixelHeight
                vectors[shot.id, default: ScreenshotVectors()].featurePrint = result.featurePrint
            } catch {
                lastError = "Couldn't read \(shot.filename): \(error.localizedDescription)"
            }
            shot.stage = .analyzed
        case .analyzed:
            do {
                let e = try await Enricher.describe(shot)
                shot.title = e.title
                shot.summary = e.summary
                shot.category = e.category
                shot.tags = e.tags
            } catch {
                // Guardrail refusals and similar failures are per-screenshot; keep going with the rest.
                lastError = "Couldn't describe \(shot.filename): \(error.localizedDescription)"
            }
            shot.stage = .enriched
        case .enriched:
            return
        }
        // The user may have edited or trashed the screenshot while it was being analyzed.
        guard let latest = rows[shot.id] else { return }
        shot.notes = latest.notes
        shot.isFavorite = latest.isFavorite
        shot.path = latest.path
        shot.isMissing = latest.isMissing
        setTextVectors(for: shot)
        attempt {
            try save(shot)
            try db.updateVectors(vectors[shot.id]!, for: shot.id)
        }
        publish()
    }

    // MARK: Edits

    /// Saves user edits such as title and notes, and refreshes the vectors that search uses.
    public func update(_ shot: Screenshot) {
        attempt {
            try save(shot)
            if shot.stage > .discovered {
                setTextVectors(for: shot)
                try db.updateVectors(vectors[shot.id]!, for: shot.id)
            }
        }
        publish()
    }

    public func setFavorite(_ ids: some Sequence<Int64>, _ favorite: Bool) {
        attempt {
            for id in ids {
                guard var shot = rows[id] else { continue }
                shot.isFavorite = favorite
                try save(shot)
            }
        }
        publish()
    }

    public func moveToTrash(_ ids: some Sequence<Int64>) {
        attempt {
            for id in ids {
                guard let shot = rows[id] else { continue }
                try FileManager.default.trashItem(at: shot.url, resultingItemURL: nil)
                try db.delete(id: id)
                rows[id] = nil
                vectors[id] = nil
                for key in membership.keys { membership[key]?.remove(id) }
            }
        }
        publish()
    }

    /// Moves files into `folder` on disk. Library metadata follows them if `folder` is watched.
    public func move(_ ids: some Sequence<Int64>, to folder: URL) {
        attempt {
            for id in ids {
                guard var shot = rows[id] else { continue }
                var destination = folder.appending(path: shot.filename)
                var n = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    let base = shot.url.deletingPathExtension().lastPathComponent
                    destination = folder.appending(path: "\(base) \(n).\(shot.url.pathExtension)")
                    n += 1
                }
                try FileManager.default.moveItem(at: shot.url, to: destination)
                shot.path = destination.path
                shot.isMissing = !folders.contains { $0.standardizedFileURL == folder.standardizedFileURL }
                try save(shot)
            }
        }
        publish()
    }

    // MARK: Collections

    @discardableResult
    public func createCollection(named name: String, with ids: some Sequence<Int64> = []) -> ShotCollection? {
        var created: ShotCollection?
        attempt {
            let collection = try db.createCollection(named: name)
            try db.add(ids, toCollection: collection.id)
            collections.append(collection)
            collections.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            membership[collection.id] = Set(ids)
            created = collection
        }
        return created
    }

    public func renameCollection(_ id: Int64, to name: String) {
        attempt {
            try db.renameCollection(id: id, to: name)
            if let i = collections.firstIndex(where: { $0.id == id }) { collections[i].name = name }
        }
    }

    public func deleteCollection(_ id: Int64) {
        attempt {
            try db.deleteCollection(id: id)
            collections.removeAll { $0.id == id }
            membership[id] = nil
        }
    }

    public func add(_ ids: some Sequence<Int64>, to collection: Int64) {
        attempt {
            try db.add(ids, toCollection: collection)
            membership[collection, default: []].formUnion(ids)
        }
    }

    public func remove(_ ids: some Sequence<Int64>, from collection: Int64) {
        attempt {
            try db.remove(ids, fromCollection: collection)
            membership[collection]?.subtract(ids)
        }
    }

    // MARK: Suggested collections

    /// Regroups screenshots into suggestions, then names new groups one at a time with the language model.
    public func refreshSuggestions() {
        suggesting?.cancel()
        suggesting = Task { [weak self] in
            guard let self else { return }
            let items = screenshots.compactMap { shot -> Suggester.Item? in
                guard shot.stage == .enriched, let title = vectors[shot.id]?.fields.first else { return nil }
                return Suggester.Item(id: shot.id, date: shot.createdAt, title: title)
            }
            let groups = await Suggester.groups(items)
            guard !Task.isCancelled else { return }
            let existing = Array(membership.values)
            suggestions = groups
                .map { CollectionSuggestion(id: Suggester.key(for: $0), ids: $0, title: suggestionTitles[Suggester.key(for: $0)]) }
                .filter { suggestion in
                    !dismissedSuggestions.contains(suggestion.id)
                        && !existing.contains { Set(suggestion.ids).isSubset(of: $0) }
                }
            guard modelIsAvailable else { return }
            for index in suggestions.indices where suggestions[index].title == nil {
                let shots = suggestions[index].ids.compactMap { rows[$0] }
                guard let name = try? await Enricher.nameCollection(shots), !Task.isCancelled else { continue }
                suggestionTitles[suggestions[index].id] = name
                UserDefaults.standard.set(suggestionTitles, forKey: "suggestionTitles")
                suggestions[index].title = name
            }
        }
    }

    /// Turns a suggestion into a real collection.
    @discardableResult
    public func accept(_ suggestion: CollectionSuggestion) -> ShotCollection? {
        let created = createCollection(named: suggestion.title ?? "New Collection", with: suggestion.ids)
        suggestions.removeAll { $0.id == suggestion.id }
        return created
    }

    public func dismiss(_ suggestion: CollectionSuggestion) {
        dismissedSuggestions.insert(suggestion.id)
        UserDefaults.standard.set(Array(dismissedSuggestions), forKey: "dismissedSuggestions")
        suggestions.removeAll { $0.id == suggestion.id }
    }

    /// A model-written name for a new collection holding `ids`, or nil if the model isn't available.
    public func suggestedName(for ids: some Sequence<Int64>) async -> String? {
        guard modelIsAvailable else { return nil }
        let shots = ids.compactMap { rows[$0] }
        guard !shots.isEmpty else { return nil }
        return try? await Enricher.nameCollection(shots)
    }

    // MARK: Search

    public func search(_ query: String) -> [SearchHit] {
        SearchEngine.search(query, in: screenshots, vectors: vectors, embedder: embedder)
    }

    /// Search tuned for a natural-language question, used to pick sources for an answer.
    public func searchForQuestion(_ question: String) -> [SearchHit] {
        SearchEngine.search(question, in: screenshots, vectors: vectors, embedder: embedder, mode: .question)
    }

    public func similar(to shot: Screenshot) -> [Screenshot] {
        SearchEngine.similar(to: shot, in: screenshots, vectors: vectors).compactMap { rows[$0] }
    }

    // MARK: Internals

    private func setTextVectors(for shot: Screenshot) {
        let (text, fieldCount) = embedder.vectors(for: shot)
        vectors[shot.id, default: ScreenshotVectors()].text = text
        vectors[shot.id, default: ScreenshotVectors()].fieldCount = fieldCount
    }

    /// Rebuilds text vectors from stored text. Fast: no Vision or language model work.
    private func reembedAll() {
        attempt {
            for shot in rows.values where shot.stage > .discovered {
                setTextVectors(for: shot)
                try db.updateVectors(vectors[shot.id]!, for: shot.id)
            }
        }
    }

    private func save(_ shot: Screenshot) throws {
        try db.update(shot)
        rows[shot.id] = shot
    }

    private func publish() {
        screenshots = rows.values.filter { !$0.isMissing }.sorted { $0.createdAt > $1.createdAt }
        refreshStatus()
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { lastError = String(describing: error) }
    }

    private func watchFolders() {
        watchers = folders.compactMap { folder in
            FolderWatcher(url: folder) { [weak self] in self?.rescan() }
        }
    }
}
