import SwiftUI

/// Emplacement SharePoint choisi dans le sélecteur, renvoyé à l'appelant.
/// `driveId`/`itemId`/`parentItemId` peuvent être nil (saisie manuelle / nouveau fichier).
struct PickedSharePointLocation {
    let siteWebUrl: String
    let libraryName: String
    let fileName: String
    let driveId: String?
    /// Fichier existant résolu (sélection directe). nil = fichier à créer.
    let itemId: String?
    /// Dossier parent où créer le fichier si `itemId` est nil. nil = racine de la bibliothèque.
    let parentItemId: String?
}

/// Sélecteur visuel de l'emplacement SharePoint. Deux modes :
///  - **Partagés avec moi** : liste directe des dossiers/fichiers partagés avec le technicien
///    (`/me/drive/sharedWithMe`), navigation dans les sous-dossiers, sélection du `.json`.
///  - **Sites** : navigation site → bibliothèque → fichier.
///
/// Dans les deux cas on renvoie via `onPick` le couple résolu (driveId, itemId) en plus des
/// libellés d'affichage, pour que le service accède directement à l'item (y compris en sous-dossier).
struct SharePointBrowserView: View {
    let sharePointService: SharePointInventoryService
    /// Nom proposé par défaut pour un nouveau fichier (ex: `inventaire-2026.json`).
    let defaultFileName: String
    /// Rappelée à la sélection finale puis la feuille se ferme.
    let onPick: (PickedSharePointLocation) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case shared = "Partagés avec moi"
        case sites = "Sites"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .shared

    /// Item partagé en cours de finalisation (résolution du nom de bibliothèque).
    @State private var finishingItem: SharePointSharedItem?
    @State private var finishError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch mode {
                case .shared:
                    SharedListView(
                        sharePointService: sharePointService,
                        onPickFile: { finish($0) }
                    )
                case .sites:
                    SitesListView(
                        sharePointService: sharePointService,
                        defaultFileName: defaultFileName,
                        onPick: complete
                    )
                }
            }
            .navigationTitle("Choisir un emplacement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Annuler") { dismiss() }
                }
            }
            .overlay { if finishingItem != nil { finishingOverlay } }
            .alert("Erreur", isPresented: Binding(
                get: { finishError != nil },
                set: { if !$0 { finishError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(finishError ?? "")
            }
        }
    }

    private var finishingOverlay: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            ProgressView("Résolution…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func complete(_ location: PickedSharePointLocation) {
        onPick(location)
        dismiss()
    }

    /// Finalise une sélection « Partagés avec moi » : on résout le nom de la bibliothèque
    /// (et son URL) pour remplir les champs d'affichage, puis on renvoie le pointeur direct.
    private func finish(_ item: SharePointSharedItem) {
        finishingItem = item
        Task {
            defer { finishingItem = nil }
            do {
                let info = try await sharePointService.driveInfo(driveId: item.driveId)
                complete(PickedSharePointLocation(
                    siteWebUrl: info.webUrl,
                    libraryName: info.name,
                    fileName: item.name,
                    driveId: item.driveId,
                    itemId: item.id,
                    parentItemId: nil
                ))
            } catch {
                finishError = error.localizedDescription
            }
        }
    }
}

// MARK: - Mode « Partagés avec moi »

private struct SharedListView: View {
    let sharePointService: SharePointInventoryService
    let onPickFile: (SharePointSharedItem) -> Void

