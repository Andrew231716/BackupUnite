import Foundation

struct JWMergeEngine: Sendable {
    fileprivate static let tables = [
        "Location", "UserMark", "Note", "BlockRange", "Bookmark", "Tag", "TagMap",
        "InputField", "IndependentMedia", "PlaylistItemAccuracy", "PlaylistItem",
        "PlaylistItemIndependentMediaMap", "PlaylistItemLocationMap", "PlaylistItemMarker",
        "PlaylistItemMarkerBibleVerseMap", "PlaylistItemMarkerParagraphMap"
    ]

    private static let insertOrder = [
        "Location", "UserMark", "Note", "BlockRange", "Bookmark", "IndependentMedia",
        "PlaylistItemAccuracy", "PlaylistItem", "PlaylistItemIndependentMediaMap",
        "PlaylistItemLocationMap", "PlaylistItemMarker", "PlaylistItemMarkerBibleVerseMap",
        "PlaylistItemMarkerParagraphMap", "Tag", "TagMap", "InputField"
    ]

    func analyze(
        left leftURL: URL,
        right rightURL: URL,
        highlightMode: HighlightMergeMode = .both
    ) throws -> MergeAnalysis {
        let fileManager = FileManager.default
        let leftAccess = leftURL.startAccessingSecurityScopedResource()
        let rightAccess = rightURL.startAccessingSecurityScopedResource()
        defer {
            if leftAccess { leftURL.stopAccessingSecurityScopedResource() }
            if rightAccess { rightURL.stopAccessingSecurityScopedResource() }
        }

        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("backup-unite-analysis-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        let left = try ArchiveSupport.extract(leftURL, to: temporary.appendingPathComponent("left"))
        let right = try ArchiveSupport.extract(rightURL, to: temporary.appendingPathComponent("right"))
        let leftDatabase = try SQLiteDatabase(url: left.databaseURL, readOnly: true)
        let rightDatabase = try SQLiteDatabase(url: right.databaseURL, readOnly: true)
        try Self.inspect(leftDatabase, label: leftURL.lastPathComponent)
        try Self.inspect(rightDatabase, label: rightURL.lastPathComponent)
        let merger = try DatabaseMerger(
            left: leftDatabase,
            right: rightDatabase,
            leftManifest: left.manifest,
            rightManifest: right.manifest,
            resolutions: [:],
            highlightMode: highlightMode
        )
        let result = try merger.run()
        return MergeAnalysis(
            leftName: leftURL.lastPathComponent,
            rightName: rightURL.lastPathComponent,
            conflicts: result.conflicts
        )
    }

    func merge(
        left leftURL: URL,
        right rightURL: URL,
        outputDirectory: URL,
        resolutions: [String: MergeResolution] = [:],
        highlightMode: HighlightMergeMode = .both
    ) throws -> MergeSummary {
        let fileManager = FileManager.default
        let leftAccess = leftURL.startAccessingSecurityScopedResource()
        let rightAccess = rightURL.startAccessingSecurityScopedResource()
        defer {
            if leftAccess { leftURL.stopAccessingSecurityScopedResource() }
            if rightAccess { rightURL.stopAccessingSecurityScopedResource() }
        }

        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("backup-unite-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)

        let left = try ArchiveSupport.extract(leftURL, to: temporary.appendingPathComponent("left"))
        let right = try ArchiveSupport.extract(rightURL, to: temporary.appendingPathComponent("right"))
        let leftDatabase = try SQLiteDatabase(url: left.databaseURL, readOnly: true)
        let rightDatabase = try SQLiteDatabase(url: right.databaseURL, readOnly: true)
        try Self.inspect(leftDatabase, label: leftURL.lastPathComponent)
        try Self.inspect(rightDatabase, label: rightURL.lastPathComponent)

        let merger = try DatabaseMerger(
            left: leftDatabase,
            right: rightDatabase,
            leftManifest: left.manifest,
            rightManifest: right.manifest,
            resolutions: resolutions,
            highlightMode: highlightMode
        )
        let result = try merger.run()

        let mergedRoot = temporary.appendingPathComponent("merged", isDirectory: true)
        try fileManager.createDirectory(at: mergedRoot, withIntermediateDirectories: true)
        let mergedDatabaseURL = mergedRoot.appendingPathComponent(ArchiveSupport.databaseName)
        try Self.rebuildDatabase(base: left.databaseURL, output: mergedDatabaseURL, rows: result.rows)
        try Self.copyAssets(left: left, right: right, pathMaps: result.pathMaps, to: mergedRoot)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let outputName = "UserdataBackup_\(formatter.string(from: Date()))_Merged.jwlibrary"
        try ArchiveSupport.writeManifest(
            basedOn: left.manifest,
            outputName: outputName,
            databaseURL: mergedDatabaseURL,
            to: mergedRoot
        )
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = Self.uniqueOutputURL(in: outputDirectory, preferredName: outputName)
        try ArchiveSupport.createArchive(from: mergedRoot, at: outputURL)
        try Self.validateArchive(outputURL)

        let counts = result.rows.mapValues(\.count)
        let playlistTagIds = Set(result.rows["Tag", default: []].compactMap { row -> Int64? in
            guard row.optionalInt("Type") == 2 else { return nil }
            return row.optionalInt("TagId")
        })
        let playlistCount = result.rows["TagMap", default: []].reduce(into: Set<Int64>()) { set, row in
            if let tag = row.optionalInt("TagId"), playlistTagIds.contains(tag) { set.insert(tag) }
        }.count
        let conflictCounts = Dictionary(grouping: result.conflicts, by: \.kind).mapValues(\.count)
        return MergeSummary(
            outputURL: outputURL,
            notes: counts["Note", default: 0],
            highlights: counts["UserMark", default: 0],
            bookmarks: counts["Bookmark", default: 0],
            tags: counts["Tag", default: 0],
            inputFields: counts["InputField", default: 0],
            playlists: playlistCount,
            playlistItems: counts["PlaylistItem", default: 0],
            media: counts["IndependentMedia", default: 0],
            bookmarkConflicts: conflictCounts[.bookmark, default: 0],
            markingConflicts: conflictCounts[.marking, default: 0],
            noteConflicts: conflictCounts[.note, default: 0],
            inputFieldConflicts: conflictCounts[.inputField, default: 0]
        )
    }

    private static func inspect(_ database: SQLiteDatabase, label: String) throws {
        let version = try database.query("PRAGMA user_version").first?.values.first?.int ?? -1
        guard version == 16 else { throw MergeEngineError.unsupportedSchema(Int(version)) }
        let integrity = try database.query("PRAGMA integrity_check").first?.values.first?.string
        guard integrity == "ok" else {
            throw MergeEngineError.validation("\(label): controllo integrità non superato")
        }
        let foreignKeys = try database.query("PRAGMA foreign_key_check")
        guard foreignKeys.isEmpty else {
            throw MergeEngineError.validation("\(label): \(foreignKeys.count) collegamenti non validi")
        }
        let existing = Set(try database.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.optionalText("name") })
        let missing = Set(tables).subtracting(existing)
        guard missing.isEmpty else {
            throw MergeEngineError.validation("\(label): tabelle mancanti: \(missing.sorted().joined(separator: ", "))")
        }
    }

    private static func rebuildDatabase(
        base: URL,
        output: URL,
        rows: [String: [SQLiteRow]]
    ) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: base, to: output)
        let database = try SQLiteDatabase(url: output, readOnly: false)
        try database.execute("PRAGMA foreign_keys=OFF")
        let triggers = try database.query("SELECT name, sql FROM sqlite_master WHERE type='trigger' AND sql IS NOT NULL")
        do {
            try database.execute("BEGIN IMMEDIATE")
            for trigger in triggers {
                try database.execute("DROP TRIGGER \(SQLiteDatabase.quote(try trigger.text("name")))")
            }
            for table in insertOrder.reversed() {
                try database.execute("DELETE FROM \(SQLiteDatabase.quote(table))")
            }
            for table in insertOrder {
                try database.insert(rows: rows[table, default: []], into: table)
            }
            let now = ISO8601DateFormatter().string(from: Date())
            try database.execute("UPDATE LastModified SET LastModified=?", values: [.text(now)])
            for trigger in triggers {
                try database.execute(try trigger.text("sql"))
            }
            try database.execute("PRAGMA user_version=16")
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        try database.execute("PRAGMA foreign_keys=ON")
        let violations = try database.query("PRAGMA foreign_key_check")
        guard violations.isEmpty else {
            throw MergeEngineError.validation("Il risultato contiene \(violations.count) collegamenti non validi")
        }
        let integrity = try database.query("PRAGMA integrity_check").first?.values.first?.string
        guard integrity == "ok" else {
            throw MergeEngineError.validation("Il database prodotto non supera il controllo di integrità")
        }
        _ = try database.query("PRAGMA journal_mode=DELETE")
    }

