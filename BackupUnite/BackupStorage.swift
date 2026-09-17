import Foundation

struct StoredBackup: Identifiable, Hashable, Sendable {
    let url: URL
    let modified: Date
    let byteCount: Int64

    var id: String { url.path }
    var displayName: String { url.lastPathComponent }
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum BackupStorageError: LocalizedError {
    case exactlyTwoRequired
    case invalidExtension(String)
    case emptyName

    var errorDescription: String? {
        switch self {
        case .exactlyTwoRequired:
            "Seleziona esattamente due backup nello stesso passaggio."
        case let .invalidExtension(name):
            "Il file \(name) non è un backup .jwlibrary."
        case .emptyName:
            "Inserisci un nome valido per il backup."
        }
    }
}

enum BackupStorage {
    static func documentsDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func importsDirectory() throws -> URL {
        let url = try documentsDirectory()
            .appendingPathComponent("Backup Unite", isDirectory: true)
            .appendingPathComponent("Backup importati", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func mergedDirectory() throws -> URL {
        let url = try documentsDirectory()
            .appendingPathComponent("Backup Unite", isDirectory: true)
            .appendingPathComponent("Backup uniti", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func importBackups(_ urls: [URL]) throws -> [URL] {
        guard urls.count == 2 else { throw BackupStorageError.exactlyTwoRequired }
        let directory = try importsDirectory()
        let fileManager = FileManager.default
        var stored: [URL] = []

        for source in urls {
            guard source.pathExtension.lowercased() == "jwlibrary" else {
                throw BackupStorageError.invalidExtension(source.lastPathComponent)
            }
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }

            let destination = uniqueURL(in: directory, preferredName: source.lastPathComponent)
            try fileManager.copyItem(at: source, to: destination)
            stored.append(destination)
        }
        return stored
    }

    static func listMergedBackups() throws -> [StoredBackup] {
        try migrateLegacyBackups()
        let directory = try mergedDirectory()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            guard url.pathExtension.lowercased() == "jwlibrary" else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return StoredBackup(
                url: url,
                modified: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }
        .sorted { $0.modified > $1.modified }
    }

    private static func migrateLegacyBackups() throws {
        let documents = try documentsDirectory()
        let destinationDirectory = try mergedDirectory()
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for source in urls {
            guard source.pathExtension.lowercased() == "jwlibrary" else { continue }
            let name = source.lastPathComponent
            guard name.contains("_Merged") else { continue }
            let destination = uniqueURL(in: destinationDirectory, preferredName: name)
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    static func rename(_ backup: StoredBackup, to requestedName: String) throws -> StoredBackup {
        let base = cleanedBaseName(requestedName)
        guard !base.isEmpty else { throw BackupStorageError.emptyName }
        let preferredName = base + ".jwlibrary"
        let destination = uniqueURL(
            in: backup.url.deletingLastPathComponent(),
            preferredName: preferredName,
            excluding: backup.url
        )
        if destination != backup.url {
            try FileManager.default.moveItem(at: backup.url, to: destination)
        }
        let values = try destination.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return StoredBackup(
            url: destination,
            modified: values.contentModificationDate ?? Date(),
            byteCount: Int64(values.fileSize ?? 0)
        )
    }

    private static func cleanedBaseName(_ value: String) -> String {
        let withoutExtension = value.lowercased().hasSuffix(".jwlibrary")
            ? String(value.dropLast(".jwlibrary".count))
            : value
        let forbidden = CharacterSet(charactersIn: "/\\:\0")
        return withoutExtension
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueURL(
        in directory: URL,
        preferredName: String,
        excluding excludedURL: URL? = nil
    ) -> URL {
        let fileManager = FileManager.default
        let preferred = directory.appendingPathComponent(preferredName)
        if preferred == excludedURL || !fileManager.fileExists(atPath: preferred.path) { return preferred }

        let source = URL(fileURLWithPath: preferredName)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)-\(index).\(ext)")
            if candidate == excludedURL || !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
