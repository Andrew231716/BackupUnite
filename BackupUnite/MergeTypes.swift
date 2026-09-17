import Foundation

enum MergeEngineError: LocalizedError, Sendable {
    case invalidArchive(String)
    case unsupportedSchema(Int)
    case invalidRow(String)
    case sqlite(String)
    case missingMapping(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArchive(message): "Archivio non valido: \(message)"
        case let .unsupportedSchema(version): "Schema \(version) non supportato; serve lo schema 16."
        case let .invalidRow(message): "Riga database non valida: \(message)"
        case let .sqlite(message): "Errore SQLite: \(message)"
        case let .missingMapping(message): "Rimappatura ID mancante: \(message)"
        case let .validation(message): "Validazione fallita: \(message)"
        }
    }
}

enum MergeSource: String, CaseIterable, Codable, Hashable, Sendable { case left, right }

enum MergeResolution: String, Codable, Hashable, Sendable {
    case left
    case right
    case both

    init(_ source: MergeSource) {
        self = source == .left ? .left : .right
    }

    var source: MergeSource? {
        switch self {
        case .left: .left
        case .right: .right
        case .both: nil
        }
    }
}

enum HighlightMergeMode: String, CaseIterable, Codable, Hashable, Sendable {
    case both
    case leftOnly
    case rightOnly

    var title: String {
        switch self {
        case .both: "Entrambi"
        case .leftOnly: "1° backup"
        case .rightOnly: "2° backup"
        }
    }

    var explanation: String {
        switch self {
        case .both: "Unisce le sottolineature dei due backup e ti mostra le eventuali collisioni."
        case .leftOnly: "Usa soltanto le sottolineature del primo backup selezionato."
        case .rightOnly: "Usa soltanto le sottolineature del secondo backup selezionato."
        }
    }

    var sources: [MergeSource] {
        switch self {
        case .both: MergeSource.allCases
        case .leftOnly: [.left]
        case .rightOnly: [.right]
        }
    }
}

enum MergeConflictKind: String, CaseIterable, Codable, Hashable, Sendable {
    case bookmark
    case marking
    case note
    case inputField

    var title: String {
        switch self {
        case .bookmark: "Segnalibri"
        case .marking: "Evidenziazioni"
        case .note: "Note"
        case .inputField: "Campi compilati"
        }
    }

    var singularTitle: String {
        switch self {
        case .bookmark: "Conflitto segnalibro"
        case .marking: "Conflitto evidenziazione"
        case .note: "Conflitto nota"
        case .inputField: "Conflitto campo compilato"
        }
    }

    var icon: String {
        switch self {
        case .bookmark: "bookmark.fill"
        case .marking: "highlighter"
        case .note: "note.text"
        case .inputField: "rectangle.and.pencil.and.ellipsis"
        }
    }
}

struct MergeConflictVersion: Hashable, Sendable {
    let title: String
    let preview: String
    let details: [String]
}

struct MergeConflictItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: MergeConflictKind
    let context: String
    let left: MergeConflictVersion
    let right: MergeConflictVersion
    let recommended: MergeSource
}

struct MergeAnalysis: Sendable {
    let leftName: String
    let rightName: String
    let conflicts: [MergeConflictItem]
}

struct MergeSummary: Sendable {
    var outputURL: URL
    let notes: Int
    let highlights: Int
    let bookmarks: Int
    let tags: Int
    let inputFields: Int
    let playlists: Int
    let playlistItems: Int
    let media: Int
    let bookmarkConflicts: Int
    let markingConflicts: Int
    let noteConflicts: Int
    let inputFieldConflicts: Int

    var resolvedConflicts: Int {
        bookmarkConflicts + markingConflicts + noteConflicts + inputFieldConflicts
    }
}

struct ExtractedBackup {
    let root: URL
    let databaseURL: URL
    let manifest: [String: Any]
    let assetNames: [String]

    var lastModified: Date {
        guard
            let userData = manifest["userDataBackup"] as? [String: Any],
            let value = userData["lastModifiedDate"] as? String
        else { return .distantPast }
        return Self.parseDate(value)
    }

    static func parseDate(_ value: String) -> Date {
        let formats = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss'Z'"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return .distantPast
    }
}