    private static func copyAssets(
        left: ExtractedBackup,
        right: ExtractedBackup,
        pathMaps: [MergeSource: [String: String]],
        to output: URL
    ) throws {
        let fileManager = FileManager.default
        for (source, backup) in [(MergeSource.left, left), (.right, right)] {
            for oldName in backup.assetNames {
                let targetName = pathMaps[source]?[oldName] ?? oldName
                let sourceURL = backup.root.appendingPathComponent(oldName)
                let targetURL = output.appendingPathComponent(targetName)
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: targetURL.path) {
                    let current = try Data(contentsOf: targetURL)
                    let incoming = try Data(contentsOf: sourceURL)
                    if current != incoming && source == .right {
                        continue
                    }
                } else {
                    try fileManager.copyItem(at: sourceURL, to: targetURL)
                }
            }
        }
    }

    private static func validateArchive(_ archiveURL: URL) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("backup-unite-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let backup = try ArchiveSupport.extract(archiveURL, to: root)
        guard let userData = backup.manifest["userDataBackup"] as? [String: Any],
              let expected = userData["hash"] as? String
        else { throw MergeEngineError.invalidArchive("hash database mancante") }
        let actual = try ArchiveSupport.sha256Hex(of: backup.databaseURL)
        guard expected == actual else { throw MergeEngineError.validation("Hash database non valido") }

        let database = try SQLiteDatabase(url: backup.databaseURL, readOnly: true)
        try inspect(database, label: "risultato")
        let assets = Set(backup.assetNames)
        let media = try database.allRows(in: "IndependentMedia")
        for row in media {
            let path = try row.text("FilePath")
            guard assets.contains(path) else {
                throw MergeEngineError.validation("File multimediale mancante: \(path)")
            }
            let mediaURL = backup.root.appendingPathComponent(path)
            guard try ArchiveSupport.jwMediaHash(of: mediaURL) == row.optionalText("Hash") else {
                throw MergeEngineError.validation("Hash multimediale non valido: \(path)")
            }
        }
        let mediaPaths = Set(media.compactMap { $0.optionalText("FilePath") })
        for item in try database.allRows(in: "PlaylistItem") {
            if let thumbnail = item.optionalText("ThumbnailFilePath"), !mediaPaths.contains(thumbnail) {
                throw MergeEngineError.validation("Miniatura non collegata: \(thumbnail)")
            }
        }
    }

    private static func uniqueOutputURL(in directory: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let preferred = directory.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let base = preferred.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).jwlibrary")
    }
}

