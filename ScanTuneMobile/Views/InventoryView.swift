import SwiftUI

/// Écran d'accueil de l'onglet Inventaire : liste des entreprises avec progression.
struct InventoryView: View {
    @ObservedObject var viewModel: InventoryViewModel

    @State private var showSettings = false
    @State private var showScanner = false
    @State private var showManualLookup = false
    @State private var pendingScanDevice: Device?
    @State private var scanErrorMessage: String?
    @State private var showScanError = false

    // Rapport PDF
    @State private var pdfExportURL: URL?
    @State private var showPDFShareSheet = false
    @State private var pdfErrorMessage: String?
    @State private var showPDFError = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !viewModel.settingsStore.settings.isConfigured {
                notConfiguredView
            } else if viewModel.isLoading && viewModel.scopedDevices.isEmpty {
                ProgressView("Chargement de l'inventaire...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                companyListView
            }
        }
        .navigationTitle("Inventaire \(viewModel.settingsStore.settings.inventoryYear)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        generatePDF()
                    } label: {
                        Label("Rapport PDF", systemImage: "doc.richtext")
                    }
                    .disabled(viewModel.scopedDevices.isEmpty)

                    Button {
                        showSettings = true
                    } label: {
                        Label("Réglages", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            InventorySettingsView(
                settingsStore: viewModel.settingsStore,
                sharePointService: viewModel.sharePointService
            ) {
                Task { await viewModel.refresh() }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            scannerFullScreen
        }
        .sheet(isPresented: $showManualLookup) {
            ManualLookupView(
                viewModel: viewModel,
                restrictToCompany: nil
            ) { device in
                // Délai pour laisser la sheet se fermer avant d'en ouvrir une autre.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    pendingScanDevice = device
                }
            }
        }
        .sheet(item: $pendingScanDevice) { device in
            InventoryScanFormView(viewModel: viewModel, device: device)
        }
        .sheet(isPresented: $showPDFShareSheet) {
            if let url = pdfExportURL {
                ActivityShareSheet(activityItems: [url])
            }
        }
        .alert("Export PDF impossible", isPresented: $showPDFError, presenting: pdfErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .alert("Scan non reconnu", isPresented: $showScanError, presenting: scanErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .task {
            if viewModel.scopedDevices.isEmpty {
                await viewModel.refresh()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await viewModel.queueStore.flush() }
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Not configured state

    private var notConfiguredView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "gearshape.2")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("Configuration requise")
                .font(.title2).fontWeight(.semibold)
            Text("Renseignez l'URL du site SharePoint et le nom du fichier d'inventaire pour commencer.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showSettings = true
            } label: {
                Label("Ouvrir les réglages", systemImage: "gearshape")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Company list

    private var companyListView: some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    globalProgressCard
                    if viewModel.isUsingSnapshot {
                        snapshotBanner
                    }
                    if !viewModel.queueStore.pending.isEmpty || !viewModel.queueStore.isOnline {
                        syncStatusCard
                    }
                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Entreprises") {
                    ForEach(viewModel.companiesProgress) { progress in
                        NavigationLink {
                            InventoryCompanyView(
                                viewModel: viewModel,
                                companyName: progress.companyName
                            )
                        } label: {
                            companyRow(progress)
                        }
                    }
                }

                // Espace pour que le dernier élément ne soit pas masqué par le bouton sticky.
                Section {
                    Color.clear.frame(height: 80)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)

            quickScanButton
        }
    }

    // MARK: - Quick scan button (accès direct depuis l'accueil)

    private var quickScanButton: some View {
        HStack(spacing: 10) {
            Button {
                showScanner = true
            } label: {
                Label("Scanner", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)

            Button {
                showManualLookup = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Saisie manuelle")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Scanner full-screen

    private var scannerFullScreen: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                QRScannerView(
                    onCodeScanned: { code in
                        handleScannedCode(code)
                    },
                    onError: { error in
                        scanErrorMessage = error.localizedDescription
                        showScanError = true
                        showScanner = false
                    }
                )
                .ignoresSafeArea()

                Button {
                    showScanner = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding()
            }
        }
    }

    private func generatePDF() {
        do {
            let url = try viewModel.generatePDFReport()
            pdfExportURL = url
            showPDFShareSheet = true
        } catch {
            pdfErrorMessage = error.localizedDescription
            showPDFError = true
        }
    }

    private func handleScannedCode(_ code: String) {
        do {
            let device = try viewModel.resolveDeviceFromScannedCodeStrict(code)
            showScanner = false
            // Temporisation pour laisser le plein-écran se fermer avant la feuille.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pendingScanDevice = device
            }
        } catch {
            scanErrorMessage = error.localizedDescription
            showScanError = true
            showScanner = false
        }
    }

    // MARK: - Snapshot banner (mode hors-ligne)

    private var snapshotBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.slash")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mode hors-ligne")
                    .font(.callout).fontWeight(.medium)
                if let age = viewModel.snapshotStore.ageLabel {
                    Text("Snapshot capturé \(age)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Global progress card

    private var globalProgressCard: some View {
        let g = viewModel.globalProgress
        let complete = g.isComplete

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: complete ? "party.popper.fill" : "checklist")
                    .foregroundStyle(complete ? .green : .blue)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(complete ? "Inventaire \(viewModel.settingsStore.settings.inventoryYear) terminé !" : "Progression globale")
                        .font(.headline)
                    Text("\(g.checkedDevices) / \(g.totalDevices) PC vérifiés")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int((g.progressRatio * 100).rounded()))%")
                    .font(.title3).bold()
                    .monospacedDigit()
                    .foregroundStyle(complete ? .green : .blue)
            }
            ProgressView(value: g.progressRatio)
                .tint(complete ? .green : .blue)
            if let last = viewModel.lastRefreshAt {
                Text("Dernière sync : \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sync status card

    private var syncStatusCard: some View {
        HStack(spacing: 10) {
            if viewModel.queueStore.isSyncing {
                ProgressView().controlSize(.small)
            } else if !viewModel.queueStore.isOnline {
                Image(systemName: "wifi.slash").foregroundStyle(.orange)
            } else {
                Image(systemName: "cloud.and.arrow.up").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.queueStore.pending.count) en attente de sync")
                    .font(.callout).fontWeight(.medium)
                if !viewModel.queueStore.isOnline {
                    Text("Hors ligne — sync auto au retour du réseau")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let err = viewModel.queueStore.lastSyncError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if viewModel.queueStore.isOnline && !viewModel.queueStore.isSyncing {
                Button("Réessayer") {
                    Task { await viewModel.queueStore.flush() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Company row

    private func companyRow(_ progress: CompanyProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: progress.isComplete ? "checkmark.seal.fill" : "building.2.fill")
                    .foregroundStyle(progress.isComplete ? .green : .blue)
                Text(progress.companyName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(progress.checkedDevices)/\(progress.totalDevices)")
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.progressRatio)
                .tint(progress.isComplete ? .green : .blue)
            if progress.remaining > 0 {
                Text("À vérifier : \(progress.remaining)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if progress.totalDevices > 0 {
                Text("Terminé")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}
