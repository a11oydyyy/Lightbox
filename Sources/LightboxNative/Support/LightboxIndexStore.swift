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

/// An image's pixel size, valid while the file still has `signature`'s
/// modification time and size.
struct StoredImageDimensions: Sendable, Equatable {
    var path: String
    var signature: FileContentSignature
    var width: CGFloat
    var height: CGFloat
}

struct IndexedVisibleSnapshot: Sendable {
    var folders: [LibraryFolderEntry]
    var assets: [LightboxAsset]
}

final class LightboxIndexStore {
    private static let logger = Logger(subsystem: "io.github.a11oydyyy.Lightbox", category: "Index")
    private static let dimensionCacheVersion = 2
    private let databaseURL: URL
    private let fileSignatureResolver: @Sendable (URL) -> FileContentSignature?
    private var database: OpaquePointer?

    init(
        databaseURL: URL = LightboxLibraryStore.indexDatabaseURL,
        fileSignatureResolver: @escaping @Sendable (URL) -> FileContentSignature? = { FileContentSignature(url: $0) }
    ) {
        self.databaseURL = databaseURL
        self.fileSignatureResolver = fileSignatureResolver
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

    /// Replaces the cached contents of one folder in a single transaction.
    /// Returns whether the new snapshot was committed: any failed step rolls
    /// the whole replacement back, keeping the previous snapshot.
    @discardableResult
    func replaceVisibleSnapshot(
        source: LibrarySource,
        folderURL: URL,
        folders: [LibraryFolderEntry],
        assets: [LightboxAsset]
    ) -> Bool {
        let startedAt = Date()
        guard !Task.isCancelled else {
            Self.logger.info("index snapshot skipped cancelled-before-start source=\(source.id, privacy: .public) folder=\(folderURL.path, privacy: .public)")
            return false
        }
        guard database != nil else {
            Self.logger.error("index snapshot skipped database unavailable source=\(source.id, privacy: .public) folder=\(folderURL.path, privacy: .public)")
            return false
        }
        func rollBack(_ phase: String) -> Bool {
            exec("ROLLBACK;", context: "snapshot rollback \(phase)")
            Self.logger.error("index snapshot failed source=\(source.id, privacy: .public) phase=\(phase, privacy: .public) folder=\(folderURL.path, privacy: .public)")
            return false
        }
        Self.logger.info("index snapshot begin source=\(source.id, privacy: .public) kind=\(source.kind.rawValue, privacy: .public) folder=\(folderURL.path, privacy: .public) folders=\(folders.count) assets=\(assets.count)")
        guard exec("BEGIN IMMEDIATE TRANSACTION;", context: "snapshot begin") else { return false }
        let deleteStartedAt = Date()
        guard deleteItems(sourceID: source.id, parentPath: folderURL.path) else { return rollBack("delete") }
        let deleteSeconds = Date().timeIntervalSince(deleteStartedAt)

        var folderResourceSeconds: TimeInterval = 0
        for folder in folders {
            guard !Task.isCancelled else {
                exec("ROLLBACK;", context: "snapshot rollback folders")
                Self.logger.info("index snapshot cancelled source=\(source.id, privacy: .public) phase=folders elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                return false
            }
            let resourceStartedAt = Date()
            let mtime = modificationTime(for: folder.url)
            folderResourceSeconds += Date().timeIntervalSince(resourceStartedAt)
            guard insertItem(
                id: folder.id,
                sourceID: source.id,
                path: folder.url.path,
                relativePath: folder.relativePath,
                parentPath: folderURL.path,
                isDirectory: true,
                fileSize: nil,
                mtime: mtime,
                addedAt: nil,
                width: nil,
                height: nil,
                tags: folder.tags
            ) else { return rollBack("folders") }
        }

        var assetResourceSeconds: TimeInterval = 0
        var insertedAssets = 0
        for asset in assets {
            guard !Task.isCancelled else {
                exec("ROLLBACK;", context: "snapshot rollback assets")
                Self.logger.info("index snapshot cancelled source=\(source.id, privacy: .public) phase=assets inserted=\(insertedAssets) elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                return false
            }
            guard let url = asset.sourceURL else { continue }
            let resourceStartedAt = Date()
            let signature = fileSignature(for: url)
            let size = signature?.fileSize
            let mtime = signature.map { Date(timeIntervalSince1970: $0.modificationTime) }
            assetResourceSeconds += Date().timeIntervalSince(resourceStartedAt)
            guard insertItem(
                id: "\(source.id):\(url.standardizedFileURL.path)",
                sourceID: source.id,
                path: url.path,
                relativePath: url.relativePath(from: source.rootURL),
                parentPath: folderURL.path,
                isDirectory: false,
                fileSize: size,
                mtime: mtime,
                addedAt: asset.addedAt,
                width: asset.metadataLoaded ? Double(asset.width) : nil,
                height: asset.metadataLoaded ? Double(asset.height) : nil,
                tags: asset.tags,
                metadataLoaded: asset.metadataLoaded
            ) else { return rollBack("assets") }
            insertedAssets += 1
            if insertedAssets % 100 == 0 {
                Self.logger.info("index snapshot progress source=\(source.id, privacy: .public) assets=\(insertedAssets)/\(assets.count) resource=\(assetResourceSeconds, format: .fixed(precision: 2))s elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
            }
        }

        guard exec("COMMIT;", context: "snapshot commit") else { return rollBack("commit") }
        Self.logger.info("index snapshot complete source=\(source.id, privacy: .public) folders=\(folders.count) assets=\(insertedAssets) delete=\(deleteSeconds, format: .fixed(precision: 2))s folderResource=\(folderResourceSeconds, format: .fixed(precision: 2))s assetResource=\(assetResourceSeconds, format: .fixed(precision: 2))s total=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
        return true
    }

    func cachedDimensions(sourceID: String, parentPath: String) -> [String: CachedAssetDimensions] {
        let startedAt = Date()
        guard !Task.isCancelled else {
            Self.logger.info("index dimensions skipped cancelled-before-start source=\(sourceID, privacy: .public) parent=\(parentPath, privacy: .public)")
            return [:]
        }
        let sql = """
        SELECT path, width, height, mtime, file_size
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

            while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
                guard !Task.isCancelled else { break }
                guard let path = columnText(statement, at: 0) else { continue }
                let width = CGFloat(sqlite3_column_double(statement, 1))
                let height = CGFloat(sqlite3_column_double(statement, 2))
                let indexedSignature = FileContentSignature(
                    modificationTime: nullableDouble(statement, at: 3),
                    fileSize: nullableInt64(statement, at: 4)
                )
                guard width > 0,
                      height > 0,
                      let indexedSignature
                else {
                    continue
                }
                guard !Task.isCancelled else { break }
                let currentSignature = fileSignatureResolver(URL(fileURLWithPath: path))
                guard !Task.isCancelled else { break }
                guard currentSignature?.matchesModificationMetadata(indexedSignature) == true else { continue }
                dimensions[path] = CachedAssetDimensions(width: width, height: height)
            }
        }

        guard !Task.isCancelled else {
            Self.logger.info("index dimensions cancelled source=\(sourceID, privacy: .public) parent=\(parentPath, privacy: .public) completed=\(dimensions.count)")
            return [:]
        }
        Self.logger.info("index dimensions read source=\(sourceID, privacy: .public) parent=\(parentPath, privacy: .public) count=\(dimensions.count) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))")
        return dimensions
    }

    func cachedVisibleSnapshot(source: LibrarySource, folderURL: URL) -> IndexedVisibleSnapshot? {
        let startedAt = Date()
        let folderPath = folderURL.standardizedFileURL.path
        let sql = """
        SELECT path, is_directory, file_size, mtime, added_at, tags
        FROM items
        WHERE source_id = ?
          AND parent_path = ?
        ORDER BY is_directory DESC, relative_path ASC;
        """
        var folders: [LibraryFolderEntry] = []
        var assets: [LightboxAsset] = []

        withStatement(sql) { statement in
            bindText(source.id, to: statement, at: 1)
            bindText(folderPath, to: statement, at: 2)

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement, at: 0) else { continue }
                let url = URL(fileURLWithPath: path)
                let tags = Self.decodedTags(columnText(statement, at: 5) ?? "")
                let isDirectory = sqlite3_column_int(statement, 1) == 1
                if isDirectory {
                    folders.append(LibraryFolderEntry(
                        sourceID: source.id,
                        url: url.standardizedFileURL,
                        rootURL: source.rootURL.standardizedFileURL,
                        tags: tags
                    ))
                    continue
                }

                assets.append(LightboxAsset(
                    originalName: url.lastPathComponent,
                    width: 1,
                    height: 1,
                    tags: tags,
                    sourceURL: url,
                    addedAt: nullableDate(statement, at: 4)
                        ?? nullableDate(statement, at: 3)
                        ?? .distantPast,
                    contentModifiedAt: nullableDate(statement, at: 3),
                    fileSize: nullableInt64(statement, at: 2),
                    palette: MockPalette.imported[assets.count % MockPalette.imported.count],
                    metadataLoaded: false
                ))
            }
        }

        guard !folders.isEmpty || !assets.isEmpty else {
            return nil
        }

        Self.logger.info("index visible snapshot read source=\(source.id, privacy: .public) parent=\(folderPath, privacy: .public) folders=\(folders.count) assets=\(assets.count) seconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))")
        return IndexedVisibleSnapshot(folders: folders, assets: assets)
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
        WHERE id = ?;
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
                // By the row's key (`replaceVisibleSnapshot`'s "source:path"):
                // no index covers `path`, so matching on it scanned the
                // whole source once per image.
                bindText("\(sourceID):\(update.url.standardizedFileURL.path)", to: statement, at: 9)
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

    /// A stored folder summary, valid while the folder's modification time
    /// still equals `modificationTime` (adding, removing or renaming a child
    /// changes it).
    func cachedFolderSummary(path: String) -> (modificationTime: Double, summary: FolderImageSummary)? {
        var result: (Double, FolderImageSummary)?
        withStatement("SELECT mtime, image_count, cover_path FROM folder_summaries WHERE path = ?;") { statement in
            bindText(path, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return }
            let cover = columnText(statement, at: 2).map { URL(fileURLWithPath: $0, isDirectory: false) }
            result = (sqlite3_column_double(statement, 0),
                      FolderImageSummary(imageCount: Int(sqlite3_column_int64(statement, 1)), coverURL: cover))
        }
        return result
    }

    func storeFolderSummary(_ summary: FolderImageSummary, path: String, modificationTime: Double) {
        withStatement("""
        INSERT INTO folder_summaries (path, mtime, image_count, cover_path, indexed_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET mtime = excluded.mtime, image_count = excluded.image_count,
            cover_path = excluded.cover_path, indexed_at = excluded.indexed_at;
        """) { statement in
            bindText(path, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, modificationTime)
            sqlite3_bind_int64(statement, 3, Int64(summary.imageCount))
            if let cover = summary.coverURL { bindText(cover.path, to: statement, at: 4) } else { sqlite3_bind_null(statement, 4) }
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            _ = stepDone(statement, context: "store folder summary")
        }
    }

    /// Image sizes by path, for any folder, scanned or not: the folder
    /// snapshot in `items` holds only folders that were opened, so recursive
    /// results and searches keep theirs here.
    func storeImageDimensions(_ entries: [StoredImageDimensions]) {
        guard !entries.isEmpty, !Task.isCancelled else { return }
        guard exec("BEGIN IMMEDIATE TRANSACTION;", context: "image dimensions begin") else { return }
        for entry in entries {
            withStatement("""
            INSERT INTO image_dimensions (path, mtime, file_size, width, height, version)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET mtime = excluded.mtime, file_size = excluded.file_size,
                width = excluded.width, height = excluded.height, version = excluded.version;
            """) { statement in
                bindText(entry.path, to: statement, at: 1)
                sqlite3_bind_double(statement, 2, entry.signature.modificationTime)
                sqlite3_bind_int64(statement, 3, entry.signature.fileSize)
                sqlite3_bind_double(statement, 4, Double(entry.width))
                sqlite3_bind_double(statement, 5, Double(entry.height))
                sqlite3_bind_int(statement, 6, Int32(Self.dimensionCacheVersion))
                _ = stepDone(statement, context: "store image dimensions")
            }
        }
        exec("COMMIT;", context: "image dimensions commit")
    }

    /// Stored sizes for these paths. Callers check each signature against the
    /// file's current one.
    func storedImageDimensions(paths: [String]) -> [String: StoredImageDimensions] {
        var result: [String: StoredImageDimensions] = [:]
        withStatement("""
        SELECT mtime, file_size, width, height FROM image_dimensions WHERE path = ? AND version = ?;
        """) { statement in
            for path in paths {
                guard !Task.isCancelled else { return }
                sqlite3_reset(statement)
                bindText(path, to: statement, at: 1)
                sqlite3_bind_int(statement, 2, Int32(Self.dimensionCacheVersion))
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let stored = storedDimensions(statement, path: path) else { continue }
                result[path] = stored
            }
        }
        return result
    }

    /// Stored sizes for every image below `folderPath`, at any depth.
    func storedImageDimensions(under folderPath: String) -> [String: StoredImageDimensions] {
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        // "0" follows "/", so the range is exactly the paths starting with the prefix.
        let upperBound = String(prefix.dropLast()) + "0"
        var result: [String: StoredImageDimensions] = [:]
        withStatement("""
        SELECT path, mtime, file_size, width, height FROM image_dimensions
        WHERE path >= ? AND path < ? AND version = ?;
        """) { statement in
            bindText(prefix, to: statement, at: 1)
            bindText(upperBound, to: statement, at: 2)
            sqlite3_bind_int(statement, 3, Int32(Self.dimensionCacheVersion))
            while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
                guard let path = columnText(statement, at: 0) else { continue }
                // Columns shift by one: path comes first here.
                guard let signature = FileContentSignature(
                    modificationTime: nullableDouble(statement, at: 1),
                    fileSize: nullableInt64(statement, at: 2)
                ) else { continue }
                let width = CGFloat(sqlite3_column_double(statement, 3))
                let height = CGFloat(sqlite3_column_double(statement, 4))
                guard width > 0, height > 0 else { continue }
                result[path] = StoredImageDimensions(path: path, signature: signature, width: width, height: height)
            }
        }
        return result
    }

    private func storedDimensions(_ statement: OpaquePointer?, path: String) -> StoredImageDimensions? {
        guard let signature = FileContentSignature(
            modificationTime: nullableDouble(statement, at: 0),
            fileSize: nullableInt64(statement, at: 1)
        ) else { return nil }
        let width = CGFloat(sqlite3_column_double(statement, 2))
        let height = CGFloat(sqlite3_column_double(statement, 3))
        guard width > 0, height > 0 else { return nil }
        return StoredImageDimensions(path: path, signature: signature, width: width, height: height)
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

        // Set the timeout first: switching to WAL needs a lock, and without a
        // timeout a concurrent connection makes it fail at once ("database is locked").
        exec("PRAGMA busy_timeout=3000;", context: "pragma busy_timeout")
        exec("PRAGMA journal_mode=WAL;", context: "pragma journal_mode")
        exec("PRAGMA synchronous=NORMAL;", context: "pragma synchronous")
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
            added_at REAL,
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
        if !table("items", hasColumn: "added_at") {
            exec(
                "ALTER TABLE items ADD COLUMN added_at REAL;",
                context: "schema add added_at"
            )
        }

        exec("""
        CREATE TABLE IF NOT EXISTS folder_summaries (
            path TEXT PRIMARY KEY,
            mtime REAL NOT NULL,
            image_count INTEGER NOT NULL,
            cover_path TEXT,
            indexed_at REAL NOT NULL
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS image_dimensions (
            path TEXT PRIMARY KEY,
            mtime REAL NOT NULL,
            file_size INTEGER NOT NULL,
            width REAL NOT NULL,
            height REAL NOT NULL,
            version INTEGER NOT NULL
        );
        """)

        exec("CREATE INDEX IF NOT EXISTS idx_items_source_parent ON items(source_id, parent_path);")
        exec("CREATE INDEX IF NOT EXISTS idx_items_source_relative ON items(source_id, relative_path);")
    }

    private func deleteItems(sourceID: String, parentPath: String) -> Bool {
        withStatement("DELETE FROM items WHERE source_id = ? AND parent_path = ?;") { statement in
            bindText(sourceID, to: statement, at: 1)
            bindText(parentPath, to: statement, at: 2)
            return stepDone(statement, context: "delete items")
        } ?? false
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
        addedAt: Date?,
        width: Double?,
        height: Double?,
        tags: [String],
        metadataLoaded: Bool = false
    ) -> Bool {
        let sql = """
        INSERT INTO items (
            id, source_id, path, relative_path, parent_path, is_directory,
            mtime, added_at, file_size, width, height, tags, metadata_loaded, dimension_version, indexed_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            relative_path = excluded.relative_path,
            parent_path = excluded.parent_path,
            is_directory = excluded.is_directory,
            mtime = excluded.mtime,
            added_at = excluded.added_at,
            file_size = excluded.file_size,
            width = excluded.width,
            height = excluded.height,
            tags = excluded.tags,
            metadata_loaded = excluded.metadata_loaded,
            dimension_version = excluded.dimension_version,
            indexed_at = excluded.indexed_at;
        """

        return withStatement(sql) { statement in
            bindText(id, to: statement, at: 1)
            bindText(sourceID, to: statement, at: 2)
            bindText(path, to: statement, at: 3)
            bindText(relativePath, to: statement, at: 4)
            bindText(parentPath, to: statement, at: 5)
            sqlite3_bind_int(statement, 6, isDirectory ? 1 : 0)
            bindDate(mtime, to: statement, at: 7)
            bindDate(addedAt, to: statement, at: 8)
            bindInt64(fileSize, to: statement, at: 9)
            bindDouble(width, to: statement, at: 10)
            bindDouble(height, to: statement, at: 11)
            bindText(Self.encodedTags(tags), to: statement, at: 12)
            sqlite3_bind_int(statement, 13, metadataLoaded ? 1 : 0)
            sqlite3_bind_int(statement, 14, metadataLoaded ? Int32(Self.dimensionCacheVersion) : 0)
            sqlite3_bind_double(statement, 15, Date().timeIntervalSince1970)
            return stepDone(statement, context: "insert item")
        } ?? false
    }

    /// Runs `body` with a prepared statement; nil when it could not be
    /// prepared.
    @discardableResult
    private func withStatement<Result>(_ sql: String, body: (OpaquePointer?) -> Result) -> Result? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            logSQLiteError(context: "prepare statement", code: sqlite3_errcode(database))
            return nil
        }

        defer {
            sqlite3_finalize(statement)
        }

        return body(statement)
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

    private func nullableDate(_ statement: OpaquePointer?, at index: Int32) -> Date? {
        nullableDouble(statement, at: index).map(Date.init(timeIntervalSince1970:))
    }

    private func nullableDouble(_ statement: OpaquePointer?, at index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    private func nullableInt64(_ statement: OpaquePointer?, at index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, index)
    }

    private func modificationTime(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func fileSignature(for url: URL) -> FileContentSignature? {
        fileSignatureResolver(url)
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

    private static func decodedTags(_ tags: String) -> [String] {
        tags.split(separator: "\n").map(String.init)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
