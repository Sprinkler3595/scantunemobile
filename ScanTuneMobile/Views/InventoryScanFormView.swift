import SwiftUI

/// Formulaire de validation d'un scan : résumé device + sélecteur de statut + note + bouton Valider.
struct InventoryScanFormView: View {
    @ObservedObject var viewModel: InventoryViewModel
    let device: Device

    @Environment(\.dismiss) private var dismiss

    @State private var selectedStatus: InventoryStatus = .trouve
    @State private var note: String = ""

    // Attribution manuelle (affichée uniquement si le device est "Non assigné").
    @State private var selectedAssignedCompany: String? = nil
    @State private var selectedAssignedUser: User? = nil
    @State private var showCompanyPicker = false
    @State private var showUserPicker = false

    // Détection d'un device déjà vérifié (le nouveau scan sera ajouté en plus, append-only).
    private var existingRecord: InventoryRecord? {
        viewModel.latestRecord(forDevice: device.id)
    }

    // Autres appareils du parc partageant le même numéro de série (doublons).
    private var serialDuplicates: [Device] {
        viewModel.serialDuplicates(for: device)
    }

    private var isUnassigned: Bool {
        viewModel.isUnassigned(device)
    }

    /// Note obligatoire si : statut "Autre", OU attribution unassigned
    /// saisie sans utilisateur précis (le tech doit justifier pourquoi il
    /// ne connaît pas le propriétaire exact).
    private var isNoteMandatory: Bool {
        if selectedStatus == .autre { return true }
        if isUnassigned && selectedAssignedCompany != nil && selectedAssignedUser == nil {
            return true
        }
        return false
    }

    private var isValidationEnabled: Bool {
        // Pour un device unassigned : l'entreprise doit être choisie.
        if isUnassigned && selectedAssignedCompany == nil {
            return false
        }
        // Note obligatoire selon les règles ci-dessus.
        if isNoteMandatory && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                if !serialDuplicates.isEmpty {
                    serialDuplicatesSection
                }
                if let existing = existingRecord {
                    alreadyCheckedSection(existing)
                }
                if isUnassigned {
                    attributionSection
                }
                statusSection
                noteSection
            }
            .navigationTitle("Vérification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Valider") { submit() }
                        .fontWeight(.semibold)
                        .disabled(!isValidationEnabled)
                }
            }
            .sheet(isPresented: $showCompanyPicker) {
                CompanyPickerView(
                    viewModel: viewModel,
                    selection: $selectedAssignedCompany,
                    userSelection: $selectedAssignedUser
                )
            }
            .sheet(isPresented: $showUserPicker) {
                UserPickerView(
                    viewModel: viewModel,
                    company: selectedAssignedCompany,
                    selection: $selectedAssignedUser
                )
            }
            .onChange(of: selectedAssignedUser) { newValue in
                // Quand un user est choisi, on aligne l'entreprise sur la
                // sienne — elle fait foi.
                if let user = newValue {
                    let userCompany = user.companyName.trimmingCharacters(in: .whitespaces)
                    if !userCompany.isEmpty {
                        selectedAssignedCompany = userCompany
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        Section("Appareil scanné") {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.deviceName)
                        .font(.headline)
                    if !device.serialNumber.isEmpty {
                        Text("N° série : \(device.serialNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !device.userDisplayName.isEmpty {
                        Text(device.userDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Entreprise : \(viewModel.companyName(for: device))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var serialDuplicatesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Doublon de numéro de série", systemImage: "doc.on.doc.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline).fontWeight(.semibold)
                Text("Le n° « \(device.serialNumber) » est aussi porté par \(serialDuplicates.count) autre(s) appareil(s) :")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(serialDuplicates) { dup in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dup.deviceName.isEmpty ? "(Sans nom)" : dup.deviceName)
                            .font(.callout).fontWeight(.medium)
                        Text("\(dup.userDisplayName.isEmpty ? "Non assigné" : dup.userDisplayName) · \(dup.operatingSystem)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Vérifiez que vous scannez le bon appareil avant de valider.")
        }
    }

    private func alreadyCheckedSection(_ existing: InventoryRecord) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Déjà vérifié", systemImage: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline).fontWeight(.semibold)
                Text("Statut : \(existing.status.rawValue)")
                    .font(.caption)
                Text("Par \(existing.checkedByName) le \(existing.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Votre nouvelle vérification s'ajoutera (append-only).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            .padding(.vertical, 4)
        }
    }

    private var attributionSection: some View {
        Section {
            // Row entreprise — obligatoire.
            Button {
                showCompanyPicker = true
            } label: {
                HStack {
                    Image(systemName: "building.2")
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Entreprise")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if let company = selectedAssignedCompany {
                            Text(company)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Sélectionner…")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Row utilisateur — optionnelle, désactivée tant que
            // l'entreprise n'est pas choisie.
            Button {
                showUserPicker = true
            } label: {
                HStack {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(selectedAssignedCompany == nil ? .gray : .blue)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Utilisateur (optionnel)")
                            .font(.subheadline)
                            .foregroundStyle(selectedAssignedCompany == nil ? .secondary : .primary)
                        if let user = selectedAssignedUser {
                            Text(user.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(selectedAssignedCompany == nil
                                 ? "Choisir d'abord l'entreprise"
                                 : "Non spécifié")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(selectedAssignedCompany == nil)
        } header: {
            Text("Attribution (obligatoire)")
        } footer: {
            Text("Cet appareil n'a pas d'utilisateur dans Intune. Sélectionnez au moins l'entreprise. Si vous ne précisez pas l'utilisateur, une note sera obligatoire.")
        }
    }

    private var statusSection: some View {
        Section("Statut") {
            ForEach(InventoryStatus.allCases, id: \.self) { status in
                Button {
                    selectedStatus = status
                } label: {
                    HStack {
                        Image(systemName: status.icon)
                            .foregroundStyle(color(for: status))
                            .frame(width: 28)
                        Text(status.rawValue)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedStatus == status {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }

    private var noteSection: some View {
        Section {
            TextField(
                isNoteMandatory ? "Précisez (obligatoire)" : "Note (optionnelle)",
                text: $note,
                axis: .vertical
            )
            .lineLimit(3...6)
        } header: {
            Text("Note")
        } footer: {
            if selectedStatus == .autre {
                Text("La note est obligatoire pour le statut « Autre ».")
                    .foregroundStyle(.orange)
            } else if isUnassigned && selectedAssignedCompany != nil && selectedAssignedUser == nil {
                Text("La note est obligatoire car aucun utilisateur précis n'a été sélectionné.")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        viewModel.submitCheck(
            device: device,
            status: selectedStatus,
            note: note,
            assignedCompany: selectedAssignedCompany,
            assignedUser: selectedAssignedUser
        )
        // Feedback haptique.
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        dismiss()
    }

    private func color(for status: InventoryStatus) -> Color {
        switch status {
        case .trouve: return .green
        case .endommage: return .orange
        case .autre: return .purple
        }
    }
}
