import Foundation
import CoreGraphics
import OSLog
import SQLite3

struct CachedAssetDimensions: Sendable {
    var width: CGFloat
    var height: CGFloat
}

struct IndexedAssetDimensions: Sendable {
    var url: URL
    var width: CGFloat
    var height: CGFloat
}

struct IndexedAssetMetadata: Sendable {
    var url: URL
    var width: CGFloat?
    var height: CGFloat?
    var tags: [String]?
}

final class LightboxIndexStore {
    private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Index")
    private static let dimensionCacheVersion = 2
    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL = LightboxLibraryStore.indexDatabaseURL) {
        self.databaseURL = databaseURL
        openDatabase()
        prepareSchema()
    }

    deinit {
        sqlite3_close(database)
    }

    func upsertSource(_ source: LibrarySource) {
        let startedAt = Date()
        let sql = """
        INSERT INTO sources (id, name, kind, root_path, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            kind = excluded.kind,
            root_path = excluded.root_path,
            updated_at = excluded.updated_at;
        """

        withStatement(sql) { statement in
            bindText(source.id, to: statement, at: 1)
            bindText(source.name, to: statement, at: 2)
            bindText(source.kind.rawValue, to: statement, at: 3)
            bindText(source.rootURL.path, to: statement, at: 4)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            stepDone(statement, context: "upsert source")
        }
        Self.logger.info("index source upsert source=\(source.id, privacy: .public) kind=\(source.kind.rawValue, privacy: .public) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))")
    }

    func replaceVisibleSnapshot(
        source: LibrarySource,
        folderURL: URL,
        folders: [LibraryFolderEntry],
        assets: [LightboxAsset]
    ) {
        let startedAt = Date()
        guard !Task.isCancelled else {
            Self.logger.info("index snapshot skipped cancelled-before-start source=\(source.id, privacy: .public) folder=\(folderURL.path, privacy: .public)")
            return
        }
        guard database != nil else {
            Self.logger.error("index snapshot skipped database unavailable source=\(source.id, privacy: .public) folder=\(folderURL.path, privacy: .public)")
            return
        }
        Self.logger.info("index snapshot begin source=\(source.id, privacy: .public) kind=\(source.kind.rawValue, privacy: .public) folder=\(folderURL.path, privacy: .public) folders=\(folders.count) assets=\(assets.count)")
        guard exec("BEGIN IMMEDIATE TRANSACTION;", context: "snapshot begin") else { return }
        let deleteStartedAt = Date()
        deleteItems(sourceID: source.id, parentPath: folderURL.path)
        let deleteSeconds = Date().timeIntervalSince(deleteStartedAt)

        var folderResourceSeconds: TimeInterval = 0
        for folder in folders {
            guard !Task.isCancelled else {
                exec("ROLLBACK;", context: "snapshot rollback folders")
                Self.logger.info("index snapshot cancelled source=\(source.id, privacy: .public) phase=folders elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                return
            }
            let resourceStartedAt = Date()
            let mtime = modificationTime(for: folder.url)
            folderResourceSeconds += Date().timeIntervalSince(resourceStartedAt)
            insertItem(
                id: folder.id,
                sourceID: source.id,
                path: folder.url.path,
                relativePath: folder.relativePath,
                parentPath: folderURL.path,
                isDirectory: true,
                fileSize: nil,
                mtime: mtime,
                width: nil,
                height: nil,
                tags: folder.tags
            )
        }

        var assetResourceSeconds: TimeInterval = 0
        var insertedAssets = 0
        for asset in assets {
            guard !Task.isCancelled else {
                exec("ROLLBACK;", context: "snapshot rollback assets")
                Self.logger.info("index snapshot cancelled source=\(source.id, privacy: .public) phase=assets inserted=\(insertedAssets) elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                return
            }
            guard let url = asset.sourceURL else { continue }
            let resourceStartedAt = Date()
            let size = fileSize(for: url)
            let mtime = modificationTime(for: url)
            assetResourceSeconds += Date().timeIntervalSince(resourceStartedAt)
            insertItem(
                id: "\(source.id):\(url.standardizedFileURL.path)",
                sourceID: source.id,
                path: url.path,
                relativePath: url.relativePath(from: source.rootURL),
                parentPath: folderURL.path,
                isDirectory: false,
                fileSize: size,
                mtime: mtime,
                width: asset.metadataLoaded ? Double(asset.width) : nil,
                height: asset.metadataLoaded ? Double(asset.height) : nil,
                tags: asset.tags,
                metadataLoaded: asset.metadataLoaded
            )
            insertedAssets += 1
            if insertedAssets % 100 == 0 {
                Self.logger.info("index snapshot progress source=\(source.id, privacy: .public) assets=\(insertedAssets)/\(assets.count) resource=\(assetResourceSeconds, format: .fixed(precision: 2))s elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
            }
        }

        exec("COMMIT;", context: "snapshot commit")
        Self.logger.info("index snapshot complete source=\(source.id, privacy: .public) folders=\(folders.count) assets=\(insertedAssets) delete=\(deleteSeconds, format: .fixed(precision: 2))s folderResource=\(folderResourceSeconds, format: .fixed(precision: 2))s assetResource=\(assetResourceSeconds, format: .fixed(precision: 2))s total=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
    }

    func cachedDimensions(sourceID: String, parentPath: String) -> [String: CachedAssetDimensions] {
        let startedAt = Date()
        let sql = """
        SELECT path, width, height
        FROM items
        WHERE source_id = ?
          AND parent_path = ?
          AND is_directory = 0
          AND metadata_loaded = 1
          AND dimension_version = ?
          AND width IS NOT NULL
          AND height IS NOT NULL;
        """
        var dimensions: [String: CachedAssetDimensions] = [:]

        withStatement(sql) { statement in
            bindText(sourceID, to: statement, at: 1)
            bindText(parentPath, to: statement, at: 2)
            sqlite3_bind_int(statement, 3, Int32(Self.dimensionCacheVersion))

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement, at: 0) else { continue }
                let width = CGFloat(sqlite3_column_double(statement, 1))
                let height = CGFloat(sqlite3_column_double(statement, 2))
                guard width > 0, height > 0 else { continue }
                dimensions[path] = CachedAssetDimensions(width: width, height: height)
            }
        }

        Self.logger.info("index dimensions read source=\(sourceID, privacy: .public) parent=\(parentPath, privacy: .public) count=\(dimensions.count) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))")
        return dimensions
    }

    func updateCachedDimensions(sourceID: String, updates: [IndexedAssetDimensions]) {
        updateCachedMetadata(
            sourceID: sourceID,
            updates: updates.map {
                IndexedAssetMetadata(
                    url: $0.url,
                    width: $0.width,
                    height: $0.height,
                    tags: nil
                )
            }
        )
    }

    func updateCachedMetadata(sourceID: String, updates: [IndexedAssetMetadata]) {
        guard !updates.isEmpty else { return }
        let startedAt = Date()
        let sql = """
        UPDATE items
        SET width = COALESCE(?, width),
            height = COALESCE(?, height),
            metadata_loaded = CASE WHEN ? = 1 THEN 1 ELSE metadata_loaded END,
            dimension_version = CASE WHEN ? = 1 THEN ? ELSE dimension_version END,
            tags = CASE WHEN ? = 1 THEN ? ELSE tags END,
            indexed_at = ?
        WHERE source_id = ?
          AND path = ?;
        """
        var updatedCount = 0

        guard exec("BEGIN IMMEDIATE TRANSACTION;", context: "dimensions begin") else { return }
        for update in updates {
            guard !Task.isCancelled else {
                exec("ROLLBACK;", context: "dimensions rollback")
                Self.logger.info("index dimensions cancelled source=\(sourceID, privacy: .public) updated=\(updatedCount)/\(updates.count)")
                return
            }

            withStatement(sql) { statement in
                let hasDimensions = update.width != nil && update.height != nil
                bindDouble(update.width.map(Double.init), to: statement, at: 1)
                bindDouble(update.height.map(Double.init), to: statement, at: 2)
                sqlite3_bind_int(statement, 3, hasDimensions ? 1 : 0)
                sqlite3_bind_int(statement, 4, hasDimensions ? 1 : 0)
                sqlite3_bind_int(statement, 5, Int32(Self.dimensionCacheVersion))
                sqlite3_bind_int(statement, 6, update.tags == nil ? 0 : 1)
                bindText(Self.encodedTags(update.tags ?? []), to: statement, at: 7)
                sqlite3_bind_double(statement, 8, Date().timeIntervalSince1970)
                bindText(sourceID, to: statement, at: 9)
                bindText(update.url.standardizedFileURL.path, to: statement, at: 10)
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE, sqlite3_changes(database) > 0 {
                    updatedCount += 1
                } else if result != SQLITE_DONE {
                    logSQLiteError(context: "update dimensions", code: result)
                }
            }
        }
        exec("COMMIT;", context: "dimensions commit")

        Self.logger.info("index metadata updated source=\(sourceID, privacy: .public) rows=\(updatedCount)/\(updates.count) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))")
    }

    private func openDatabase() {
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            database = nil
            return
        }

        exec("PRAGMA journal_mode=WAL;", context: "pragma journal_mode")
        exec("PRAGMA synchronous=NORMAL;", context: "pragma synchronous")
        exec("PRAGMA busy_timeout=3000;", context: "pragma busy_timeout")
    }

    private func prepareSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            root_path TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            parent_path TEXT NOT NULL,
            is_directory INTEGER NOT NULL,
            mtime REAL,
            file_size INTEGER,
            width REAL,
            height REAL,
            tags TEXT NOT NULL DEFAULT '',
            metadata_loaded INTEGER NOT NULL DEFAULT 0,
            dimension_version INTEGER NOT NULL DEFAULT 0,
            indexed_at REAL NOT NULL
        );
        """)
        if !table("items", hasColumn: "metadata_loaded") {
            exec(
                "ALTER TABLE items ADD COLUMN metadata_loaded INTEGER NOT NULL DEFAULT 0;",
                context: "schema add metadata_loaded"
            )
        }
        if !table("items", hasColumn: "dimension_version") {
            exec(
                "ALTER TABLE items ADD COLUMN dimension_version INTEGER NOT NULL DEFAULT 0;",
                context: "schema add dimension_version"
            )
        }
        if !table("items", hasColumn: "tags") {
            exec(
                "ALTER TABLE items ADD COLUMN tags TEXT NOT NULL DEFAULT '';",
                context: "schema add tags"
            )
        }

        exec("CREATE INDEX IF NOT EXISTS idx_items_source_parent ON items(source_id, parent_path);")
        exec("CREATE INDEX IF NOT EXISTS idx_items_source_relative ON items(source_id, relative_path);")
    }

    private func deleteItems(sourceID: String, parentPath: String) {
        withStatement("DELETE FROM items WHERE source_id = ? AND parent_path = ?;") { statement in
            bindText(sourceID, to: statement, at: 1)
            bindText(parentPath, to: statement, at: 2)
            stepDone(statement, context: "delete items")
        }
    }

    private func insertItem(
        id: String,
        sourceID: String,
        path: String,
        relativePath: String,
        parentPath: String,
        isDirectory: Bool,
        fileSize: Int64?,
        mtime: Date?,
        width: Double?,
        height: Double?,
        tags: [String],
        metadataLoaded: Bool = false
    ) {
        let sql = """
        INSERT INTO items (
            id, source_id, path, relative_path, parent_path, is_directory,
            mtime, file_size, width, height, tags, metadata_loaded, dimension_version, indexed_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            relative_path = excluded.relative_path,
            parent_path = excluded.parent_path,
            is_directory = excluded.is_directory,
            mtime = excluded.mtime,
            file_size = excluded.file_size,
            width = excluded.width,
            height = excluded.height,
            tags = excluded.tags,
            metadata_loaded = excluded.metadata_loaded,
            dimension_version = excluded.dimension_version,
            indexed_at = excluded.indexed_at;
        """

        withStatement(sql) { statement in
            bindText(id, to: statement, at: 1)
            bindText(sourceID, to: statement, at: 2)
            bindText(path, to: statement, at: 3)
            bindText(relativePath, to: statement, at: 4)
            bindText(parentPath, to: statement, at: 5)
            sqlite3_bind_int(statement, 6, isDirectory ? 1 : 0)
            bindDate(mtime, to: statement, at: 7)
            bindInt64(fileSize, to: statement, at: 8)
            bindDouble(width, to: statement, at: 9)
            bindDouble(height, to: statement, at: 10)
            bindText(Self.encodedTags(tags), to: statement, at: 11)
            sqlite3_bind_int(statement, 12, metadataLoaded ? 1 : 0)
            sqlite3_bind_int(statement, 13, metadataLoaded ? Int32(Self.dimensionCacheVersion) : 0)
            sqlite3_bind_double(statement, 14, Date().timeIntervalSince1970)
            stepDone(statement, context: "insert item")
        }
    }

    private func withStatement(_ sql: String, body: (OpaquePointer?) -> Void) {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare statement", code: sqlite3_errcode(database))
            return
        }

        defer {
            sqlite3_finalize(statement)
        }

        body(statement)
    }

    private func table(_ tableName: String, hasColumn columnName: String) -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(tableName));", -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "pragma table_info", code: sqlite3_errcode(database))
            return false
        }
        defer {
            sqlite3_finalize(statement)
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: rawName) == columnName {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func exec(
        _ sql: String,
        context: String = "exec"
    ) -> Bool {
        guard let database else { return false }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result == SQLITE_OK {
            return true
        }

        let message = errorMessage.map { String(cString: $0) } ?? sqliteErrorMessage()
        sqlite3_free(errorMessage)

        logSQLiteError(context: context, code: result, message: message)
        return false
    }

    @discardableResult
    private func stepDone(_ statement: OpaquePointer?, context: String) -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return true
        }

        logSQLiteError(context: context, code: result)
        return false
    }

    private func logSQLiteError(context: String, code: Int32, message: String? = nil) {
        let message = message ?? sqliteErrorMessage()
        Self.logger.error("sqlite \(context, privacy: .public) failed code=\(code) message=\(message, privacy: .public)")
    }

    private func sqliteErrorMessage() -> String {
        guard let database else { return "database unavailable" }
        return String(cString: sqlite3_errmsg(database))
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindDate(_ value: Date?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func bindDouble(_ value: Double?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        sqlite3_bind_double(statement, index, value)
    }

    private func bindInt64(_ value: Int64?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        sqlite3_bind_int64(statement, index, value)
    }

    private func modificationTime(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func fileSize(for url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }

        return Int64(size)
    }

    private func columnText(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: text)
    }

    private static func encodedTags(_ tags: [String]) -> String {
        tags.joined(separator: "\n")
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