private struct DatabaseMergeResult {
    let rows: [String: [SQLiteRow]]
    let pathMaps: [MergeSource: [String: String]]
    let conflicts: [MergeConflictItem]
}

private final class DatabaseMerger {
    private var data: [MergeSource: [String: [SQLiteRow]]] = [:]
    private var maps: [MergeSource: [String: [Int64: Int64]]] = [:]
    private var pathMaps: [MergeSource: [String: String]] = [.left: [:], .right: [:]]
    private var blockRangesByMark: [MergeSource: [Int64: [SQLiteRow]]] = [:]
    private var merged: [String: [SQLiteRow]] = [:]
    private var winnerByMark: [Int64: MergeSource] = [:]
    private let preferred: MergeSource
    private let resolutions: [String: MergeResolution]
    private let highlightMode: HighlightMergeMode
    private var conflicts: [MergeConflictItem] = []

    init(
        left: SQLiteDatabase,
        right: SQLiteDatabase,
        leftManifest: [String: Any],
        rightManifest: [String: Any],
        resolutions: [String: MergeResolution],
        highlightMode: HighlightMergeMode
    ) throws {
        for source in MergeSource.allCases {
            let database = source == .left ? left : right
            var sourceRows: [String: [SQLiteRow]] = [:]
            for table in JWMergeEngine.tables { sourceRows[table] = try database.allRows(in: table) }
            data[source] = sourceRows
            var groupedRanges: [Int64: [SQLiteRow]] = [:]
            for row in sourceRows["BlockRange", default: []] {
                if let markID = row.optionalInt("UserMarkId") {
                    groupedRanges[markID, default: []].append(row)
                }
            }
            blockRangesByMark[source] = groupedRanges
            maps[source] = [:]
        }
        let leftDate = Self.manifestDate(leftManifest)
        let rightDate = Self.manifestDate(rightManifest)
        preferred = leftDate >= rightDate ? .left : .right
        self.resolutions = resolutions
        self.highlightMode = highlightMode
        for table in JWMergeEngine.tables { merged[table] = [] }
    }

    func run() throws -> DatabaseMergeResult {
        try mergeLocations()
        try mergeUserMarks()
        try mergeNotes()
        try mergeBlockRanges()
        try mergeBookmarks()
        try mergeAccuracy()
        try mergeMedia()
        try mergePlaylistItems()
        try mergeMarkers()
        try mergeSimpleMap(
            table: "PlaylistItemIndependentMediaMap",
            foreignKeys: ["PlaylistItemId": "PlaylistItem", "IndependentMediaId": "IndependentMedia"],
            keyColumns: ["PlaylistItemId", "IndependentMediaId"]
        )
        try mergeSimpleMap(
            table: "PlaylistItemLocationMap",
            foreignKeys: ["PlaylistItemId": "PlaylistItem", "LocationId": "Location"],
            keyColumns: ["PlaylistItemId", "LocationId"]
        )
        try mergeSimpleMap(
            table: "PlaylistItemMarkerBibleVerseMap",
            foreignKeys: ["PlaylistItemMarkerId": "PlaylistItemMarker"],
            keyColumns: ["PlaylistItemMarkerId", "VerseId"]
        )
        try mergeSimpleMap(
            table: "PlaylistItemMarkerParagraphMap",
            foreignKeys: ["PlaylistItemMarkerId": "PlaylistItemMarker"],
            keyColumns: ["PlaylistItemMarkerId", "MepsDocumentId", "ParagraphIndex", "MarkerIndexWithinParagraph"]
        )
        try mergeTags()
        try mergeTagMaps()
        try mergeInputFields()
        return DatabaseMergeResult(
            rows: merged,
            pathMaps: pathMaps,
            conflicts: conflicts
        )
    }

    private static func manifestDate(_ manifest: [String: Any]) -> Date {
        guard let userData = manifest["userDataBackup"] as? [String: Any],
              let value = userData["lastModifiedDate"] as? String
        else { return .distantPast }
        return ExtractedBackup.parseDate(value)
    }

    private func rows(_ source: MergeSource, _ table: String) -> [SQLiteRow] {
        data[source]?[table] ?? []
    }

    private func map(_ source: MergeSource, _ table: String, _ oldID: Int64) throws -> Int64 {
        guard let value = maps[source]?[table]?[oldID] else {
            throw MergeEngineError.missingMapping("\(source.rawValue) \(table) ID \(oldID)")
        }
        return value
    }

    private func setMap(_ source: MergeSource, _ table: String, _ oldID: Int64, _ newID: Int64) {
        maps[source, default: [:]][table, default: [:]][oldID] = newID
    }

    private func nullableMap(_ source: MergeSource, _ table: String, _ value: Int64?) throws -> SQLiteValue {
        guard let value else { return .null }
        return .integer(try map(source, table, value))
    }

    private func append(_ row: SQLiteRow, to table: String) {
        merged[table, default: []].append(row)
    }

    private func chosenSource(for conflict: MergeConflictItem) -> MergeSource {
        resolutions[conflict.id]?.source ?? conflict.recommended
    }

