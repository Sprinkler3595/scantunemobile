import SwiftUI

/// Écran discret de bascule d'organisation Azure : permet de changer le
/// client ID (App Registration) et le tenant ID sans recompiler l'application,
/// par exemple lors d'un changement de client / d'organisation Entra ID.
///
/// Le changement déconnecte proprement la session en cours (le compte appartient
/// au tenant précédent) puis réinitialise MSAL sur la nouvelle organisation.
struct OrganizationConfigView: View {
    @ObservedObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var clientId: String = ""
    @State private var tenantId: String = ""
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                if isCustom {
                    resetSection
                }
            }
            .navigationTitle("Organisation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Enregistrer") { save() }
                        .fontWeight(.semibold)
                        .disabled(!isValid || !hasChanges)
                }
            }
            .onAppear {
                clientId = authService.organization.clientId
                tenantId = authService.organization.tenantId
            }
            .confirmationDialog(
                "Rétablir l'organisation par défaut ?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Rétablir", role: .destructive) {
                    clientId = OrganizationConfig.factoryDefault.clientId
                    tenantId = OrganizationConfig.factoryDefault.tenantId
                }
                Button("Annuler", role: .cancel) {}
            }
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            guidField(title: "Client ID", text: $clientId)
            guidField(title: "Tenant ID", text: $tenantId)
        } header: {
            Text("Identité Azure")
        } footer: {
            Text("Identifiants de l'App Registration et du tenant Entra ID. Ne les modifiez que pour basculer vers une autre organisation. L'enregistrement déconnecte la session en cours ; il faudra se reconnecter.")
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Rétablir l'organisation par défaut", systemImage: "arrow.uturn.backward")
            }
        }
    }

    /// Champ de saisie d'un GUID : monospace, sans autocorrection, avec puce de validation.
    private func guidField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    Image(systemName: OrganizationConfig.isGuid(text.wrappedValue) ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(OrganizationConfig.isGuid(text.wrappedValue) ? .green : .orange)
                }
            }
            TextField("00000000-0000-0000-0000-000000000000", text: text)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
        }
    }

    // MARK: - State

    private var trimmedConfig: OrganizationConfig {
        OrganizationConfig(
            clientId: clientId.trimmingCharacters(in: .whitespaces),
            tenantId: tenantId.trimmingCharacters(in: .whitespaces)
        )
    }
    private var isValid: Bool { trimmedConfig.isValid }
    private var hasChanges: Bool { trimmedConfig != authService.organization }
    private var isCustom: Bool { trimmedConfig.isCustom }

    // MARK: - Actions

    private func save() {
        let newConfig = trimmedConfig
        Task {
            await authService.updateOrganization(newConfig)
            dismiss()
        }
    }
}
