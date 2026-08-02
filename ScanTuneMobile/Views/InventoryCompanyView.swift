import SwiftUI

/// Liste des appareils d'une entreprise donnée + bouton scanner en bas.
struct InventoryCompanyView: View {
    @ObservedObject var viewModel: InventoryViewModel
    let companyName: String

    @State private var showOnlyUnchecked = true
    @State private var showScanner = false
    @State private var showManualLookup = false
    @State private var pendingScanDevice: Device?
    @State private var scanErrorMessage: String?
    @State private var showScanError = false

    var body: some View {
        ZStack(alignment: .bottom) {
            deviceList
            scanButton
        }
        .navigationTitle(companyName)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScanner) {
            scannerSheet
        }
        .sheet(isPresented: $showManualLookup) {
            ManualLookupView(
                viewModel: viewModel,
                restrictToCompany: companyName
            ) { device in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    pendingScanDevice = device
                }
            }
        }
        .sheet(item: $pendingScanDevice) { device in
            InventoryScanFormView(
                viewModel: viewModel,
                device: device
            )
        }
        .alert("Scan non reconnu", isPresented: $showScanError, presenting: scanErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Device list

    private var deviceList: some View {
        let allRows = viewModel.deviceRows(forCompany: companyName)
        let rows = showOnlyUnchecked ? allRows.filter { !$0.isChecked } : allRows
        let checkedCount = allRows.filter(\.isChecked).count

        return List {
            Section {
                Toggle("N'afficher qu'à vérifier", isOn: $showOnlyUnchecked)
                HStack {
                    Text("\(checkedCount) / \(allRows.count) vérifiés")
                        .font(.callout)
                    Spacer()
                    Text("\(allRows.count - checkedCount) restants")
                        .font(.caption)
                        .foregroundStyle(allRows.count - checkedCount == 0 ? .green : .orange)
                }
            }

            Section {
                if rows.isEmpty {
                    Label(
                        showOnlyUnchecked ? "Tous les appareils sont vérifiés." : "Aucun appareil.",
                        systemImage: "checkmark.seal"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        deviceRow(row)
                    }
                }
            }
            // Espace pour le bouton sticky en bas.
            Section {
                Color.clear.frame(height: 80)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func deviceRow(_ row: InventoryDeviceRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.isChecked ? "checkmark.seal.fill" : "desktopcomputer")
                .foregroundStyle(row.isChecked ? .green : .blue)
                .font(.title3)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.device.deviceName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.device.serialNumber.isEmpty ? "—" : row.device.serialNumber)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !row.device.userDisplayName.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(row.device.userDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if row.isChecked, let at = row.lastCheckedAt, let by = row.lastCheckedBy {
                    Text("Vérifié \(at.formatted(date: .abbreviated, time: .shortened)) par \(by)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Scan button

    private var scanButton: some View {
        VStack {
            Spacer()
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
    }

    // MARK: - Scanner sheet

    private var scannerSheet: some View {
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

    private func handleScannedCode(_ code: String) {
        do {
            let device = try viewModel.resolveDeviceFromScannedCodeStrict(code)
            showScanner = false
            // Petite temporisation pour laisser le plein-écran se fermer avant la feuille.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pendingScanDevice = device
            }
        } catch {
            scanErrorMessage = error.localizedDescription
            showScanError = true
            showScanner = false
        }
    }
}
