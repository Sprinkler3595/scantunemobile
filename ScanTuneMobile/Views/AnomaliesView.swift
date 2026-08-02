import SwiftUI

/// Écran dédié aux anomalies détectées sur le parc actif.
/// Regroupé par type, trié par sévérité. Tap sur une ligne → fiche détail device.
struct AnomaliesView: View {
    @ObservedObject var viewModel: InventoryViewModel

    @State private var selectedKindFilter: AnomalyKind?

    var body: some View {
        Group {
            if viewModel.anomalies.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle("Anomalies")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Aucune anomalie")
                .font(.title3).fontWeight(.semibold)
            Text("Aucun appareil du périmètre actif ne déclenche les règles de vérification.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        let grouped = Dictionary(grouping: filteredAnomalies, by: \.kind)
        let kinds = grouped.keys.sorted { $0.severity > $1.severity }

        return List {
            Section {
                summaryCard
                filterPicker
            }

            ForEach(kinds, id: \.self) { kind in
                Section {
                    ForEach(grouped[kind] ?? []) { anomaly in
                        anomalyRow(anomaly)
                    }
                } header: {
                    HStack {
                        Image(systemName: kind.icon)
                        Text(kind.title)
                        Spacer()
                        Text("\((grouped[kind] ?? []).count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var summaryCard: some View {
        let total = viewModel.anomalies.count
        let high = viewModel.anomalies.filter { $0.severity == .high }.count
        let medium = viewModel.anomalies.filter { $0.severity == .medium }.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(total) anomalie(s) détectée(s)")
                        .font(.headline)
                    Text("Sur \(viewModel.scopedDevices.count) appareils du périmètre")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                severityBadge(count: high, label: "Élevées", color: .red)
                severityBadge(count: medium, label: "Moyennes", color: .orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func severityBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var filterPicker: some View {
        Picker("Type", selection: $selectedKindFilter) {
            Text("Tous").tag(AnomalyKind?.none)
            ForEach(AnomalyKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(AnomalyKind?.some(kind))
            }
        }
    }

    private func anomalyRow(_ anomaly: DeviceAnomaly) -> some View {
        let device = viewModel.scopedDevices.first { $0.id == anomaly.deviceId }
        return NavigationLink {
            if let device {
                DeviceDetailView(
                    device: device,
                    graphService: viewModel.graphService,
                    anomalies: viewModel.anomalies(forDevice: device.id)
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device?.deviceName ?? anomaly.deviceId)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    severityDot(anomaly.severity)
                }
                Text(anomaly.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let device, !device.userDisplayName.isEmpty {
                    Text(device.userDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func severityDot(_ severity: AnomalySeverity) -> some View {
        let color: Color = {
            switch severity {
            case .high: return .red
            case .medium: return .orange
            case .low: return .yellow
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    // MARK: - Filter

    private var filteredAnomalies: [DeviceAnomaly] {
        guard let kind = selectedKindFilter else { return viewModel.anomalies }
        return viewModel.anomalies.filter { $0.kind == kind }
    }
}
