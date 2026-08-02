import SwiftUI

/// Sheet de sélection d'une entreprise parmi celles dérivées des utilisateurs
/// Entra ID déjà chargés. Utilisée depuis `InventoryScanFormView` pour
/// attribuer manuellement un device originellement "Non assigné".
///
/// Si l'utilisateur courant (`userSelection`) appartient à une entreprise
/// différente de celle choisie, il est remis à `nil` pour préserver
/// l'invariant "l'utilisateur sélectionné appartient à l'entreprise
/// sélectionnée".
struct CompanyPickerView: View {
    @ObservedObject var viewModel: InventoryViewModel
    @Binding var selection: String?
    @Binding var userSelection: User?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredCompanies: [String] {
        let all = viewModel.allCompanies
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredCompanies.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "building.2")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Aucune entreprise")
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
                    ForEach(filteredCompanies, id: \.self) { company in
                        Button {
                            select(company)
                        } label: {
                            HStack {
                                Image(systemName: "building.2")
                                    .foregroundStyle(.blue)
                                    .frame(width: 28)
                                Text(company)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selection == company {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Rechercher une entreprise")
            .navigationTitle("Entreprise")
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
            return "Aucune entreprise ne correspond à « \(query) »."
        }
        return "Aucune entreprise disponible."
    }

    private func select(_ company: String) {
        // Invalide l'utilisateur si celui-ci n'appartient plus à la nouvelle
        // entreprise — on maintient ainsi l'invariant "user.company == selection".
        if let user = userSelection {
            let userCompany = user.companyName.trimmingCharacters(in: .whitespaces)
            if userCompany.caseInsensitiveCompare(company) != .orderedSame {
                userSelection = nil
            }
        }
        selection = company
        dismiss()
    }
}