    private func locationDescription(_ source: MergeSource, id: Int64?) -> String {
        guard let id, let location = rows(source, "Location").first(where: { $0.optionalInt("LocationId") == id }) else {
            return "Posizione non specificata"
        }
        var components: [String] = []
        if let title = location.optionalText("Title"), !title.isEmpty { components.append(title) }
        if let key = location.optionalText("KeySymbol"), !key.isEmpty { components.append(key) }
        if let book = location.optionalInt("BookNumber") {
            if let chapter = location.optionalInt("ChapterNumber") {
                components.append("Libro \(book), capitolo \(chapter)")
            } else {
                components.append("Libro \(book)")
            }
        }
        if let document = location.optionalInt("DocumentId") { components.append("Documento \(document)") }
        if let track = location.optionalInt("Track") { components.append("Traccia \(track)") }
        return components.isEmpty ? "Posizione ID \(id)" : components.joined(separator: " · ")
    }

    private static func valueText(_ value: SQLiteValue?) -> String {
        switch value {
        case let .text(text): text
        case let .integer(number): String(number)
        case let .real(number): String(number)
        case let .blob(data): "\(data.count) byte"
        case .null, .none: "—"
        }
    }

    private func blockRangeDescriptions(_ source: MergeSource, markID: Int64) -> [String] {
        (blockRangesByMark[source]?[markID] ?? [])
            .sorted { ($0.optionalInt("BlockRangeId") ?? 0) < ($1.optionalInt("BlockRangeId") ?? 0) }
            .map { row in
                let type = row.optionalInt("BlockType") ?? 0
                let identifier = row.optionalInt("Identifier") ?? 0
                let start = Self.valueText(row["StartToken"])
                let end = Self.valueText(row["EndToken"])
                return "Blocco \(type), ID \(identifier), token \(start)–\(end)"
            }
    }

    private func markSignature(_ source: MergeSource, _ row: SQLiteRow) throws -> String {
        let mappedLocation = try map(source, "Location", try row.int("LocationId"))
        let ranges = blockRangeDescriptions(source, markID: try row.int("UserMarkId")).sorted()
        return [
            String(mappedLocation), Self.valueText(row["ColorIndex"]), Self.valueText(row["StyleIndex"]),
            Self.valueText(row["Version"]), ranges.joined(separator: "|")
        ].joined(separator: "#")
    }

    private func mergeLocations() throws {
        var indexes: [String: Int64] = [:]
        var rowIndexByID: [Int64: Int] = [:]
        var nextID: Int64 = 1
        for source in MergeSource.allCases {
            for original in rows(source, "Location") {
                let keys = Self.locationKeys(original)
                if let existing = keys.compactMap({ indexes[$0] }).first {
                    setMap(source, "Location", try original.int("LocationId"), existing)
                    if let index = rowIndexByID[existing],
                       merged["Location"]?[index].optionalText("Title") == nil,
                       let title = original.optionalText("Title") {
                        merged["Location"]?[index]["Title"] = .text(title)
                    }
                    continue
                }
                var record = original
                record["LocationId"] = .integer(nextID)
                rowIndexByID[nextID] = merged["Location", default: []].count
                append(record, to: "Location")
                setMap(source, "Location", try original.int("LocationId"), nextID)
                for key in keys { indexes[key] = nextID }
                nextID += 1
            }
        }
    }

    private static func locationKeys(_ row: SQLiteRow) -> [String] {
        func key(_ prefix: String, _ fields: [String], requireAll: Bool) -> String? {
            let values = fields.map { row[$0] ?? .null }
            if requireAll && values.contains(.null) { return nil }
            return prefix + "|" + values.map(\.stable).joined(separator: "|")
        }
        let book = key("book", ["BookNumber", "ChapterNumber", "KeySymbol", "MepsLanguage", "Type"], requireAll: true)
        var mediaFields = ["KeySymbol", "IssueTagNumber", "MepsLanguage", "DocumentId", "Track", "Type"]
            .map { row[$0] ?? .null }
        if !mediaFields.contains(.null) {
            mediaFields += [row["Specialty"] ?? .text(""), row["Edition"] ?? .text("")]
        }
        let media = mediaFields.prefix(6).contains(.null) ? nil : "media|" + mediaFields.map(\.stable).joined(separator: "|")
        let full = key("full", ["BookNumber", "ChapterNumber", "DocumentId", "Track", "IssueTagNumber", "KeySymbol", "MepsLanguage", "Type", "Specialty", "Edition"], requireAll: false)
        return [book, media, full].compactMap { $0 }
    }

    private func mergeUserMarks() throws {
        var byGuid: [String: (id: Int64, index: Int, original: SQLiteRow)] = [:]
        var nextID: Int64 = 1
        for source in highlightMode.sources {
            for original in rows(source, "UserMark") {
                let guid = try original.text("UserMarkGuid")
                if source == .right, let match = byGuid[guid] {
                    setMap(source, "UserMark", try original.int("UserMarkId"), match.id)
                    guard try markSignature(.left, match.original) != markSignature(.right, original) else { continue }

                    let leftVersion = match.original.optionalInt("Version") ?? 0
                    let rightVersion = original.optionalInt("Version") ?? 0
                    let recommended: MergeSource = rightVersion > leftVersion
                        ? .right
                        : (leftVersion > rightVersion ? .left : preferred)
                    let conflict = MergeConflictItem(
                        id: "marking:\(guid)",
                        kind: .marking,
                        context: locationDescription(.left, id: match.original.optionalInt("LocationId")),
                        left: MergeConflictVersion(
                            title: "Colore \(match.original.optionalInt("ColorIndex") ?? 0)",
                            preview: blockRangeDescriptions(.left, markID: try match.original.int("UserMarkId")).joined(separator: "\n"),
                            details: [
                                "Versione: \(leftVersion)",
                                "Stile: \(match.original.optionalInt("StyleIndex") ?? 0)"
                            ]
                        ),
                        right: MergeConflictVersion(
                            title: "Colore \(original.optionalInt("ColorIndex") ?? 0)",
                            preview: blockRangeDescriptions(.right, markID: try original.int("UserMarkId")).joined(separator: "\n"),
                            details: [
                                "Versione: \(rightVersion)",
                                "Stile: \(original.optionalInt("StyleIndex") ?? 0)"
                            ]
                        ),
                        recommended: recommended
                    )
                    conflicts.append(conflict)
                    let choice = chosenSource(for: conflict)
                    winnerByMark[match.id] = choice
                    if choice == .right {
                        var replacement = original
                        replacement["UserMarkId"] = .integer(match.id)
                        replacement["LocationId"] = .integer(try map(source, "Location", try original.int("LocationId")))
                        merged["UserMark"]?[match.index] = replacement
                    }
                    continue
                }
                var record = original
                record["UserMarkId"] = .integer(nextID)
                record["LocationId"] = .integer(try map(source, "Location", try original.int("LocationId")))
                let index = merged["UserMark", default: []].count
                append(record, to: "UserMark")
                setMap(source, "UserMark", try original.int("UserMarkId"), nextID)
                winnerByMark[nextID] = source
                byGuid[guid] = (nextID, index, original)
                nextID += 1
            }
        }
    }

