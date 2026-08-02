import SwiftUI

/// Écran de réglages de l'inventaire : configuration SharePoint + périmètre d'appareils.
struct InventorySettingsView: View {
    @ObservedObject var settingsStore: InventorySettingsStore
    let sharePointService: SharePointInventoryService
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Formulaire local (validé puis commité à la sauvegarde).
    @State private var siteUrl: String = ""
    @State private var libraryName: String = ""
    @State private var fileName: String = ""
    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var activeScopes: Set<DeviceScope> = [.windows, .macOS]

    // Test de connexion
    @State private var isTesting = false
    @State private var testResult: TestResult?

    // Diagnostic
    @State private var showDiagnostic = false

    // Sélecteur d'emplacement SharePoint
    @State private var showBrowser = false
    // Affiche les champs de saisie manuelle (URL / bibliothèque / fichier). Repliés
    // par défaut quand un emplacement a déjà été sélectionné.
    @State private var showManualFields = false
    // Pointeur direct résolu par le sélecteur (driveId/itemId). Invalidé dès que
    // l'utilisateur modifie à la main l'un des champs site/bibliothèque/fichier.
    @State private var pickedDriveId: String?
    @State private var pickedItemId: String?
    @State private var pickedParentItemId: String?
    /// Empreinte des champs au moment de la sélection — sert à détecter une édition manuelle.
    @State private var pointerSnapshot: String?

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                sharePointSection
                deviceScopeSection
                testSection
                diagnosticSection
            }
            .navigationTitle("Réglages inventaire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Enregistrer") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isFormValid)
                }
            }
            .onAppear(perform: loadFromStore)
            .sheet(isPresented: $showDiagnostic) {
                DiagnosticLogView()
            }
            .sheet(isPresented: $showBrowser) {
                SharePointBrowserView(
                    sharePointService: sharePointService,
                    defaultFileName: "inventaire-\(year).json",
                    onPick: { location in
                        siteUrl = location.siteWebUrl
                        libraryName = location.libraryName
                        fileName = location.fileName
                        pickedDriveId = location.driveId
                        pickedItemId = location.itemId
                        pickedParentItemId = location.parentItemId
                        // Empreinte des valeurs sélectionnées : si l'utilisateur édite
                        // ensuite un champ, le pointeur est ignoré (repli résolution par URL).
                        pointerSnapshot = "\(location.siteWebUrl)|\(location.libraryName)|\(location.fileName)"
                        testResult = nil
                    }
                )
            }
        }
    }

    // MARK: - Sections

    private var sharePointSection: some View {
        Section {
            Button {
                showBrowser = true
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    Text(hasSelection ? "Changer d'emplacement…" : "Parcourir SharePoint…")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Résumé compact de l'emplacement sélectionné (au lieu des 3 champs).
            if hasSelection {
                selectedLocationSummary
            }

            // Champs de saisie manuelle, repliés par défaut quand un emplacement existe.
            DisclosureGroup("Réglages manuels", isExpanded: $showManualFields) {
                TextField("https://contoso.sharepoint.com/sites/IT", text: $siteUrl)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Bibliothèque (ex: Documents)", text: $libraryName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("inventaire-\(year).json", text: $fileName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Stepper(value: $year, in: 2020...2100) {
                HStack {
                    Text("Année d'inventaire")
                    Spacer()
                    Text(String(year)).foregroundStyle(.secondary)
                }
            }
            .onChange(of: year) { newYear in
                // Si l'utilisateur n'a pas customisé le nom de fichier, le synchroniser.
                if fileName.hasPrefix("inventaire-") {
                    fileName = "inventaire-\(newYear).json"
                }
            }
        } header: {
            Text("Fichier SharePoint centralisé")
        } footer: {
            Text("Ce fichier est partagé entre tous les techniciens du groupe. Append-only : aucune entrée ne sera jamais modifiée ni supprimée.")
        }
    }

    /// Carte de résumé de l'emplacement choisi : fichier + bibliothèque + site.
    private var selectedLocationSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text("\(libraryName) · \(siteDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var deviceScopeSection: some View {
        Section {
            ForEach(DeviceScope.allCases) { scope in
                Button {
                    toggle(scope)
                } label: {
                    HStack {
                        Image(systemName: scope.icon)
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        Text(scope.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if activeScopes.contains(scope) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        } header: {
            Text("Périmètre d'appareils")
        } footer: {
            Text("Seuls les appareils des types cochés seront comptabilisés dans l'inventaire.")
        }
    }

    private var diagnosticSection: some View {
        Section {
            Button {
                showDiagnostic = true
            } label: {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    Text("Journal de diagnostic")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Diagnostic")
        } footer: {
            Text("Consulter et exporter le journal applicatif (1000 dernières entrées). Utile pour diagnostiquer un problème terrain.")
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text("Tester la connexion")
                }
            }
            .disabled(isTesting || !isFormValid)

            if let result = testResult {
                switch result {
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - Form state

    private var isFormValid: Bool {
        !siteUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !libraryName.trimmingCharacters(in: .whitespaces).isEmpty
            && !fileName.trimmingCharacters(in: .whitespaces).isEmpty
            && !activeScopes.isEmpty
    }

    /// Vrai dès que les trois champs d'emplacement sont renseignés.
    private var hasSelection: Bool {
        !siteUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !libraryName.trimmingCharacters(in: .whitespaces).isEmpty
            && !fileName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Nom lisible du site dérivé de l'URL (dernier segment du chemin, sinon l'hôte).
    private var siteDisplayName: String {
        guard let comps = URLComponents(string: siteUrl.trimmingCharacters(in: .whitespaces)) else {
            return siteUrl
        }
        let lastPathSegment = comps.path
            .split(separator: "/")
            .last
            .map(String.init)
        return lastPathSegment ?? comps.host ?? siteUrl
    }

    /// Empreinte courante des champs site/bibliothèque/fichier.
    private var currentFieldsKey: String {
        "\(siteUrl)|\(libraryName)|\(fileName)"
    }

    /// Le pointeur direct n'est valable que si les champs n'ont pas été édités à la main
    /// depuis la sélection ; sinon on repasse en résolution par URL.
    private var pointerIsValid: Bool {
        pointerSnapshot != nil && pointerSnapshot == currentFieldsKey
    }
    private var effectiveDriveId: String? { pointerIsValid ? pickedDriveId : nil }
    private var effectiveItemId: String? { pointerIsValid ? pickedItemId : nil }
    private var effectiveParentItemId: String? { pointerIsValid ? pickedParentItemId : nil }

    private func loadFromStore() {
        let s = settingsStore.settings
        siteUrl = s.sharePointSiteUrl
        libraryName = s.documentLibraryName
        fileName = s.fileName
        year = s.inventoryYear
        activeScopes = s.activeScopes
        // Restaurer le pointeur direct persisté ; valable tant que les champs ne sont pas édités.
        pickedDriveId = s.driveId
        pickedItemId = s.itemId
        pickedParentItemId = s.parentItemId
        pointerSnapshot = (s.driveId != nil) ? "\(s.sharePointSiteUrl)|\(s.documentLibraryName)|\(s.fileName)" : nil
        // Replier les champs manuels si un emplacement est déjà configuré ; sinon les
        // afficher pour permettre une première saisie sans passer par le sélecteur.
        showManualFields = !hasSelection
    }

    private func toggle(_ scope: DeviceScope) {
        if activeScopes.contains(scope) {
            // Empêcher de tout décocher.
            if activeScopes.count > 1 {
                activeScopes.remove(scope)
            }
        } else {
            activeScopes.insert(scope)
        }
    }

    private func save() {
        let updated = InventorySettings(
            sharePointSiteUrl: siteUrl.trimmingCharacters(in: .whitespaces),
            documentLibraryName: libraryName.trimmingCharacters(in: .whitespaces),
            fileName: fileName.trimmingCharacters(in: .whitespaces),
            inventoryYear: year,
            activeScopes: activeScopes,
            driveId: effectiveDriveId,
            itemId: effectiveItemId,
            parentItemId: effectiveParentItemId
        )
        settingsStore.update(updated)
        sharePointService.invalidateCache()
        onSaved()
    }

    private func testConnection() async {
        // On pousse les valeurs du formulaire dans un `InventorySettings` temporaire
        // pour tester même si l'utilisateur n'a pas encore sauvegardé.
        let test = InventorySettings(
            sharePointSiteUrl: siteUrl.trimmingCharacters(in: .whitespaces),
            documentLibraryName: libraryName.trimmingCharacters(in: .whitespaces),
            fileName: fileName.trimmingCharacters(in: .whitespaces),
            inventoryYear: year,
            activeScopes: activeScopes,
            driveId: effectiveDriveId,
            itemId: effectiveItemId,
            parentItemId: effectiveParentItemId
        )
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        do {
            let message = try await sharePointService.testConnection(settings: test)
            testResult = .success(message)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}
