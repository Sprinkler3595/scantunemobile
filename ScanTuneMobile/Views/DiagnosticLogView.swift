import SwiftUI
import UIKit

/// Écran de consultation du journal applicatif en mémoire (1000 dernières entrées),
/// avec partage du fichier `.log` via le ShareSheet iOS.
struct DiagnosticLogView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LogEntry] = []
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var exportErrorMessage: String?
    @State private var showExportError = false
    @State private var showClearConfirm = false
    @State private var filterLevel: LogLevel?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar

                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    logList
                }
            }
            .navigationTitle("Diagnostic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            export()
                        } label: {
                            Label("Exporter (.log)", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("Vider le buffer", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear(perform: reload)
            .refreshable { reload() }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportURL {
                    ActivityShareSheet(activityItems: [url])
                }
            }
            .alert("Export impossible", isPresented: $showExportError, presenting: exportErrorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
            .confirmationDialog("Vider le buffer de log ?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Vider", role: .destructive) {
                    AppLog.shared.clear()
                    reload()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les entrées en mémoire seront supprimées. Les logs système (Console.app) ne sont pas affectés.")
            }
        }
    }

    // MARK: - Sections

    private var filterBar: some View {
        Picker("Niveau", selection: $filterLevel) {
            Text("Tous").tag(LogLevel?.none)
            Text("Info").tag(LogLevel?.some(.info))
            Text("Warn").tag(LogLevel?.some(.warning))
            Text("Error").tag(LogLevel?.some(.error))
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(filterLevel == nil ? "Aucune entrée pour le moment" : "Aucune entrée pour ce niveau")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var logList: some View {
        List {
            Section {
                ForEach(Array(filteredEntries.reversed().enumerated()), id: \.offset) { _, entry in
                    LogEntryRow(entry: entry)
                }
            } header: {
                Text("\(filteredEntries.count) entrée(s)")
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Actions

    private func reload() {
        entries = AppLog.shared.snapshot()
    }

    private var filteredEntries: [LogEntry] {
        guard let lvl = filterLevel else { return entries }
        return entries.filter { $0.level == lvl }
    }

    private func export() {
        do {
            let url = try AppLog.shared.exportToTemporaryFile()
            exportURL = url
            showShareSheet = true
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }
}

// MARK: - Row

private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                levelBadge
                Text(entry.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(entry.message)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }

    private var levelBadge: some View {
        Text(entry.level.rawValue)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(levelColor.opacity(0.18))
            .foregroundStyle(levelColor)
            .cornerRadius(4)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - ShareSheet wrapper

/// Pont UIKit minimal pour présenter un `UIActivityViewController` depuis SwiftUI.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