    private func remapNote(_ source: MergeSource, _ original: SQLiteRow, id: Int64) throws -> SQLiteRow {
        var record = original
        record["NoteId"] = .integer(id)
        record["LocationId"] = try nullableMap(source, "Location", original.optionalInt("LocationId"))
        if let oldMarkID = original.optionalInt("UserMarkId"),
           let newMarkID = maps[source]?["UserMark"]?[oldMarkID] {
            record["UserMarkId"] = .integer(newMarkID)
        } else {
            // Una nota resta valida anche quando l'utente ha escluso le sottolineature
            // del backup da cui proviene.
            record["UserMarkId"] = .null
        }
        return record
    }

    private func mergeNotes() throws {
        var byGuid: [String: (id: Int64, index: Int, original: SQLiteRow)] = [:]
        var nextID: Int64 = 1
        for source in MergeSource.allCases {
            for original in rows(source, "Note") {
                let guid = try original.text("Guid")
                if source == .right, let match = byGuid[guid] {
                    setMap(source, "Note", try original.int("NoteId"), match.id)
                    let leftDate = ExtractedBackup.parseDate(match.original.optionalText("LastModified") ?? "")
                    let rightDate = ExtractedBackup.parseDate(original.optionalText("LastModified") ?? "")
                    let differs = match.original["Title"] != original["Title"]
                        || match.original["Content"] != original["Content"]
                    if differs {
                        let conflict = MergeConflictItem(
                            id: "note:\(guid)",
                            kind: .note,
                            context: locationDescription(.left, id: match.original.optionalInt("LocationId")),
                            left: MergeConflictVersion(
                                title: match.original.optionalText("Title") ?? "Nota senza titolo",
                                preview: match.original.optionalText("Content") ?? "",
                                details: ["Modificata: \(match.original.optionalText("LastModified") ?? "—")"]
                            ),
                            right: MergeConflictVersion(
                                title: original.optionalText("Title") ?? "Nota senza titolo",
                                preview: original.optionalText("Content") ?? "",
                                details: ["Modificata: \(original.optionalText("LastModified") ?? "—")"]
                            ),
                            recommended: rightDate > leftDate ? .right : .left
                        )
                        conflicts.append(conflict)
                        let resolution = resolutions[conflict.id] ?? MergeResolution(conflict.recommended)
                        if resolution == .right {
                            merged["Note"]?[match.index] = try remapNote(source, original, id: match.id)
                        } else if resolution == .both {
                            var duplicate = try remapNote(source, original, id: nextID)
                            duplicate["Guid"] = .text(UUID().uuidString.lowercased())
                            append(duplicate, to: "Note")
                            setMap(source, "Note", try original.int("NoteId"), nextID)
                            nextID += 1
                        }
                        continue
                    }
                    let created = Self.earlierDateString(match.original.optionalText("Created"), original.optionalText("Created"))
                    let modified = Self.laterDateString(match.original.optionalText("LastModified"), original.optionalText("LastModified"))
                    if let created { merged["Note"]?[match.index]["Created"] = .text(created) }
                    if let modified { merged["Note"]?[match.index]["LastModified"] = .text(modified) }
                    continue
                }
                let record = try remapNote(source, original, id: nextID)
                let index = merged["Note", default: []].count
                append(record, to: "Note")
                setMap(source, "Note", try original.int("NoteId"), nextID)
                byGuid[guid] = (nextID, index, original)
                nextID += 1
            }
        }
    }

    private static func earlierDateString(_ a: String?, _ b: String?) -> String? {
        [a, b].compactMap { $0 }.min { ExtractedBackup.parseDate($0) < ExtractedBackup.parseDate($1) }
    }

    private static func laterDateString(_ a: String?, _ b: String?) -> String? {
        [a, b].compactMap { $0 }.max { ExtractedBackup.parseDate($0) < ExtractedBackup.parseDate($1) }
    }

    private func mergeBlockRanges() throws {
        var nextID: Int64 = 1
        for source in highlightMode.sources {
            for original in rows(source, "BlockRange") {
                let parent = try map(source, "UserMark", try original.int("UserMarkId"))
                guard winnerByMark[parent] == source else { continue }
                var record = original
                record["BlockRangeId"] = .integer(nextID)
                record["UserMarkId"] = .integer(parent)
                append(record, to: "BlockRange")
                setMap(source, "BlockRange", try original.int("BlockRangeId"), nextID)
                nextID += 1
            }
        }
    }

