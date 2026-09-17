import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var jwLibraryBackup: UTType {
        UTType(filenameExtension: "jwlibrary")
            ?? UTType(exportedAs: "it.andreapozzi.jwlibrary-backup", conformingTo: .zip)
    }
}

struct JWLibraryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.jwLibraryBackup] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(url: URL) throws {
        data = try Data(contentsOf: url)
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
