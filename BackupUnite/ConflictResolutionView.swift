import SwiftUI

struct ConflictResolutionView: View {
    let analysis: MergeAnalysis
    @Binding var resolutions: [String: MergeResolution]
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0

    private var conflict: MergeConflictItem { analysis.conflicts[currentIndex] }
    private var resolvedCount: Int {
        analysis.conflicts.reduce(0) { $0 + (resolutions[$1.id] == nil ? 0 : 1) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    progressHeader
                    contextCard
                    choiceCard(side: .left, version: conflict.left, filename: analysis.leftName)
                    choiceCard(side: .right, version: conflict.right, filename: analysis.rightName)
                    if conflict.kind == .note { keepBothNotesCard }
                    quickChoiceMenu
                    navigationButtons
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(conflict.kind.singularTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(conflict.kind.title, systemImage: conflict.kind.icon)
                    .font(.headline)
                Spacer()
                Text("\(currentIndex + 1) di \(analysis.conflicts.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(resolvedCount), total: Double(analysis.conflicts.count))
            Text("\(resolvedCount) risolti · \(analysis.conflicts.count - resolvedCount) da scegliere")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dove si trova").font(.caption.bold()).foregroundStyle(.secondary)
            Text(conflict.context).font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func choiceCard(side: MergeSource, version: MergeConflictVersion, filename: String) -> some View {
        let selected = resolutions[conflict.id] == MergeResolution(side)
        let recommended = conflict.recommended == side
        return Button {
            resolutions[conflict.id] = MergeResolution(side)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(side == .left ? "PRIMO BACKUP" : "SECONDO BACKUP")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(filename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if recommended {
                        Text("CONSIGLIATO")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? .blue : .secondary)
                }

                Divider()
                Text(version.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if !version.preview.isEmpty {
                    Text(version.preview)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(8)
                }
                ForEach(Array(version.details.enumerated()), id: \.offset) { _, detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? Color.blue : Color.secondary.opacity(0.18), lineWidth: selected ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var keepBothNotesCard: some View {
        let selected = resolutions[conflict.id] == .both
        return Button {
            resolutions[conflict.id] = .both
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CONSERVA ENTRAMBE")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text("Crea due note distinte nel backup unito")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? .blue : .secondary)
                }

                Divider()
                Label("Mantieni tutti e due i testi", systemImage: "note.text.badge.plus")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("L’app assegna alla seconda nota un nuovo identificatore, conservando contenuto, posizione e collegamenti di entrambe.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? Color.blue : Color.secondary.opacity(0.18), lineWidth: selected ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var quickChoiceMenu: some View {
        Menu {
            Section("Solo \(conflict.kind.title.lowercased())") {
                Button("Usa sempre il primo backup") { apply(.left, to: conflict.kind) }
                Button("Usa sempre il secondo backup") { apply(.right, to: conflict.kind) }
                if conflict.kind == .note {
                    Button("Conserva entrambe le note") { applyBothNotes() }
                }
                Button("Usa sempre la scelta consigliata") { applyRecommended(to: conflict.kind) }
            }
            Section("Tutti i conflitti") {
                Button("Usa il primo backup per tutti") { applyToAll(.left) }
                Button("Usa il secondo backup per tutti") { applyToAll(.right) }
                Button("Usa tutte le scelte consigliate") { applyAllRecommended() }
            }
        } label: {
            Label("Applica la stessa scelta a più conflitti", systemImage: "checklist")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            Button {
                currentIndex = max(0, currentIndex - 1)
            } label: {
                Label("Indietro", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(currentIndex == 0)

            Button(action: continueAction) {
                Label(
                    resolvedCount == analysis.conflicts.count ? "Conferma e crea" : "Continua",
                    systemImage: resolvedCount == analysis.conflicts.count ? "checkmark.shield.fill" : "chevron.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(resolutions[conflict.id] == nil)
        }
        .controlSize(.large)
        .padding(.bottom)
    }

    private func continueAction() {
        if resolvedCount == analysis.conflicts.count {
            onComplete()
            return
        }
        if let next = ((currentIndex + 1)..<analysis.conflicts.count)
            .first(where: { resolutions[analysis.conflicts[$0].id] == nil }) {
            currentIndex = next
        } else if let first = analysis.conflicts.indices
            .first(where: { resolutions[analysis.conflicts[$0].id] == nil }) {
            currentIndex = first
        }
    }

    private func apply(_ side: MergeSource, to kind: MergeConflictKind) {
        for item in analysis.conflicts where item.kind == kind { resolutions[item.id] = MergeResolution(side) }
    }

    private func applyRecommended(to kind: MergeConflictKind) {
        for item in analysis.conflicts where item.kind == kind { resolutions[item.id] = MergeResolution(item.recommended) }
    }

    private func applyBothNotes() {
        for item in analysis.conflicts where item.kind == .note { resolutions[item.id] = .both }
    }

    private func applyToAll(_ side: MergeSource) {
        for item in analysis.conflicts { resolutions[item.id] = MergeResolution(side) }
    }

    private func applyAllRecommended() {
        for item in analysis.conflicts { resolutions[item.id] = MergeResolution(item.recommended) }
    }
}