    private func mergeBookmarks() throws {
        var occupied: [String: (id: Int64, index: Int, source: MergeSource, original: SQLiteRow)] = [:]
        var nextID: Int64 = 1
        for source in MergeSource.allCases {
            for original in rows(source, "Bookmark") {
                let location = try map(source, "Location", try original.int("LocationId"))
                let publication = try map(source, "Location", try original.int("PublicationLocationId"))
                let slot = try original.int("Slot")
                let key = "\(publication)|\(slot)"
                if let existing = occupied[key] {
                    setMap(source, "Bookmark", try original.int("BookmarkId"), existing.id)
                    let current = merged["Bookmark"]?[existing.index] ?? [:]
                    let identical = current.optionalInt("LocationId") == location
                        && current["Title"] == original["Title"]
                        && current["Snippet"] == original["Snippet"]
                        && current["BlockType"] == original["BlockType"]
                        && current["BlockIdentifier"] == original["BlockIdentifier"]
                    guard !identical else { continue }
                    let conflict = MergeConflictItem(
                        id: "bookmark:\(publication):\(slot)",
                        kind: .bookmark,
                        context: "\(locationDescription(existing.source, id: existing.original.optionalInt("PublicationLocationId"))) · Slot \(slot)",
                        left: MergeConflictVersion(
                            title: existing.original.optionalText("Title") ?? "Segnalibro senza titolo",
                            preview: existing.original.optionalText("Snippet") ?? "",
                            details: [
                                locationDescription(existing.source, id: existing.original.optionalInt("LocationId")),
                                "Blocco: \(Self.valueText(existing.original["BlockIdentifier"]))"
                            ]
                        ),
                        right: MergeConflictVersion(
                            title: original.optionalText("Title") ?? "Segnalibro senza titolo",
                            preview: original.optionalText("Snippet") ?? "",
                            details: [
                                locationDescription(source, id: original.optionalInt("LocationId")),
                                "Blocco: \(Self.valueText(original["BlockIdentifier"]))"
                            ]
                        ),
                        recommended: preferred
                    )
                    conflicts.append(conflict)
                    if chosenSource(for: conflict) == source {
                        var replacement = original
                        replacement["BookmarkId"] = .integer(existing.id)
                        replacement["LocationId"] = .integer(location)
                        replacement["PublicationLocationId"] = .integer(publication)
                        merged["Bookmark"]?[existing.index] = replacement
                    }
                    continue
                }
                var record = original
                record["BookmarkId"] = .integer(nextID)
                record["LocationId"] = .integer(location)
                record["PublicationLocationId"] = .integer(publication)
                let index = merged["Bookmark", default: []].count
                append(record, to: "Bookmark")
                setMap(source, "Bookmark", try original.int("BookmarkId"), nextID)
                occupied[key] = (nextID, index, source, original)
                nextID += 1
            }
        }
    }

    private func mergeAccuracy() throws {
        var descriptions: [String: Int64] = [:]
        var nextID: Int64 = 1
        for source in MergeSource.allCases {
            for original in rows(source, "PlaylistItemAccuracy") {
                let description = try original.text("Description")
                if let existing = descriptions[description] {
                    setMap(source, "PlaylistItemAccuracy", try original.int("PlaylistItemAccuracyId"), existing)
                    continue
                }
                var record = original
                record["PlaylistItemAccuracyId"] = .integer(nextID)
                append(record, to: "PlaylistItemAccuracy")
                setMap(source, "PlaylistItemAccuracy", try original.int("PlaylistItemAccuracyId"), nextID)
                descriptions[description] = nextID
                nextID += 1
            }
        }
    }

    private func mergeMedia() throws {
        var byHash: [String: (id: Int64, path: String)] = [:]
        var usedPaths: [String: String] = [:]
        var nextID: Int64 = 1
        for source in MergeSource.allCases {
            for original in rows(source, "IndependentMedia") {
                let hash = try original.text("Hash")
                let oldPath = try original.text("FilePath")
                if source == .right, let existing = byHash[hash] {
                    setMap(source, "IndependentMedia", try original.int("IndependentMediaId"), existing.id)
                    pathMaps[source, default: [:]][oldPath] = existing.path
                    continue
                }
                var targetPath = oldPath
                if let previousHash = usedPaths[targetPath], previousHash != hash {
                    let path = oldPath as NSString
                    let extensionPart = path.pathExtension.isEmpty ? "" : ".\(path.pathExtension)"
                    let stem = path.deletingPathExtension
                    targetPath = "\(stem)-merged-\(source.rawValue)-\(try original.int("IndependentMediaId"))\(extensionPart)"
                    while usedPaths[targetPath] != nil {
                        targetPath = "\(stem)-merged-\(UUID().uuidString.prefix(8))\(extensionPart)"
                    }
                }
                var record = original
                record["IndependentMediaId"] = .integer(nextID)
                record["FilePath"] = .text(targetPath)
                append(record, to: "IndependentMedia")
                setMap(source, "IndependentMedia", try original.int("IndependentMediaId"), nextID)
                pathMaps[source, default: [:]][oldPath] = targetPath
                usedPaths[targetPath] = hash
                if byHash[hash] == nil { byHash[hash] = (nextID, targetPath) }
                nextID += 1
            }
        }
    }

