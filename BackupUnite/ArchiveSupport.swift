import CryptoKit
import Foundation
import ZIPFoundation

enum ArchiveSupport {
    static let databaseName = "userData.db"
    static let manifestName = "manifest.json"

    static func extract(_ archiveURL: URL, to destination: URL) throws -> ExtractedBackup {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: archiveURL, to: destination)

        let manifestURL = destination.appendingPathComponent(manifestName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MergeEngineError.invalidArchive("manifest.json mancante")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let backup = manifest["userDataBackup"] as? [String: Any]
        else {
            throw MergeEngineError.invalidArchive("manifest.json illeggibile")
        }
        let schema = backup["schemaVersion"] as? Int ?? -1
        guard schema == 16 else { throw MergeEngineError.unsupportedSchema(schema) }

        let storedDatabaseName = backup["databaseName"] as? String ?? databaseName
        let databaseURL = destination.appendingPathComponent(storedDatabaseName)
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw MergeEngineError.invalidArchive("database \(storedDatabaseName) mancante")
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = fileManager.enumerator(
            at: destination,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var assets: [String] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let relative = String(fileURL.path.dropFirst(destination.path.count + 1))
            if relative != manifestName && relative != storedDatabaseName {
                assets.append(relative)
            }
        }
        return ExtractedBackup(
            root: destination,
            databaseURL: databaseURL,
            manifest: manifest,
            assetNames: assets.sorted()
        )
    }

    static func writeManifest(
        basedOn source: [String: Any],
        outputName: String,
        databaseURL: URL,
        to root: URL
    ) throws {
        let databaseHash = try sha256Hex(of: databaseURL)
        let now = ISO8601DateFormatter().string(from: Date())
        let manifest: [String: Any] = [
            "version": source["version"] ?? 1,
            "name": outputName,
            "type": source["type"] ?? 0,
            "userDataBackup": [
                "lastModifiedDate": now,
                "hash": databaseHash,
                "schemaVersion": 16,
                "deviceName": "Backup Unite",
                "databaseName": databaseName
            ],
            "creationDate": now
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [])
        try data.write(to: root.appendingPathComponent(manifestName), options: .atomic)
    }

    static func createArchive(from root: URL, at outputURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.zipItem(
            at: root,
            to: outputURL,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func jwMediaHash(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String($0, radix: 16) }.joined()
    }
}
