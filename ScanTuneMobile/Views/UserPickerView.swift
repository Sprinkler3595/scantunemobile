import SwiftUI

/// Sheet de sélection d'un utilisateur Entra ID, optionnellement filtré
/// par entreprise. Utilisée depuis `InventoryScanFormView` pour préciser
/// le propriétaire d'un device originellement "Non assigné".
///
/// Le filtrage par `company` garde la liste pertinente — on n'affiche pas
/// tout l'annuaire quand on sait déjà à quelle entreprise rattacher le
/// device.
struct UserPickerView: View {
    @ObservedObject var viewModel: InventoryViewModel
    let company: String?
    @Binding var selection: User?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredUsers: [User] {
        let base = viewModel.users(inCompany: company)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.userPrincipalName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredUsers.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Aucun utilisateur")
                                .font(.headline)
                            Text(emptyDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    ForEach(filteredUsers) { user in
                        Button {
                            selection = user
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if !user.userPrincipalName.isEmpty {
                                        Text(user.userPrincipalName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selection?.id == user.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .fontWeight(.semibold)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Rechercher un utilisateur")
            .navigationTitle("Utilisateur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    private var emptyDescription: String {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            return "Aucun utilisateur ne correspond à « \(query) »."
        }
        if let company = company, !company.isEmpty {
            return "Aucun utilisateur actif trouvé pour « \(company) »."
        }
        return "Aucun utilisateur actif chargé."
    }
}
