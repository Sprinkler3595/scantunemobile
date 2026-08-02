import SwiftUI

/// Saisie manuelle d'un appareil quand le QR est endommagé ou absent.
/// Recherche live dans `scopedDevices` par numéro de série, nom d'appareil ou
/// utilisateur assigné. Sélection → ferme la vue et remonte le device choisi
/// à l'appelant (qui ouvre le formulaire de vérification).
struct ManualLookupView: View {
    @ObservedObject var viewModel: InventoryViewModel
    /// Si renseigné, restreint la recherche aux appareils de cette entreprise.
    let restrictToCompany: String?
    let onDeviceSelected: (Device) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var showCheckedToo: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                filterToggle
                resultsList
            }
            .navigationTitle("Saisie manuelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("N° série, nom, utilisateur…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var filterToggle: some View {
        Toggle("Inclure les appareils déjà vérifiés", isOn: $showCheckedToo)
            .font(.callout)
            .padding(.horizontal)
            .padding(.vertical, 6)
    }

    private var resultsList: some View {
        let results = filteredDevices()

        return Group {
            if results.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(results, id: \.id) { device in
                            Button {
                                AppLog.shared.info(
                                    "Manual lookup selection: \(device.deviceName) (serial=\(device.serialNumber))",
                                    category: "scanner"
                                )
                                onDeviceSelected(device)
                                dismiss()
                            } label: {
                                deviceRow(device)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("\(results.count) résultat(s)")
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: searchText.isEmpty ? "keyboard" : "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty
                 ? "Saisissez un n° de série, un nom d'appareil ou d'utilisateur."
                 : "Aucun résultat pour « \(searchText) »")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func deviceRow(_ device: Device) -> some View {
        let isChecked = viewModel.checkedDeviceIds.contains(device.id)
        return HStack(spacing: 12) {
            Image(systemName: isChecked ? "checkmark.seal.fill" : "desktopcomputer")
                .foregroundStyle(isChecked ? .green : .blue)
                .font(.title3)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(device.serialNumber.isEmpty ? "—" : device.serialNumber)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !device.userDisplayName.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(device.userDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if isChecked {
                    Text("Déjà vérifié")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Filtering

    private func filteredDevices() -> [Device] {
        let pool: [Device]
        if let company = restrictToCompany {
            pool = viewModel.scopedDevices.filter { viewModel.companyName(for: $0) == company }
        } else {
            pool = viewModel.scopedDevices
        }

        let checked = viewModel.checkedDeviceIds
        let unfiltered = showCheckedToo ? pool : pool.filter { !checked.contains($0.id) }

        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            // Pas de recherche → top 50 triés par nom pour éviter de scroller un parc entier.
            return Array(unfiltered.sorted {
                $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
            }.prefix(50))
        }

        return unfiltered
            .filter { device in
                device.deviceName.lowercased().contains(needle)
                    || device.serialNumber.lowercased().contains(needle)
                    || device.userDisplayName.lowercased().contains(needle)
                    || device.userPrincipalName.lowercased().contains(needle)
            }
            .sorted {
                $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
            }
    }
}
