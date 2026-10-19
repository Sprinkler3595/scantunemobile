import SwiftUI

/// Écran de configuration du tenant Microsoft Entra ID auquel se connecter.
/// Accessible uniquement depuis l'écran de connexion (hors session).
struct TenantSettingsView: View {
    @EnvironmentObject var authService: AuthService

    @Environment(\.dismiss) private var dismiss

    // Formulaire local (validé puis commité à l'enregistrement).
    @State private var tenantId: String = ""
    @State private var clientId: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ID ou domaine du tenant", text: $tenantId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                    if !tenantId.isEmpty && !TenantConfiguration.isValidTenantId(tenantId) {
                        validationMessage("Saisir un GUID ou un domaine (ex : contoso.onmicrosoft.com).")
                    }
                } header: {
                    Text("Tenant")
                } footer: {
                    Text("ID du tenant (GUID) ou domaine vérifié, visible dans le portail Entra ID › Vue d'ensemble.")
                }

                Section {
                    TextField("Client ID", text: $clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    if !clientId.isEmpty && !TenantConfiguration.isValidClientId(clientId) {
                        validationMessage("Le Client ID doit être un GUID.")
                    }
                } header: {
                    Text("App Registration")
                } footer: {
                    Text("L'App Registration doit déclarer le redirect URI \(TenantConfiguration.redirectUri) et disposer des permissions Graph avec consentement admin dans ce tenant.")
                }

                Section {
                    Button("Restaurer les valeurs par défaut") {
                        tenantId = TenantConfiguration.defaults.tenantId
                        clientId = TenantConfiguration.defaults.clientId
                    }
                    .disabled(draft.isDefault)
                }
            }
            .navigationTitle("Tenant de connexion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Enregistrer") {
                        authService.updateTenantConfiguration(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!draft.isValid)
                }
            }
            .onAppear {
                tenantId = authService.tenantConfiguration.tenantId
                clientId = authService.tenantConfiguration.clientId
            }
        }
    }

    private var draft: TenantConfiguration {
        TenantConfiguration(tenantId: tenantId, clientId: clientId).normalized
    }

    private func validationMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}
