import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let description: String
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed store for screenshots, their vectors, and user collections.
@MainActor
public final class Database {
    private var handle: OpaquePointer?

    public static var defaultURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Screenshelf", directoryHint: .isDirectory)
        return dir.appending(path: "library.sqlite")
    }

    public init(url: URL = Database.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw DatabaseError(description: "cannot open \(url.path)")
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA foreign_keys = ON")
        try exec("""
            CREATE TABLE IF NOT EXISTS screenshots (
                id INTEGER PRIMARY KEY,
                path TEXT UNIQUE NOT NULL,
                file_number INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                file_size INTEGER NOT NULL DEFAULT 0,
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0,
                ocr_text TEXT NOT NULL DEFAULT '',
                ocr_lines TEXT NOT NULL DEFAULT '[]',
                labels TEXT NOT NULL DEFAULT '[]',
                title TEXT,
                summary TEXT,
                category TEXT,
                tags TEXT NOT NULL DEFAULT '[]',
                notes TEXT NOT NULL DEFAULT '',
                favorite INTEGER NOT NULL DEFAULT 0,
                stage INTEGER NOT NULL DEFAULT 0,
                missing INTEGER NOT NULL DEFAULT 0,
                feature_print BLOB,
                text_vectors BLOB,
                vector_dim INTEGER NOT NULL DEFAULT 0,
                field_vectors INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS collections (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS collection_items (
                collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                screenshot_id INTEGER NOT NULL REFERENCES screenshots(id) ON DELETE CASCADE,
                PRIMARY KEY (collection_id, screenshot_id)
            );
            """)
    }

    // MARK: Screenshots

    public func allScreenshots() throws -> [(Screenshot, ScreenshotVectors)] {
        let sql = """
            SELECT id, path, file_number, created_at, file_size, width, height, ocr_text, ocr_lines, labels,
                   title, summary, category, tags, notes, favorite, stage, missing,
                   feature_print, text_vectors, vector_dim, field_vectors
            FROM screenshots
            """
        return try query(sql) { row in
            let shot = Screenshot(
                id: row.int(0),
                path: row.string(1) ?? "",
                fileNumber: UInt64(bitPattern: row.int(2)),
                createdAt: Date(timeIntervalSince1970: row.double(3)),
                fileSize: row.int(4),
                pixelWidth: Int(row.int(5)),
                pixelHeight: Int(row.int(6)),
                ocrText: row.string(7) ?? "",
                ocrLines: decodeJSON(row.string(8)) ?? [],
                labels: decodeJSON(row.string(9)) ?? [],
                title: row.string(10),
                summary: row.string(11),
                category: row.string(12),
                tags: decodeJSON(row.string(13)) ?? [],
                notes: row.string(14) ?? "",
                isFavorite: row.int(15) != 0,
                stage: AnalysisStage(rawValue: Int(row.int(16))) ?? .discovered,
                isMissing: row.int(17) != 0
            )
            let dim = Int(row.int(20))
            let flat = row.floats(19)
            let text = dim > 0 ? stride(from: 0, to: flat.count, by: dim).map { Array(flat[$0..<min($0 + dim, flat.count)]) } : []
            return (shot, ScreenshotVectors(featurePrint: row.floats(18), text: text, fieldCount: Int(row.int(21))))
        }
    }

    /// Inserts `shot` and returns its new id.
    public func insert(_ shot: Screenshot) throws -> Int64 {
        try run("""
            INSERT INTO screenshots (path, file_number, created_at, file_size) VALUES (?, ?, ?, ?)
            """, [.text(shot.path), .int(Int64(bitPattern: shot.fileNumber)), .double(shot.createdAt.timeIntervalSince1970), .int(shot.fileSize)])
        return sqlite3_last_insert_rowid(handle)
    }

    public func update(_ shot: Screenshot) throws {
        try run("""
            UPDATE screenshots SET path = ?, file_number = ?, created_at = ?, file_size = ?, width = ?, height = ?,
                ocr_text = ?, ocr_lines = ?, labels = ?, title = ?, summary = ?, category = ?, tags = ?, notes = ?,
                favorite = ?, stage = ?, missing = ?
            WHERE id = ?
            """, [
                .text(shot.path), .int(Int64(bitPattern: shot.fileNumber)), .double(shot.createdAt.timeIntervalSince1970),
                .int(shot.fileSize), .int(Int64(shot.pixelWidth)), .int(Int64(shot.pixelHeight)),
                .text(shot.ocrText), .text(encodeJSON(shot.ocrLines)), .text(encodeJSON(shot.labels)),
                shot.title.map(SQLValue.text) ?? .null, shot.summary.map(SQLValue.text) ?? .null,
                shot.category.map(SQLValue.text) ?? .null, .text(encodeJSON(shot.tags)), .text(shot.notes),
                .int(shot.isFavorite ? 1 : 0), .int(Int64(shot.stage.rawValue)), .int(shot.isMissing ? 1 : 0),
                .int(shot.id),
            ])
    }

    public func updateVectors(_ vectors: ScreenshotVectors, for id: Int64) throws {
        let dim = vectors.text.first?.count ?? 0
        try run("UPDATE screenshots SET feature_print = ?, text_vectors = ?, vector_dim = ?, field_vectors = ? WHERE id = ?", [
            .floats(vectors.featurePrint), .floats(vectors.text.flatMap { $0 }), .int(Int64(dim)),
            .int(Int64(vectors.fieldCount)), .int(id),
        ])
    }

    public func delete(id: Int64) throws {
        try run("DELETE FROM screenshots WHERE id = ?", [.int(id)])
    }

    // MARK: Collections

    public func allCollections() throws -> [ShotCollection] {
        try query("SELECT id, name, created_at FROM collections ORDER BY name COLLATE NOCASE") { row in
            ShotCollection(id: row.int(0), name: row.string(1) ?? "", createdAt: Date(timeIntervalSince1970: row.double(2)))
        }
    }

    /// Maps collection id to the screenshot ids it contains.
    public func collectionMembership() throws -> [Int64: Set<Int64>] {
        let pairs = try query("SELECT collection_id, screenshot_id FROM collection_items") { row in (row.int(0), row.int(1)) }
        return Dictionary(grouping: pairs, by: \.0).mapValues { Set($0.map(\.1)) }
    }

    public func createCollection(named name: String) throws -> ShotCollection {
        let now = Date()
        try run("INSERT INTO collections (name, created_at) VALUES (?, ?)", [.text(name), .double(now.timeIntervalSince1970)])
        return ShotCollection(id: sqlite3_last_insert_rowid(handle), name: name, createdAt: now)
    }

    public func renameCollection(id: Int64, to name: String) throws {
        try run("UPDATE collections SET name = ? WHERE id = ?", [.text(name), .int(id)])
    }

    public func deleteCollection(id: Int64) throws {
        try run("DELETE FROM collections WHERE id = ?", [.int(id)])
    }

    public func add(_ screenshotIDs: some Sequence<Int64>, toCollection id: Int64) throws {
        for sid in screenshotIDs {
            try run("INSERT OR IGNORE INTO collection_items (collection_id, screenshot_id) VALUES (?, ?)", [.int(id), .int(sid)])
        }
    }

    public func remove(_ screenshotIDs: some Sequence<Int64>, fromCollection id: Int64) throws {
        for sid in screenshotIDs {
            try run("DELETE FROM collection_items WHERE collection_id = ? AND screenshot_id = ?", [.int(id), .int(sid)])
        }
    }

    // MARK: SQLite plumbing

    private enum SQLValue {
        case null, int(Int64), double(Double), text(String), floats([Float])
    }

    private struct Row {
        let stmt: OpaquePointer

        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func string(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func floats(_ i: Int32) -> [Float] {
            let bytes = Int(sqlite3_column_bytes(stmt, i))
            guard bytes > 0, let blob = sqlite3_column_blob(stmt, i) else { return [] }
            return Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: bytes / MemoryLayout<Float>.size))
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw DatabaseError(description: message)
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError(description: String(cString: sqlite3_errmsg(handle)))
        }
        for (offset, value) in params.enumerated() {
            let i = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, i)
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .floats(let v):
                if v.isEmpty {
                    sqlite3_bind_null(stmt, i)
                } else {
                    v.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
                }
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError(description: String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func query<T>(_ sql: String, _ params: [SQLValue] = [], map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(try map(Row(stmt: stmt)))
        }
        return rows
    }
}

private func encodeJSON(_ value: some Encodable) -> String {
    (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "[]"
}

private func decodeJSON<T: Decodable>(_ string: String?) -> T? {
    guard let data = string?.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
