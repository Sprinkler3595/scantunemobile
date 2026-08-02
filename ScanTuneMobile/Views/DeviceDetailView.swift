import SwiftUI
import UIKit

/// Vue détaillée d'un appareil Intune. 100% LECTURE SEULE — affichage des informations uniquement.
struct DeviceDetailView: View {
    @StateObject private var viewModel: DeviceViewModel
    /// Anomalies à afficher en bandeau d'alerte. Passées par l'écran appelant
    /// (typiquement la liste d'anomalies ou de devices d'une entreprise).
    let anomalies: [DeviceAnomaly]

    init(device: Device, graphService: GraphService, anomalies: [DeviceAnomaly] = []) {
        // On crée le VM ici pour pouvoir lui passer le device directement.
        let vm = DeviceViewModel(graphService: graphService)
        vm.device = device
        _viewModel = StateObject(wrappedValue: vm)
        self.anomalies = anomalies
    }

    init(viewModel: DeviceViewModel, anomalies: [DeviceAnomaly] = []) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.anomalies = anomalies
    }

    var body: some View {
        ScrollView {
            if let device = viewModel.device {
                VStack(spacing: 0) {
                    deviceHeader(device)
                    deviceInfoSections(device)
                }
            } else if viewModel.isLoading {
                ProgressView("Chargement...")
                    .padding(.top, 60)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Erreur")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 60)
            }
        }
        .navigationTitle(viewModel.device?.deviceName ?? "Appareil")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Charge le profil de l'utilisateur assigné (poste, département, bureau)
            // quand le device est fourni directement (flux scanner).
            await viewModel.loadAssignedUserIfNeeded()
            // Détermine le type de jointure Azure AD (hybride vs 100% Intune).
            await viewModel.loadJoinTypeIfNeeded()
            // Détecte d'éventuels doublons de numéro de série.
            await viewModel.loadSerialDuplicatesIfNeeded()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Header

    private func deviceHeader(_ device: Device) -> some View {
        VStack(spacing: 12) {
            // Status badge
            HStack(spacing: 8) {
                Image(systemName: device.displayStatus.icon)
                    .foregroundColor(statusColor(device.displayStatus))
                Text(device.displayStatus.rawValue)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(statusColor(device.displayStatus))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(statusColor(device.displayStatus).opacity(0.12))
            .cornerRadius(20)

            // Motif du statut (pourquoi warning / non conforme / obsolète)
            if let reason = device.statusReason {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundColor(statusColor(device.displayStatus))
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(statusColor(device.displayStatus))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor(device.displayStatus).opacity(0.08))
                .cornerRadius(10)
                .padding(.horizontal, 24)
            }

            // Device icon
            Image(systemName: deviceIcon(for: device.operatingSystem))
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            // Device name
            Text(device.deviceName)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            // Model & OS
            Text("\(device.manufacturer) \(device.model)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\(device.operatingSystem) \(device.osVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Type de jointure Azure AD (discret) — hybride vs 100% Intune.
            // Masqué tant que l'info n'est pas déterminée.
            if let joinType = viewModel.joinType, joinType != .unknown {
                HStack(spacing: 4) {
                    Image(systemName: joinType.icon)
                        .font(.caption2)
                    Text(joinType.label)
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(4)
            }

            readOnlyIndicator
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Info Sections

    private func deviceInfoSections(_ device: Device) -> some View {
        VStack(spacing: 16) {
            // Doublons de numéro de série (si présents)
            if !viewModel.serialDuplicates.isEmpty {
                serialDuplicatesBanner(device)
            }

            // Anomalies (si présentes)
            if !anomalies.isEmpty {
                anomaliesBanner
            }

            // Identité
            infoSection("Identité", icon: "tag.fill") {
                infoRow("Nom", value: device.deviceName)
                infoRow("Numéro de série", value: device.serialNumber)
                infoRow("Azure AD ID", value: device.azureADDeviceId)
                infoRow("ID Intune", value: device.id)
            }

            // Utilisateur assigné
            infoSection("Utilisateur", icon: "person.fill") {
                infoRow("Nom", value: device.userDisplayName)
                infoRow("Email", value: device.userPrincipalName)
                infoRow("Type", value: device.managedDeviceOwnerType)

                if let user = viewModel.assignedUser {
                    infoRow("Poste", value: user.jobTitle)
                    infoRow("Département", value: user.department)
                    infoRow("Bureau", value: user.officeLocation)
                }
            }

            // Conformité & Statut
            infoSection("Conformité", icon: "shield.fill") {
                HStack {
                    Text("État")
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: device.isCompliant ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundColor(device.isCompliant ? .green : .red)
                        Text(device.complianceState)
                            .fontWeight(.medium)
                    }
                }
                infoRow("Enregistrement", value: device.deviceRegistrationState)
                infoRow("Agent", value: device.managementAgent)
                infoRow("Catégorie", value: device.deviceCategoryDisplayName)
            }

            // Clés de récupération BitLocker (à la demande)
            bitlockerSection

            // Dates
            infoSection("Activité", icon: "clock.fill") {
                infoRow("Dernière sync", value: viewModel.lastSyncFormatted)
                infoRow("Inscrit le", value: viewModel.enrolledDateFormatted)
                if device.daysSinceLastSync >= 0 {
                    infoRow("Jours depuis sync", value: "\(device.daysSinceLastSync) jours")
                }
            }

            // Stockage
            if device.totalStorageSpaceInBytes > 0 {
                infoSection("Stockage", icon: "internaldrive.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Utilisation")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f%%", device.storageUsedPercent))
                                .fontWeight(.medium)
                        }
                        ProgressView(value: device.storageUsedPercent, total: 100)
                            .tint(storageBarColor(device.storageUsedPercent))
                        Text(device.storageUsedFormatted)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Notes
            if !device.notes.isEmpty {
                infoSection("Notes", icon: "note.text") {
                    Text(device.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - Doublons de numéro de série

    private func serialDuplicatesBanner(_ device: Device) -> some View {
        let dups = viewModel.serialDuplicates
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Doublon de numéro de série")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
            }
            .padding(.bottom, 2)

            Text("Le n° de série « \(device.serialNumber) » est aussi porté par \(dups.count) autre(s) appareil(s) :")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(dups) { dup in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: deviceIcon(for: dup.operatingSystem))
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Text(dup.deviceName.isEmpty ? "(Sans nom)" : dup.deviceName)
                                .font(.callout)
                                .fontWeight(.medium)
                        }
                        let owner = dup.userDisplayName.isEmpty ? "Non assigné" : dup.userDisplayName
                        Text("\(owner) · \(dup.operatingSystem) · sync il y a \(dup.daysSinceLastSync >= 0 ? "\(dup.daysSinceLastSync) j" : "—")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Anomalies banner

    private var anomaliesBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Anomalies détectées")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(anomalies) { anomaly in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: anomaly.kind.icon)
                            .font(.caption)
                            .foregroundStyle(severityColor(anomaly.severity))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(anomaly.kind.title)
                                .font(.callout)
                                .fontWeight(.medium)
                            Text(anomaly.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private func severityColor(_ severity: AnomalySeverity) -> Color {
        switch severity {
        case .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        }
    }

    // MARK: - BitLocker section

    private var bitlockerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Clés BitLocker")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
            }
            .padding(.bottom, 2)

            if viewModel.isLoadingBitLocker {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Récupération des clés…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !viewModel.bitlockerLoaded {
                // État initial : bouton de récupération (chargement explicite, opération auditée)
                Button {
                    Task { await viewModel.loadBitLockerKeys() }
                } label: {
                    HStack {
                        Image(systemName: "key.horizontal")
                        Text("Récupérer les clés BitLocker")
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .cornerRadius(8)
                }
            } else if let error = viewModel.bitlockerError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                retryBitLockerButton
            } else if viewModel.bitlockerKeys.isEmpty {
                Text("Aucune clé BitLocker associée à cet appareil.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                retryBitLockerButton
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.bitlockerKeys) { key in
                        bitlockerKeyRow(key)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var retryBitLockerButton: some View {
        Button {
            Task { await viewModel.loadBitLockerKeys() }
        } label: {
            Label("Réessayer", systemImage: "arrow.clockwise")
                .font(.subheadline)
        }
        .padding(.top, 4)
    }

    private func bitlockerKeyRow(_ key: BitLockerKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key.volumeTypeLabel)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(key.createdDateFormatted)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Key ID — identifiant de la clé (correspond à celui affiché sur
            // l'écran de récupération BitLocker de Windows). Utile pour distinguer
            // plusieurs clés enregistrées pour un même poste.
            HStack(spacing: 6) {
                Text("Key ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(key.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    UIPasteboard.general.string = key.id
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
            }

            if let value = key.key, !value.isEmpty {
                // Affichage seul : la clé de déblocage ne doit pas pouvoir être copiée
                // (pas de bouton de copie ni de sélection de texte).
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(6)
            } else {
                Text("Valeur indisponible")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground).opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Section builder

    private func infoSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
            }
            .padding(.bottom, 2)

            VStack(spacing: 8) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.subheadline)
    }

    // MARK: - Read-only indicator

    private var readOnlyIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption2)
            Text("Lecture seule Intune")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(4)
    }

    // MARK: - Helpers

    private func statusColor(_ status: DeviceStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .warning: return .orange
        case .stale: return .gray
        case .nonCompliant: return .red
        }
    }

    private func deviceIcon(for os: String) -> String {
        let osLower = os.lowercased()
        if osLower.contains("ios") || osLower.contains("iphone") { return "iphone" }
        if osLower.contains("ipad") { return "ipad" }
        if osLower.contains("mac") { return "laptopcomputer" }
        if osLower.contains("android") { return "smartphone" }
        if osLower.contains("windows") { return "desktopcomputer" }
        return "display"
    }

    private func storageBarColor(_ percent: Double) -> Color {
        if percent > 90 { return .red }
        if percent > 75 { return .orange }
        return .blue
    }
}
