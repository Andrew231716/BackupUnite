import SwiftUI

#if DEBUG
struct SelfTestView: View {
    @State private var message = "Avvio prova completa…"

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message).multilineTextAlignment(.center)
        }
        .padding()
        .task { await run() }
    }

    private func run() async {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let left = documents.appendingPathComponent("self-test-left.jwlibrary")
            let right = documents.appendingPathComponent("self-test-right.jwlibrary")
            let testResult = try await Task.detached(priority: .userInitiated) {
                let engine = JWMergeEngine()
                let analysis = try engine.analyze(left: left, right: right, highlightMode: .rightOnly)
                let decisions = Dictionary(uniqueKeysWithValues: analysis.conflicts.map {
                    ($0.id, $0.kind == .note ? MergeResolution.both : MergeResolution.right)
                })
                let summary = try engine.merge(
                    left: left,
                    right: right,
                    outputDirectory: documents,
                    resolutions: decisions,
                    highlightMode: .rightOnly
                )
                return (analysis, summary)
            }.value
            let analysis = testResult.0
            let summary = testResult.1
            let conflictCounts = Dictionary(grouping: analysis.conflicts, by: \.kind).mapValues(\.count)
            let report: [String: Any] = [
                "status": "ok",
                "testNoteResolution": "keep-both",
                "testHighlightMode": "right-only",
                "conflicts": analysis.conflicts.count,
                "bookmarkConflicts": conflictCounts[.bookmark, default: 0],
                "markingConflicts": conflictCounts[.marking, default: 0],
                "noteConflicts": conflictCounts[.note, default: 0],
                "inputFieldConflicts": conflictCounts[.inputField, default: 0],
                "output": summary.outputURL.lastPathComponent,
                "notes": summary.notes,
                "highlights": summary.highlights,
                "bookmarks": summary.bookmarks,
                "tags": summary.tags,
                "inputFields": summary.inputFields,
                "playlists": summary.playlists,
                "playlistItems": summary.playlistItems,
                "media": summary.media,
                "appliedResolutions": summary.resolvedConflicts
            ]
            try write(report, to: documents.appendingPathComponent("self-test-result.json"))
            message = "Prova completata"
        } catch {
            let report: [String: Any] = ["status": "error", "message": error.localizedDescription]
            if let documents = try? FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ) {
                try? write(report, to: documents.appendingPathComponent("self-test-result.json"))
            }
            message = "Errore: \(error.localizedDescription)"
        }
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
#endif
