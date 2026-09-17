import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selectedURLs: [URL] = []
    @State private var isImporterPresented = false
    @State private var isMerging = false
    @State private var operationStatus = ""
    @State private var analysis: MergeAnalysis?
    @State private var resolutions: [String: MergeResolution] = [:]
    @State private var highlightMode: HighlightMergeMode = .both
    @State private var isConflictResolverPresented = false
    @State private var mergeSummary: MergeSummary?
    @State private var mergeError: String?
    @State private var preparedBackupURL: URL?
    @State private var preparationError: String?
    @State private var savedBackups: [StoredBackup] = []
    @State private var isImporting = false
    @State private var exportDocument = JWLibraryDocument()
    @State private var exportFilename = "Backup-Unito.jwlibrary"
    @State private var isExporterPresented = false
    @State private var storageMessage: String?
    @State private var renameTarget: StoredBackup?
    @State private var renameText = ""
    @State private var isRenamePresented = false

    private var isBusy: Bool { isMerging || isImporting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    mergeCard
                    if let analysis, !analysis.conflicts.isEmpty { conflictSummaryCard(analysis) }
                    if let mergeSummary { resultCard(mergeSummary) }
                    savedBackupsCard
                    preparedBackupCard
                    safetyNote
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Backup Unite")
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.jwLibraryBackup],
                allowsMultipleSelection: true,
                onCompletion: receiveFiles
            )
            .fileExporter(
                isPresented: $isExporterPresented,
                document: exportDocument,
                contentType: .jwLibraryBackup,
                defaultFilename: exportFilename,
                onCompletion: exportCompleted
            )
            .alert("Rinomina backup", isPresented: $isRenamePresented) {
                TextField("Nome del backup", text: $renameText)
                Button("Annulla", role: .cancel) { renameTarget = nil }
                Button("Rinomina", action: completeRename)
            } message: {
                Text("L’estensione .jwlibrary viene mantenuta automaticamente.")
            }
            .fullScreenCover(isPresented: $isConflictResolverPresented) {
                if let analysis {
                    ConflictResolutionView(analysis: analysis, resolutions: $resolutions) {
                        isConflictResolverPresented = false
                        startFinalMerge()
                    }
                }
            }
            .task {
                prepareBundledBackup()
                refreshStoredBackups()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.12)).frame(width: 82, height: 82)
                Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.blue)
            }
            Text("Unisci i tuoi backup")
                .font(.title2.bold())
            Text("Carica anche i backup futuri, modifica le scelte e crea un file pronto per JW Library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }

    private var mergeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Nuovo merge", systemImage: "plus.square.on.square")
                .font(.headline)

            Text("Scegli esattamente due file .jwlibrary. L’app ne conserva copie di lavoro e non modifica mai gli originali.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if selectedURLs.isEmpty {
                Label("Nessun backup selezionato", systemImage: "doc.badge.plus")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                VStack(spacing: 9) {
                    ForEach(Array(selectedURLs.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 10) {
                            Image(systemName: "\(index + 1).circle.fill").foregroundStyle(.blue)
                            Text(url.lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            Button {
                isImporterPresented = true
            } label: {
                Label(selectedURLs.isEmpty ? "Scegli due backup" : "Cambia selezione", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isBusy)

            VStack(alignment: .leading, spacing: 9) {
                Label("Sottolineature da usare", systemImage: "highlighter")
                    .font(.subheadline.weight(.semibold))
                Picker("Sottolineature da usare", selection: $highlightMode) {
                    ForEach(HighlightMergeMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isBusy)

                Text(highlightMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .onChange(of: highlightMode) {
                analysis = nil
                resolutions = [:]
                mergeSummary = nil
                mergeError = nil
            }

            Button(action: primaryAction) {
                Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedURLs.count != 2 || isBusy || mergeSummary != nil)

            if isBusy {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(operationStatus).fontWeight(.semibold)
                        Text("Non chiudere l’app; il controllo finale può richiedere qualche minuto.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 3)
            }

            if let mergeError {
                Label(mergeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var primaryButtonTitle: String {
        guard let analysis else { return "Analizza conflitti" }
        let unresolved = analysis.conflicts.filter { resolutions[$0.id] == nil }.count
        if unresolved > 0 { return "Risolvi \(unresolved) conflitti" }
        return "Crea e verifica il backup"
    }

    private var primaryButtonIcon: String {
        guard let analysis else { return "magnifyingglass" }
        return analysis.conflicts.contains { resolutions[$0.id] == nil }
            ? "rectangle.on.rectangle.badge.exclamationmark"
            : "wand.and.stars"
    }

    private func conflictSummaryCard(_ analysis: MergeAnalysis) -> some View {
        let grouped = Dictionary(grouping: analysis.conflicts, by: \.kind).mapValues(\.count)
        let unresolved = analysis.conflicts.filter { resolutions[$0.id] == nil }.count
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Collisioni trovate", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(analysis.conflicts.count)").font(.headline.monospacedDigit())
            }

            ForEach(MergeConflictKind.allCases, id: \.self) { kind in
                if let count = grouped[kind], count > 0 {
                    HStack {
                        Label(kind.title, systemImage: kind.icon)
                        Spacer()
                        Text(count.formatted()).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }
            }

            Label(
                unresolved == 0 ? "Tutte le scelte sono state confermate" : "Mancano \(unresolved) scelte",
                systemImage: unresolved == 0 ? "checkmark.circle.fill" : "circle.dotted"
            )
            .font(.subheadline)
            .foregroundStyle(unresolved == 0 ? .green : .orange)

            Button {
                isConflictResolverPresented = true
            } label: {
                Label(unresolved == 0 ? "Rivedi le scelte" : "Scegli cosa conservare", systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isBusy)
        }
        .cardStyle()
    }

    private func resultCard(_ summary: MergeSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Backup verificato", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                Text("schema 16").font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                resultStat("Note", summary.notes)
                resultStat("Evidenziazioni", summary.highlights)
                resultStat("Segnalibri", summary.bookmarks)
                resultStat("Playlist", summary.playlists)
                resultStat("Elementi playlist", summary.playlistItems)
                resultStat("Media", summary.media)
            }

            Label("Integrità SQLite OK · 0 collegamenti non validi · media e miniature presenti", systemImage: "shield.checkered")
                .font(.caption)
                .foregroundStyle(.secondary)

            Label("Sottolineature: \(highlightMode.title.lowercased())", systemImage: "highlighter")
                .font(.caption)
                .foregroundStyle(.secondary)

            if summary.resolvedConflicts > 0 {
                Text("Sono state applicate le tue scelte a \(summary.resolvedConflicts) conflitti: \(summary.bookmarkConflicts) segnalibri, \(summary.markingConflicts) evidenziazioni, \(summary.noteConflicts) note e \(summary.inputFieldConflicts) campi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ShareLink(item: summary.outputURL) {
                Label("Invia a JW Library / Condividi", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)

            Button {
                prepareExport(summary.outputURL)
            } label: {
                Label("Salva una copia in File", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if let analysis, !analysis.conflicts.isEmpty {
                Button {
                    isConflictResolverPresented = true
                } label: {
                    Label("Modifica le scelte e ricrea", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }

            Button(action: resetForNewMerge) {
                Label("Unisci altri due backup", systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)

            Text(summary.outputURL.lastPathComponent)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .cardStyle()
    }

    private var savedBackupsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("I tuoi backup uniti", systemImage: "externaldrive.fill.badge.checkmark")
                    .font(.headline)
                Spacer()
                Text(savedBackups.count.formatted())
                    .font(.headline.monospacedDigit())
            }

            Text("Restano nell’app e sono visibili anche in File › Sul mio iPhone › Backup Unite.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if savedBackups.isEmpty {
                Label("Non hai ancora creato backup", systemImage: "tray")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                ForEach(Array(savedBackups.prefix(8))) { item in
                    HStack(spacing: 11) {
                        Image(systemName: "doc.zipper")
                            .font(.title3)
                            .foregroundStyle(.purple)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text("\(item.modified.formatted(date: .abbreviated, time: .shortened)) · \(item.sizeDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Menu {
                            ShareLink(item: item.url) {
                                Label("JW Library / Condividi", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                prepareExport(item.url)
                            } label: {
                                Label("Salva in File", systemImage: "arrow.down.doc")
                            }
                            Button {
                                beginRename(item)
                            } label: {
                                Label("Rinomina", systemImage: "pencil")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 4)
                    if item.id != savedBackups.prefix(8).last?.id { Divider() }
                }
            }

            if let storageMessage {
                Label(storageMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .cardStyle()
    }

    private func resultStat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted()).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 55)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var preparedBackupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Merge iPhone + iPad già pronto", systemImage: "shippingbox.fill")
                .font(.headline)
            Text("È il risultato verificato dei due backup del 17 agosto già incluso nell’app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let preparedBackupURL {
                ShareLink(item: preparedBackupURL) {
                    Label("Condividi il backup già unito", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if let preparationError {
                Label(preparationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                ProgressView("Preparazione…")
            }
        }
        .cardStyle()
    }

    private var safetyNote: some View {
        Label {
            Text("Prima di eliminare gli originali, controlla in JW Library alcune note, evidenziazioni, segnalibri e ogni playlist.")
        } icon: {
            Image(systemName: "externaldrive.badge.exclamationmark")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func receiveFiles(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard urls.count == 2 else {
                selectedURLs = []
                mergeError = BackupStorageError.exactlyTwoRequired.localizedDescription
                return
            }
            isImporting = true
            operationStatus = "Importazione delle copie di lavoro…"
            analysis = nil
            resolutions = [:]
            mergeSummary = nil
            mergeError = nil
            storageMessage = nil
            Task {
                do {
                    let copies = try await Task.detached(priority: .userInitiated) {
                        try BackupStorage.importBackups(urls)
                    }.value
                    selectedURLs = copies
                } catch {
                    selectedURLs = []
                    mergeError = "Importazione non riuscita: \(error.localizedDescription)"
                }
                isImporting = false
            }
        case let .failure(error):
            mergeError = "Selezione non riuscita: \(error.localizedDescription)"
        }
    }

    private func primaryAction() {
        guard let analysis else {
            startAnalysis()
            return
        }
        if analysis.conflicts.contains(where: { resolutions[$0.id] == nil }) {
            isConflictResolverPresented = true
        } else {
            startFinalMerge()
        }
    }

    private func startAnalysis() {
        guard selectedURLs.count == 2, !isMerging else { return }
        let left = selectedURLs[0]
        let right = selectedURLs[1]
        let selectedHighlightMode = highlightMode
        isMerging = true
        operationStatus = "Analisi delle collisioni…"
        analysis = nil
        resolutions = [:]
        mergeSummary = nil
        mergeError = nil

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try JWMergeEngine().analyze(
                        left: left,
                        right: right,
                        highlightMode: selectedHighlightMode
                    )
                }.value
                analysis = result
                isMerging = false
                if result.conflicts.isEmpty {
                    startFinalMerge()
                } else {
                    isConflictResolverPresented = true
                }
            } catch {
                mergeError = error.localizedDescription
                isMerging = false
            }
        }
    }

    private func startFinalMerge() {
        guard selectedURLs.count == 2, !isMerging else { return }
        let left = selectedURLs[0]
        let right = selectedURLs[1]
        let decisions = resolutions
        let selectedHighlightMode = highlightMode
        if let analysis, analysis.conflicts.contains(where: { decisions[$0.id] == nil }) {
            isConflictResolverPresented = true
            return
        }
        isMerging = true
        operationStatus = "Creazione e verifica del backup…"
        mergeSummary = nil
        mergeError = nil

        Task {
            do {
                let documents = try BackupStorage.mergedDirectory()
                let summary = try await Task.detached(priority: .userInitiated) {
                    try JWMergeEngine().merge(
                        left: left,
                        right: right,
                        outputDirectory: documents,
                        resolutions: decisions,
                        highlightMode: selectedHighlightMode
                    )
                }.value
                mergeSummary = summary
                refreshStoredBackups()
                storageMessage = "Backup conservato nell’archivio dell’app."
            } catch {
                mergeError = error.localizedDescription
            }
            isMerging = false
        }
    }

    private func prepareBundledBackup() {
        guard preparedBackupURL == nil, preparationError == nil else { return }
        guard let bundled = Bundle.main.url(
            forResource: "UserdataBackup_2026-08-17_Merged",
            withExtension: "jwlibrary"
        ) else {
            preparationError = "Backup incluso nell’app non trovato."
            return
        }
        do {
            let documents = try BackupStorage.mergedDirectory()
            let destination = documents.appendingPathComponent("UserdataBackup_2026-08-17_Merged.jwlibrary")
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: bundled, to: destination)
            }
            preparedBackupURL = destination
            refreshStoredBackups()
        } catch {
            preparationError = "Impossibile preparare il backup: \(error.localizedDescription)"
        }
    }

    private func refreshStoredBackups() {
        do {
            savedBackups = try BackupStorage.listMergedBackups()
        } catch {
            mergeError = "Impossibile leggere i backup conservati: \(error.localizedDescription)"
        }
    }

    private func prepareExport(_ url: URL) {
        do {
            exportDocument = try JWLibraryDocument(url: url)
            exportFilename = url.lastPathComponent
            isExporterPresented = true
            storageMessage = nil
        } catch {
            mergeError = "Impossibile preparare il download: \(error.localizedDescription)"
        }
    }

    private func exportCompleted(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            storageMessage = "Copia salvata nell’app File."
        case let .failure(error):
            let cocoa = error as? CocoaError
            if cocoa?.code != .userCancelled {
                mergeError = "Salvataggio non riuscito: \(error.localizedDescription)"
            }
        }
    }

    private func beginRename(_ backup: StoredBackup) {
        renameTarget = backup
        renameText = backup.url.deletingPathExtension().lastPathComponent
        isRenamePresented = true
    }

    private func completeRename() {
        guard let target = renameTarget else { return }
        do {
            let renamed = try BackupStorage.rename(target, to: renameText)
            if mergeSummary?.outputURL == target.url { mergeSummary?.outputURL = renamed.url }
            if preparedBackupURL == target.url { preparedBackupURL = renamed.url }
            storageMessage = "Backup rinominato."
            refreshStoredBackups()
        } catch {
            mergeError = "Rinomina non riuscita: \(error.localizedDescription)"
        }
        renameTarget = nil
    }

    private func resetForNewMerge() {
        selectedURLs = []
        analysis = nil
        resolutions = [:]
        highlightMode = .both
        mergeSummary = nil
        mergeError = nil
        storageMessage = nil
    }
}

private extension View {
    func cardStyle() -> some View {
        padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