    private func playlistMemberships(_ source: MergeSource) -> [Int64: [String]] {
        let tags = Dictionary(uniqueKeysWithValues: rows(source, "Tag").compactMap { row -> (Int64, SQLiteRow)? in
            guard let id = row.optionalInt("TagId") else { return nil }
            return (id, row)
        })
        var result: [Int64: [String]] = [:]
        for mapping in rows(source, "TagMap") {
            guard let item = mapping.optionalInt("PlaylistItemId"),
                  let tagID = mapping.optionalInt("TagId"),
                  tags[tagID]?.optionalInt("Type") == 2,
                  let name = tags[tagID]?.optionalText("Name")
            else { continue }
            result[item, default: []].append(name)
        }
        return result
    }

    private func playlistFingerprint(_ source: MergeSource, _ item: SQLiteRow) throws -> String {
        let itemID = try item.int("PlaylistItemId")
        let memberships = playlistMemberships(source)[itemID, default: []].sorted()
        let mediaByID = Dictionary(uniqueKeysWithValues: rows(source, "IndependentMedia").compactMap { row -> (Int64, SQLiteRow)? in
            guard let id = row.optionalInt("IndependentMediaId") else { return nil }
            return (id, row)
        })
        let hashByPath = Dictionary(uniqueKeysWithValues: rows(source, "IndependentMedia").compactMap { row -> (String, String)? in
            guard let path = row.optionalText("FilePath"), let hash = row.optionalText("Hash") else { return nil }
            return (path, hash)
        })
        var locations: [String] = []
        for mapping in rows(source, "PlaylistItemLocationMap") where mapping.optionalInt("PlaylistItemId") == itemID {
            let mappedLocation = try map(source, "Location", try mapping.int("LocationId"))
            locations.append("\(mappedLocation)|\(mapping["MajorMultimediaType"]?.stable ?? "n:")|\(mapping["BaseDurationTicks"]?.stable ?? "n:")")
        }
        var media: [String] = []
        for mapping in rows(source, "PlaylistItemIndependentMediaMap") where mapping.optionalInt("PlaylistItemId") == itemID {
            guard let oldMediaID = mapping.optionalInt("IndependentMediaId"), let medium = mediaByID[oldMediaID] else { continue }
            media.append("\(medium["Hash"]?.stable ?? "n:")|\(mapping["DurationTicks"]?.stable ?? "n:")")
        }
        var markerChildren: [Int64: [String]] = [:]
        for verse in rows(source, "PlaylistItemMarkerBibleVerseMap") {
            if let marker = verse.optionalInt("PlaylistItemMarkerId") {
                markerChildren[marker, default: []].append("v|\(verse["VerseId"]?.stable ?? "n:")")
            }
        }
        for paragraph in rows(source, "PlaylistItemMarkerParagraphMap") {
            if let marker = paragraph.optionalInt("PlaylistItemMarkerId") {
                markerChildren[marker, default: []].append(
                    "p|\(paragraph["MepsDocumentId"]?.stable ?? "n:")|\(paragraph["ParagraphIndex"]?.stable ?? "n:")|\(paragraph["MarkerIndexWithinParagraph"]?.stable ?? "n:")"
                )
            }
        }
        var markers: [String] = []
        for marker in rows(source, "PlaylistItemMarker") where marker.optionalInt("PlaylistItemId") == itemID {
            let markerID = try marker.int("PlaylistItemMarkerId")
            let children = markerChildren[markerID, default: []].sorted().joined(separator: ",")
            markers.append(["Label", "StartTimeTicks", "DurationTicks", "EndTransitionDurationTicks"]
                .map { marker[$0]?.stable ?? "n:" }.joined(separator: "|") + "|" + children)
        }
        let thumbnailHash = item.optionalText("ThumbnailFilePath").flatMap { hashByPath[$0] } ?? ""
        let main = ["Label", "StartTrimOffsetTicks", "EndTrimOffsetTicks", "EndAction"]
            .map { item[$0]?.stable ?? "n:" }.joined(separator: "|")
        let accuracy = try map(source, "PlaylistItemAccuracy", try item.int("Accuracy"))
        return [
            memberships.joined(separator: ","), main, String(accuracy), thumbnailHash,
            locations.sorted().joined(separator: ","), media.sorted().joined(separator: ","),
            markers.sorted().joined(separator: ",")
        ].joined(separator: "#")
    }

    private func mergePlaylistItems() throws {
        var seen: [String: Int64] = [:]
        var nextID: Int64 = 1
        for source in MergeSource.allCases {
            for original in rows(source, "PlaylistItem") {
                let fingerprint = try playlistFingerprint(source, original)
                if source == .right, let existing = seen[fingerprint] {
                    setMap(source, "PlaylistItem", try original.int("PlaylistItemId"), existing)
                    continue
                }
                var record = original
                record["PlaylistItemId"] = .integer(nextID)
                record["Accuracy"] = .integer(try map(source, "PlaylistItemAccuracy", try original.int("Accuracy")))
                if let thumbnail = original.optionalText("ThumbnailFilePath") {
                    guard let mappedPath = pathMaps[source]?[thumbnail] else {
                        throw MergeEngineError.missingMapping("miniatura \(thumbnail)")
                    }
                    record["ThumbnailFilePath"] = .text(mappedPath)
                }
                append(record, to: "PlaylistItem")
                setMap(source, "PlaylistItem", try original.int("PlaylistItemId"), nextID)
                seen[fingerprint] = nextID
                nextID += 1
            }
        }
    }