    @State private var items: [SharePointSharedItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                LoadingRow()
            } else if let errorMessage {
                ErrorRow(message: errorMessage)
            } else if items.isEmpty {
                EmptyRow(
                    icon: "person.2",
                    title: "Aucun partage",
                    message: "Rien ne vous a été partagé, ou aucun fichier .json. Essayez l'onglet « Sites »."
                )
            } else {
                ForEach(items) { item in
                    SharedItemRow(
                        sharePointService: sharePointService,
                        item: item,
                        onPickFile: onPickFile
                    )
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await sharePointService.listSharedWithMe()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Contenu d'un sous-dossier parcouru depuis « Partagés avec moi ».
private struct SharedFolderView: View {
    let sharePointService: SharePointInventoryService
    let folder: SharePointSharedItem
    let onPickFile: (SharePointSharedItem) -> Void

    @State private var items: [SharePointSharedItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                LoadingRow()
            } else if let errorMessage {
                ErrorRow(message: errorMessage)
            } else if items.isEmpty {
                EmptyRow(
                    icon: "folder",
                    title: "Dossier vide",
                    message: "Aucun sous-dossier ni fichier .json ici."
                )
            } else {
                ForEach(items) { item in
                    SharedItemRow(
                        sharePointService: sharePointService,
                        item: item,
                        onPickFile: onPickFile
                    )
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await sharePointService.listChildren(driveId: folder.driveId, itemId: folder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Ligne d'un item partagé : dossier (navigable) ou fichier .json (sélectionnable).
private struct SharedItemRow: View {
    let sharePointService: SharePointInventoryService
    let item: SharePointSharedItem
    let onPickFile: (SharePointSharedItem) -> Void

    var body: some View {
        if item.isFolder {
            NavigationLink {
                SharedFolderView(
                    sharePointService: sharePointService,
                    folder: item,
                    onPickFile: onPickFile
                )
            } label: {
                Label(item.name, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
            }
        } else {
            Button {
                onPickFile(item)
            } label: {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.blue)
                        .frame(width: 28)
                    Text(item.name).foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - Mode « Sites » : Niveau 1 (sites)

private struct SitesListView: View {
    let sharePointService: SharePointInventoryService
    let defaultFileName: String
    let onPick: (PickedSharePointLocation) -> Void

    @State private var followed: [SharePointSiteInfo] = []
    @State private var memberSites: [SharePointSiteInfo] = []
    @State private var results: [SharePointSiteInfo] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isLoadingMembers = true
    @State private var errorMessage: String?
    @State private var memberError: String?

    // Ouvrir par URL
    @State private var showURLPrompt = false
    @State private var urlInput = ""
    @State private var isResolving = false
    @State private var urlError: String?
    @State private var resolvedSite: SharePointSiteInfo?
    @State private var navigateToResolved = false

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Sites suivis + sites des groupes M365, dédupliqués par id et triés par nom.
    private var combinedSites: [SharePointSiteInfo] {
        var seen = Set<String>()
        var out: [SharePointSiteInfo] = []
        for site in followed + memberSites where seen.insert(site.id).inserted {
            out.append(site)
        }
        return out.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var displayedSites: [SharePointSiteInfo] {
        isSearching ? results : combinedSites
    }

    /// Vrai tant qu'aucun site n'est encore disponible et qu'un chargement est en cours.
    private var isInitialLoading: Bool {
        !isSearching && combinedSites.isEmpty && (isLoading || isLoadingMembers)
    }

    var body: some View {
        List {
            Section {
                Button {
                    showURLPrompt = true
                } label: {
                    HStack {
                        Image(systemName: "link")
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        Text("Ouvrir par URL…").foregroundStyle(.primary)
                    }
                }
            } footer: {
                Text("Collez l'URL d'un site auquel vous avez accès mais qui n'apparaît ni dans les sites suivis ni dans la recherche.")
            }

            if isInitialLoading {
                LoadingRow()
            } else if let errorMessage, displayedSites.isEmpty {
                ErrorRow(message: errorMessage)
            } else if displayedSites.isEmpty {
                EmptyRow(
                    icon: "globe",
                    title: "Aucun site",
                    message: isSearching
                        ? "Aucun site ne correspond à « \(searchText.trimmingCharacters(in: .whitespaces)) »."
                        : "Aucun site trouvé. Utilisez la recherche ou « Ouvrir par URL… »."
                )
            } else {
                Section {
                    ForEach(displayedSites) { site in
                        NavigationLink {
                            LibrariesListView(
                                sharePointService: sharePointService,
                                site: site,
                                defaultFileName: defaultFileName,
                                onPick: onPick
                            )
                            .navigationTitle("Bibliothèque")
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            row(icon: "globe", title: site.displayName, subtitle: site.webUrl)
                        }
                    }
                    // Indicateur discret pendant le chargement des sites membres.
                    if !isSearching && isLoadingMembers {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Recherche de vos sites d'équipe…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(isSearching ? "Résultats de recherche" : "Mes sites")
                } footer: {
                    if !isSearching, let memberError {
                        Text(memberError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Rechercher un site SharePoint")
        .task { await loadFollowed() }
        .task { await loadMembers() }
        .task(id: searchText) { await runSearch() }
        .navigationDestination(isPresented: $navigateToResolved) {
            if let resolvedSite {
                LibrariesListView(
                    sharePointService: sharePointService,
                    site: resolvedSite,
                    defaultFileName: defaultFileName,
                    onPick: onPick
                )
                .navigationTitle("Bibliothèque")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert("Ouvrir par URL", isPresented: $showURLPrompt) {
            TextField("https://contoso.sharepoint.com/sites/IT", text: $urlInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Ouvrir") { Task { await resolveAndGo() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Collez l'URL complète du site SharePoint.")
        }
        .alert("Site introuvable", isPresented: Binding(
            get: { urlError != nil },
            set: { if !$0 { urlError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(urlError ?? "")
        }
        .overlay {
            if isResolving {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView("Ouverture…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func resolveAndGo() async {
        let input = urlInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            let site = try await sharePointService.resolveSite(urlString: input)
            resolvedSite = site
            navigateToResolved = true
        } catch {
            urlError = error.localizedDescription
        }
    }

    private func row(icon: String, title: String, subtitle: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func loadFollowed() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            followed = try await sharePointService.listFollowedSites()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMembers() async {
        isLoadingMembers = true
        memberError = nil
        defer { isLoadingMembers = false }
        do {
            memberSites = try await sharePointService.listMemberSites()
        } catch {
            // Non bloquant : on affiche quand même les sites suivis.
            memberError = error.localizedDescription
        }
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            results = []
            return
        }
        // Petit debounce : laisse l'utilisateur finir de taper.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        do {
            let found = try await sharePointService.searchSites(query: query)
            if !Task.isCancelled { results = found }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Mode « Sites » : Niveau 2 (bibliothèques)

private struct LibrariesListView: View {
    let sharePointService: SharePointInventoryService
    let site: SharePointSiteInfo
    let defaultFileName: String
    let onPick: (PickedSharePointLocation) -> Void

    @State private var libraries: [SharePointLibraryInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                LoadingRow()
            } else if let errorMessage {
                ErrorRow(message: errorMessage)
            } else if libraries.isEmpty {
                EmptyRow(
                    icon: "folder",
                    title: "Aucune bibliothèque",
                    message: "Ce site ne contient aucune bibliothèque de documents."
                )
            } else {
                Section {
                    ForEach(libraries) { library in
                        NavigationLink {
                            LibraryBrowserView(
                                sharePointService: sharePointService,
                                site: site,
                                library: library,
                                folder: nil,
                                defaultFileName: defaultFileName,
                                onPick: onPick
                            )
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                    .frame(width: 28)
                                Text(library.name).foregroundStyle(.primary)
                            }
                        }
                    }
                } header: {
                    Text(site.displayName)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            libraries = try await sharePointService.listLibraries(siteId: site.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Mode « Sites » : Niveau 3 (dossiers + fichiers, navigable)

/// Explorateur d'une bibliothèque : affiche les dossiers (navigables) et les fichiers `.json`.
/// `folder == nil` = racine de la bibliothèque ; sinon contenu du sous-dossier.
private struct LibraryBrowserView: View {
    let sharePointService: SharePointInventoryService
    let site: SharePointSiteInfo
    let library: SharePointLibraryInfo
    /// Sous-dossier courant. nil = racine de la bibliothèque.
    let folder: SharePointSharedItem?
    let defaultFileName: String
    let onPick: (PickedSharePointLocation) -> Void

    @State private var items: [SharePointSharedItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var newFileName = ""

    private var title: String { folder?.name ?? library.name }

    var body: some View {
        List {
            // Section "Nouveau fichier" : créé dans le dossier courant.
            Section {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(.green)
                        .frame(width: 28)
                    TextField(defaultFileName, text: $newFileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(pickNewFile)
                }
                Button(action: pickNewFile) {
                    Label("Créer ici ce nouveau fichier", systemImage: "checkmark.circle.fill")
                }
            } header: {
                Text("Nouveau fichier")
            } footer: {
                Text("Sera créé dans « \(title) » au premier envoi s'il n'existe pas encore.")
            }

            // Section contenu : dossiers + fichiers .json.
            Section {
                if isLoading {
                    LoadingRow()
                } else if let errorMessage {
                    ErrorRow(message: errorMessage)
                } else if items.isEmpty {
                    EmptyRow(
                        icon: "folder",
                        title: "Vide",
                        message: "Aucun dossier ni fichier .json ici. Créez-en un ci-dessus."
                    )
                } else {
                    ForEach(items) { item in
                        if item.isFolder {
                            NavigationLink {
                                LibraryBrowserView(
                                    sharePointService: sharePointService,
                                    site: site,
                                    library: library,
                                    folder: item,
                                    defaultFileName: defaultFileName,
                                    onPick: onPick
                                )
                            } label: {
                                Label(item.name, systemImage: "folder.fill")
                                    .foregroundStyle(.primary)
                            }
                        } else {
                            Button {
                                onPick(PickedSharePointLocation(
                                    siteWebUrl: site.webUrl,
                                    libraryName: library.name,
                                    fileName: item.name,
                                    driveId: library.id,
                                    itemId: item.id,
                                    parentItemId: nil
                                ))
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                        .foregroundStyle(.blue)
                                        .frame(width: 28)
                                    Text(item.name).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Contenu")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if newFileName.isEmpty { newFileName = defaultFileName }
            await load()
        }
    }

    private func pickNewFile() {
        var name = newFileName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = defaultFileName }
        if !name.lowercased().hasSuffix(".json") { name += ".json" }
        // Nouveau fichier : pas d'itemId (sera créé). parentItemId = dossier courant (nil à la racine).
        onPick(PickedSharePointLocation(
            siteWebUrl: site.webUrl,
            libraryName: library.name,
            fileName: name,
            driveId: library.id,
            itemId: nil,
            parentItemId: folder?.id
        ))
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            if let folder {
                items = try await sharePointService.listChildren(driveId: library.id, itemId: folder.id)
            } else {
                items = try await sharePointService.listRootItems(driveId: library.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Lignes réutilisables

private struct LoadingRow: View {
    var body: some View {
        HStack {
            ProgressView()
            Text("Chargement…").foregroundStyle(.secondary)
        }
    }
}

private struct ErrorRow: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
    }
}

private struct EmptyRow: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