    private func mergeMarkers() throws {
        var seen: [String: Int64] = [:]
        var nextID: Int64 = 1
        for source in MergeSource.allCases {
            for original in rows(source, "PlaylistItemMarker") {
                let parent = try map(source, "PlaylistItem", try original.int("PlaylistItemId"))
                let key = "\(parent)|\(try original.int("StartTimeTicks"))"
                if let existing = seen[key] {
                    setMap(source, "PlaylistItemMarker", try original.int("PlaylistItemMarkerId"), existing)
                    continue
                }
                var record = original
                record["PlaylistItemMarkerId"] = .integer(nextID)
                record["PlaylistItemId"] = .integer(parent)
                append(record, to: "PlaylistItemMarker")
                setMap(source, "PlaylistItemMarker", try original.int("PlaylistItemMarkerId"), nextID)
                seen[key] = nextID
                nextID += 1
            }
        }
    }

    private func mergeSimpleMap(table: String, foreignKeys: [String: String], keyColumns: [String]) throws {
        var seen = Set<String>()
        for source in MergeSource.allCases {
            for original in rows(source, table) {
                var record = original
                for (column, parentTable) in foreignKeys {
                    record[column] = .integer(try map(source, parentTable, try original.int(column)))
                }
                let key = keyColumns.map { record[$0]?.stable ?? "n:" }.joined(separator: "|")
                if seen.insert(key).inserted { append(record, to: table) }
            }
        }
    }

    private func mergeTags() throws {
        var seen: [String: Int64] = [:]
        var nextID: Int64 = 1
        for source in MergeSource.allCases {
            for original in rows(source, "Tag") {
                let key = "\(try original.int("Type"))|\(try original.text("Name"))"
                if let existing = seen[key] {
                    setMap(source, "Tag", try original.int("TagId"), existing)
                    continue
                }
                var record = original
                record["TagId"] = .integer(nextID)
                append(record, to: "Tag")
                setMap(source, "Tag", try original.int("TagId"), nextID)
                seen[key] = nextID
                nextID += 1
            }
        }
    }

    private func mergeTagMaps() throws {
        struct Entry {
            let targetKey: String
            let source: MergeSource
            let original: SQLiteRow
        }
        var grouped: [Int64: [Entry]] = [:]
        for source in MergeSource.allCases {
            let sorted = rows(source, "TagMap").sorted {
                let left = ($0.optionalInt("TagId") ?? 0, $0.optionalInt("Position") ?? 0, $0.optionalInt("TagMapId") ?? 0)
                let right = ($1.optionalInt("TagId") ?? 0, $1.optionalInt("Position") ?? 0, $1.optionalInt("TagMapId") ?? 0)
                if left.0 != right.0 { return left.0 < right.0 }
                if left.1 != right.1 { return left.1 < right.1 }
                return left.2 < right.2
            }
            for original in sorted {
                let tag = try map(source, "Tag", try original.int("TagId"))
                let key: String
                if let note = original.optionalInt("NoteId") {
                    key = "note|\(try map(source, "Note", note))"
                } else if let location = original.optionalInt("LocationId") {
                    key = "location|\(try map(source, "Location", location))"
                } else if let playlist = original.optionalInt("PlaylistItemId") {
                    key = "playlist|\(try map(source, "PlaylistItem", playlist))"
                } else {
                    throw MergeEngineError.invalidRow("TagMap senza destinazione")
                }
                grouped[tag, default: []].append(Entry(targetKey: key, source: source, original: original))
            }
        }
        var nextID: Int64 = 1
        for tag in grouped.keys.sorted() {
            var seen = Set<String>()
            var position: Int64 = 0
            for entry in grouped[tag, default: []] where seen.insert(entry.targetKey).inserted {
                let components = entry.targetKey.split(separator: "|", maxSplits: 1).map(String.init)
                let target = Int64(components[1])!
                var record: SQLiteRow = [
                    "TagMapId": .integer(nextID), "PlaylistItemId": .null, "LocationId": .null,
                    "NoteId": .null, "TagId": .integer(tag), "Position": .integer(position)
                ]
                if components[0] == "note" { record["NoteId"] = .integer(target) }
                if components[0] == "location" { record["LocationId"] = .integer(target) }
                if components[0] == "playlist" { record["PlaylistItemId"] = .integer(target) }
                append(record, to: "TagMap")
                setMap(entry.source, "TagMap", try entry.original.int("TagMapId"), nextID)
                nextID += 1
                position += 1
            }
        }
    }

    private func mergeInputFields() throws {
        var indexes: [String: (index: Int, source: MergeSource, original: SQLiteRow)] = [:]
        for source in MergeSource.allCases {
            for original in rows(source, "InputField") {
                var record = original
                let location = try map(source, "Location", try original.int("LocationId"))
                record["LocationId"] = .integer(location)
                let key = "\(location)|\(try original.text("TextTag"))"
                if let existing = indexes[key] {
                    guard merged["InputField"]?[existing.index]["Value"] != record["Value"] else { continue }
                    let textTag = try original.text("TextTag")
                    let conflict = MergeConflictItem(
                        id: "inputField:\(location):\(textTag)",
                        kind: .inputField,
                        context: locationDescription(existing.source, id: existing.original.optionalInt("LocationId")),
                        left: MergeConflictVersion(
                            title: Self.valueText(existing.original["Value"]),
                            preview: textTag,
                            details: ["Valore salvato nel primo backup"]
                        ),
                        right: MergeConflictVersion(
                            title: Self.valueText(original["Value"]),
                            preview: textTag,
                            details: ["Valore salvato nel secondo backup"]
                        ),
                        recommended: preferred
                    )
                    conflicts.append(conflict)
                    if chosenSource(for: conflict) == source {
                        merged["InputField"]?[existing.index]["Value"] = record["Value"]
                    }
                } else {
                    indexes[key] = (merged["InputField", default: []].count, source, original)
                    append(record, to: "InputField")
                }
            }
        }
    }
}
