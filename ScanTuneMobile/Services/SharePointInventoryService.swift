import Foundation

// MARK: - Errors

enum SharePointInventoryError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case invalidSiteUrl
    case siteNotFound
    case libraryNotFound(String)
    case invalidResponse
    case fileTooLarge(bytes: Int)
    case conflictRetryExhausted
    case insufficientPermissions
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Réglages SharePoint incomplets. Ouvrez l'écran Réglages de l'inventaire."
        case .notAuthenticated:
            return "Non authentifié — impossible d'accéder à SharePoint."
        case .invalidSiteUrl:
            return "URL du site SharePoint invalide."
        case .siteNotFound:
            return "Site SharePoint introuvable. Vérifiez l'URL saisie."
        case .libraryNotFound(let name):
            return "Bibliothèque de documents « \(name) » introuvable sur ce site."
        case .invalidResponse:
            return "Réponse inattendue de Microsoft Graph."
        case .fileTooLarge(let bytes):
            let mb = Double(bytes) / 1_048_576
            return String(format: "Fichier d'inventaire trop volumineux (%.2f Mo, > 4 Mo). Contactez l'admin.", mb)
        case .conflictRetryExhausted:
            return "Trop de conflits de synchronisation consécutifs. Réessayez dans quelques secondes."
        case .insufficientPermissions:
            return "Permission insuffisante pour lister vos groupes. Un consentement administrateur peut être requis."
        case .httpError(let statusCode, let body):
            return "Erreur HTTP \(statusCode) : \(body)"
        }
    }
}

// MARK: - Browse Items

/// Site SharePoint listé lors de la navigation (sites suivis ou recherche).
struct SharePointSiteInfo: Identifiable, Hashable {
    let id: String          // Graph site id
    let displayName: String
    let webUrl: String      // URL complète -> InventorySettings.sharePointSiteUrl
}

/// Bibliothèque de documents (drive) d'un site.
struct SharePointLibraryInfo: Identifiable, Hashable {
    let id: String          // drive id
    let name: String        // -> InventorySettings.documentLibraryName
}

/// Fichier .json présent dans une bibliothèque.
struct SharePointFileInfo: Identifiable, Hashable {
    let id: String
    let name: String        // -> InventorySettings.fileName
}

/// Élément listé dans « Partagés avec moi » ou dans un dossier parcouru.
/// Porte le couple (driveId, id) nécessaire pour accéder directement à l'item.
struct SharePointSharedItem: Identifiable, Hashable {
    let id: String          // itemId
    let driveId: String
    let name: String
    let webUrl: String
    let isFolder: Bool
}

// MARK: - Resolved Target

/// Cache d'un fichier d'inventaire résolu sur SharePoint (site → drive → item).
private struct ResolvedTarget {
    let siteId: String
    let driveId: String
    /// nil tant que le fichier n'existe pas encore.
    var itemId: String?
    /// ETag du dernier GET réussi. nil si le fichier n'existe pas encore.
    var eTag: String?
}

// MARK: - Service

/// Accès en lecture / écriture au fichier JSON d'inventaire centralisé sur SharePoint.
///
/// Flux :
/// 1. `resolveTarget(settings:)` résout site → drive → (item, eTag) via Microsoft Graph.
/// 2. `downloadFile(settings:)` récupère le contenu courant + eTag.
/// 3. `upload(records:settings:)` fusionne les records entrants avec le fichier distant
///    et fait un PUT avec `If-Match` (ETag). Sur 412, re-GET et re-merge jusqu'à 5 fois.
///
/// Plafond simple upload Graph : 4 Mo. Au-delà il faudra migrer vers `createUploadSession`.
@MainActor
final class SharePointInventoryService {

    // MARK: - Constants

    private static let graphBaseURL = "https://graph.microsoft.com/v1.0"
    private static let maxUploadBytes = 4 * 1024 * 1024 // 4 MiB
    private static let maxConflictRetries = 5

    // MARK: - Dependencies

    private let authService: AuthService

    // MARK: - Cache

    /// Cache keyé par la combinaison (site URL + library + fileName) pour invalider si les réglages changent.
    private var cachedTarget: ResolvedTarget?
    private var cachedTargetKey: String?

    // MARK: - Init

    init(authService: AuthService) {
        self.authService = authService
    }

    // MARK: - Public API

    /// Invalide le cache de résolution. À appeler après modification des réglages.
    func invalidateCache() {
        cachedTarget = nil
        cachedTargetKey = nil
    }

    /// Teste la connexion : résout le site + la bibliothèque. Ne touche pas au fichier.
    /// Retourne un message descriptif en cas de succès.
    func testConnection(settings: InventorySettings) async throws -> String {
        guard settings.isConfigured else { throw SharePointInventoryError.notConfigured }
        let target = try await resolveTarget(settings: settings, forceRefresh: true)
        let fileState = target.itemId == nil ? "sera créé au 1er upload" : "déjà présent"
        return "Connexion OK. Fichier \"\(settings.fileName)\" : \(fileState)."
    }

    // MARK: - Public API: Navigation (sélecteur d'emplacement)

    /// Liste les sites SharePoint suivis par l'utilisateur (`GET /me/followedSites`).
    func listFollowedSites() async throws -> [SharePointSiteInfo] {
        let token = try await requireToken()
        let urlString = "\(Self.graphBaseURL)/me/followedSites"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }
        return try await fetchSiteList(url: url, token: token)
    }

    /// Recherche des sites par nom (`GET /sites?search={query}`).
    /// Retourne un tableau vide si la requête est vide.
    func searchSites(query: String) async throws -> [SharePointSiteInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let token = try await requireToken()
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let urlString = "\(Self.graphBaseURL)/sites?search=\(encoded)"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }
        return try await fetchSiteList(url: url, token: token)
    }

    /// Liste les sites des groupes Microsoft 365 dont l'utilisateur est membre.
    /// Étape 1 : `GET /me/memberOf` (groupes unifiés). Étape 2 : `GET /groups/{id}/sites/root`.
    /// Les groupes sans site (ou inaccessibles) sont ignorés silencieusement.
    func listMemberSites() async throws -> [SharePointSiteInfo] {
        let token = try await requireToken()

        // Étape 1 : groupes M365 (unifiés) de l'utilisateur.
        let urlString = "\(Self.graphBaseURL)/me/memberOf/microsoft.graph.group?$select=id,displayName,groupTypes&$top=999"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        if http.statusCode == 403 { throw SharePointInventoryError.insufficientPermissions }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["value"] as? [[String: Any]] else {
            throw SharePointInventoryError.invalidResponse
        }

        // Ne garder que les groupes unifiés (= dotés d'un site SharePoint).
        let groupIds: [String] = groups.compactMap { group in
            let types = (group["groupTypes"] as? [String]) ?? []
            guard types.contains(where: { $0.caseInsensitiveCompare("Unified") == .orderedSame }),
                  let id = group["id"] as? String else { return nil }
            return id
        }

        // Étape 2 : résoudre le site de chaque groupe en parallèle, en tolérant les échecs.
        var sites: [SharePointSiteInfo] = []
        await withTaskGroup(of: SharePointSiteInfo?.self) { taskGroup in
            for id in groupIds {
                taskGroup.addTask { await self.fetchGroupSite(groupId: id, token: token) }
            }
            for await site in taskGroup {
                if let site { sites.append(site) }
            }
        }

        // Dédupliquer par id et trier par nom.
        var seen = Set<String>()
        let unique = sites.filter { seen.insert($0.id).inserted }
        return unique.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Résout le site d'un groupe (`GET /groups/{id}/sites/root`). nil si absent/inaccessible.
    private func fetchGroupSite(groupId: String, token: String) async -> SharePointSiteInfo? {
        let urlString = "\(Self.graphBaseURL)/groups/\(groupId)/sites/root?$select=id,displayName,webUrl"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await authGet(url: url, token: token)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let webUrl = json["webUrl"] as? String else { return nil }
            let display = (json["displayName"] as? String) ?? (json["name"] as? String) ?? webUrl
            return SharePointSiteInfo(id: id, displayName: display, webUrl: webUrl)
        } catch {
            return nil
        }
    }

    /// Résout un site à partir de son URL collée (`GET /sites/{host}:{chemin}`).
    /// Contourne les limites du suivi et de la recherche : atteint tout site accessible.
    func resolveSite(urlString: String) async throws -> SharePointSiteInfo {
        var raw = urlString.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw SharePointInventoryError.invalidSiteUrl }
        // Tolérer une URL sans schéma (ex: "contoso.sharepoint.com/sites/IT").
        if !raw.contains("://") { raw = "https://\(raw)" }

        guard var components = URLComponents(string: raw) else {
            throw SharePointInventoryError.invalidSiteUrl
        }
        components.query = nil
        components.fragment = nil
        if let host = components.host { components.host = host.lowercased() }
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        guard let host = components.host, !components.path.isEmpty else {
            throw SharePointInventoryError.invalidSiteUrl
        }

        let token = try await requireToken()
        let encodedPath = components.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? components.path
        let endpoint = "\(Self.graphBaseURL)/sites/\(host):\(encodedPath)"
        guard let url = URL(string: endpoint) else { throw SharePointInventoryError.invalidSiteUrl }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        if http.statusCode == 404 { throw SharePointInventoryError.siteNotFound }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SharePointInventoryError.invalidResponse
        }
        let webUrl = (json["webUrl"] as? String) ?? raw
        let display = (json["displayName"] as? String)
            ?? (json["name"] as? String)
            ?? webUrl
        return SharePointSiteInfo(id: id, displayName: display, webUrl: webUrl)
    }

    /// Liste les bibliothèques de documents d'un site (`GET /sites/{siteId}/drives`).
    func listLibraries(siteId: String) async throws -> [SharePointLibraryInfo] {
        let token = try await requireToken()
        let urlString = "\(Self.graphBaseURL)/sites/\(siteId)/drives"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let drives = json["value"] as? [[String: Any]] else {
            throw SharePointInventoryError.invalidResponse
        }
        return drives.compactMap { drive in
            let type = (drive["driveType"] as? String ?? "").lowercased()
            guard type == "documentlibrary",
                  let id = drive["id"] as? String,
                  let name = drive["name"] as? String else { return nil }
            return SharePointLibraryInfo(id: id, name: name)
        }
    }

    /// Liste les fichiers `.json` à la racine d'une bibliothèque (`GET /drives/{driveId}/root/children`).
    func listJSONFiles(driveId: String) async throws -> [SharePointFileInfo] {
        let token = try await requireToken()
        let urlString = "\(Self.graphBaseURL)/drives/\(driveId)/root/children"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["value"] as? [[String: Any]] else {
            throw SharePointInventoryError.invalidResponse
        }
        return items.compactMap { item in
            guard item["file"] != nil,
                  let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  name.lowercased().hasSuffix(".json") else { return nil }
            return SharePointFileInfo(id: id, name: name)
        }
    }

    /// Liste les éléments partagés avec l'utilisateur (`GET /me/drive/sharedWithMe`).
    /// Ne conserve que les dossiers (navigables) et les fichiers `.json`.
    /// Les identifiants exploitables se trouvent sous `remoteItem`.
    func listSharedWithMe() async throws -> [SharePointSharedItem] {
        let token = try await requireToken()
        let urlString = "\(Self.graphBaseURL)/me/drive/sharedWithMe"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else {
            throw SharePointInventoryError.invalidResponse
        }
        return values.compactMap { entry in
            // Pour un item partagé, les vrais identifiants sont sous `remoteItem`.
            let remote = (entry["remoteItem"] as? [String: Any]) ?? entry
            guard let id = remote["id"] as? String,
                  let parent = remote["parentReference"] as? [String: Any],
                  let driveId = parent["driveId"] as? String else { return nil }
            let name = (remote["name"] as? String) ?? (entry["name"] as? String) ?? id
            let webUrl = (remote["webUrl"] as? String) ?? ""
            let isFolder = remote["folder"] != nil
            // Garder les dossiers (navigables) et les .json uniquement.
            if isFolder { return SharePointSharedItem(id: id, driveId: driveId, name: name, webUrl: webUrl, isFolder: true) }
            guard name.lowercased().hasSuffix(".json") else { return nil }
            return SharePointSharedItem(id: id, driveId: driveId, name: name, webUrl: webUrl, isFolder: false)
        }
    }

    /// Liste les enfants à la racine d'une bibliothèque (`GET /drives/{driveId}/root/children`).
    /// Ne conserve que les dossiers et les fichiers `.json`.
    func listRootItems(driveId: String) async throws -> [SharePointSharedItem] {
        let urlString = "\(Self.graphBaseURL)/drives/\(driveId)/root/children"
        return try await fetchChildItems(urlString: urlString, driveId: driveId)
    }

    /// Liste les enfants d'un dossier (`GET /drives/{driveId}/items/{itemId}/children`).
    /// Ne conserve que les sous-dossiers et les fichiers `.json`.
    func listChildren(driveId: String, itemId: String) async throws -> [SharePointSharedItem] {
        let urlString = "\(Self.graphBaseURL)/drives/\(driveId)/items/\(itemId)/children"
        return try await fetchChildItems(urlString: urlString, driveId: driveId)
    }

    /// Récupère et filtre une collection d'enfants (dossiers + `.json`).
    private func fetchChildItems(urlString: String, driveId: String) async throws -> [SharePointSharedItem] {
        let token = try await requireToken()
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["value"] as? [[String: Any]] else {
            throw SharePointInventoryError.invalidResponse
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String else { return nil }
            let webUrl = (item["webUrl"] as? String) ?? ""
            let isFolder = item["folder"] != nil
            if isFolder { return SharePointSharedItem(id: id, driveId: driveId, name: name, webUrl: webUrl, isFolder: true) }
            guard name.lowercased().hasSuffix(".json") else { return nil }
            return SharePointSharedItem(id: id, driveId: driveId, name: name, webUrl: webUrl, isFolder: false)
        }
    }

    /// Infos d'affichage d'une bibliothèque (drive) : nom + URL web. Sert à remplir
    /// les champs « bibliothèque » et « site » après une sélection « Partagés avec moi ».
    func driveInfo(driveId: String) async throws -> (name: String, webUrl: String) {
        let token = try await requireToken()
        let urlString = "\(Self.graphBaseURL)/drives/\(driveId)?$select=name,webUrl"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SharePointInventoryError.invalidResponse
        }
        let name = (json["name"] as? String) ?? "Documents"
        let webUrl = (json["webUrl"] as? String) ?? ""
        return (name, webUrl)
    }

    /// Parse une réponse Graph contenant une collection de sites (`value[]`).
    private func fetchSiteList(url: URL, token: String) async throws -> [SharePointSiteInfo] {
        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sites = json["value"] as? [[String: Any]] else {
            throw SharePointInventoryError.invalidResponse
        }
        return sites.compactMap { site in
            guard let id = site["id"] as? String,
                  let webUrl = site["webUrl"] as? String else { return nil }
            // displayName peut manquer sur certains sites — repli sur name puis webUrl.
            let display = (site["displayName"] as? String)
                ?? (site["name"] as? String)
                ?? webUrl
            return SharePointSiteInfo(id: id, displayName: display, webUrl: webUrl)
        }
    }

    /// Télécharge le fichier JSON distant. Retourne un `InventoryFile` vide si le fichier n'existe pas encore.
    func downloadFile(settings: InventorySettings) async throws -> InventoryFile {
        guard settings.isConfigured else { throw SharePointInventoryError.notConfigured }
        var target = try await resolveTarget(settings: settings, forceRefresh: false)

        guard let itemId = target.itemId else {
            // Fichier absent — retourner un fichier vide sans erreur.
            return InventoryFile(year: settings.inventoryYear)
        }

        let token = try await requireToken()
        let urlString = "\(Self.graphBaseURL)/drives/\(target.driveId)/items/\(itemId)/content"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }

        if http.statusCode == 404 {
            // Le fichier a été supprimé entre-temps.
            target.itemId = nil
            target.eTag = nil
            cachedTarget = target
            return InventoryFile(year: settings.inventoryYear)
        }

        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        // Capturer l'ETag du GET pour le prochain upload.
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            target.eTag = etag
            cachedTarget = target
        }

        // Parser. Si corrompu ou vide → repartir d'un fichier vide (safer que de crasher).
        if data.isEmpty {
            return InventoryFile(year: settings.inventoryYear)
        }
        do {
            return try InventoryFile.jsonDecoder.decode(InventoryFile.self, from: data)
        } catch {
            return InventoryFile(year: settings.inventoryYear)
        }
    }

    /// Ajoute `newRecords` au fichier SharePoint de façon append-only.
    /// Boucle interne download → merge → PUT avec `If-Match`. Retry jusqu'à 5 fois sur 412.
    /// Retourne le `InventoryFile` final tel que présent sur SharePoint après succès.
    @discardableResult
    func upload(newRecords: [InventoryRecord], settings: InventorySettings) async throws -> InventoryFile {
        guard settings.isConfigured else { throw SharePointInventoryError.notConfigured }
        guard !newRecords.isEmpty else {
            return try await downloadFile(settings: settings)
        }

        var attempt = 0
        while attempt < Self.maxConflictRetries {
            attempt += 1

            // 1. Download courant + capture ETag.
            var remote = try await downloadFile(settings: settings)
            let target = try await resolveTarget(settings: settings, forceRefresh: false)

            // 2. Merge append-only (union par clientRecordId).
            remote.merge(appending: newRecords)

            // 3. Encode.
            let body = try InventoryFile.jsonEncoder.encode(remote)
            if body.count > Self.maxUploadBytes {
                throw SharePointInventoryError.fileTooLarge(bytes: body.count)
            }

            // 4. PUT avec If-Match (update) ou If-None-Match: * (création).
            do {
                try await putContent(body: body, target: target, settings: settings)
                return remote
            } catch SharePointInventoryError.httpError(let status, _) where status == 412 {
                // Conflit : un autre téléphone a modifié le fichier. Invalider le cache et réessayer.
                invalidateCache()
                AppLog.shared.warning("ETag conflict (412) on attempt \(attempt)/\(Self.maxConflictRetries) — retrying", category: "sharepoint")
                // Petit backoff exponentiel : 200, 400, 800, 1600, 3200 ms
                let delayMs = UInt64(200 * (1 << (attempt - 1)))
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                continue
            } catch SharePointInventoryError.httpError(let status, _) where status == 404 {
                // L'item a disparu entre download et PUT. Invalider et retenter en création.
                invalidateCache()
                AppLog.shared.warning("Item gone (404) between download and PUT — retrying as creation", category: "sharepoint")
                continue
            }
        }

        AppLog.shared.error("Upload aborted after \(Self.maxConflictRetries) ETag conflicts", category: "sharepoint")
        throw SharePointInventoryError.conflictRetryExhausted
    }

    // MARK: - Private: Token

    private func requireToken() async throws -> String {
        guard let token = await authService.getAccessToken() else {
            throw SharePointInventoryError.notAuthenticated
        }
        return token
    }

    // MARK: - Private: Resolution (site → drive → item)

    private func targetCacheKey(settings: InventorySettings) -> String {
        // Inclut le pointeur direct pour invalider le cache si la sélection change.
        "\(settings.driveId ?? "-")|\(settings.itemId ?? "-")|\(settings.sharePointSiteUrl)|\(settings.documentLibraryName)|\(settings.fileName)"
    }

    private func resolveTarget(settings: InventorySettings, forceRefresh: Bool) async throws -> ResolvedTarget {
        let key = targetCacheKey(settings: settings)
        if !forceRefresh, let cached = cachedTarget, cachedTargetKey == key {
            return cached
        }

        // Chemin rapide : un drive a déjà été résolu via le sélecteur. On court-circuite
        // la résolution site → bibliothèque (et on supporte les fichiers en sous-dossier).
        if let driveId = settings.driveId {
            let itemId: String?
            let eTag: String?
            if let knownItem = settings.itemId {
                // Fichier existant connu (peut être en sous-dossier). eTag capturé au 1er GET.
                itemId = knownItem
                eTag = (cachedTargetKey == key) ? cachedTarget?.eTag : nil
            } else {
                // Bibliothèque connue ; fichier adressé par nom (racine ou dossier parent). Création possible.
                let token = try await requireToken()
                (itemId, eTag) = try await fetchItemIdAndETag(
                    driveId: driveId,
                    parentItemId: settings.parentItemId,
                    fileName: settings.fileName,
                    token: token
                )
            }
            let target = ResolvedTarget(siteId: "", driveId: driveId, itemId: itemId, eTag: eTag)
            cachedTarget = target
            cachedTargetKey = key
            return target
        }

        guard let normalized = settings.normalizedSiteUrl(),
              let host = normalized.host else {
            throw SharePointInventoryError.invalidSiteUrl
        }
        // path ex: "/sites/IT" — retirer le leading slash attendu par Graph.
        let sitePath = normalized.path
        guard !sitePath.isEmpty else { throw SharePointInventoryError.invalidSiteUrl }

        let token = try await requireToken()

        // 1. Résoudre le site.
        let siteId = try await fetchSiteId(host: host, sitePath: sitePath, token: token)

        // 2. Trouver le drive correspondant à la bibliothèque configurée.
        let driveId = try await fetchDriveId(siteId: siteId, libraryName: settings.documentLibraryName, token: token)

        // 3. Résoudre l'item (le fichier peut ne pas exister encore → itemId = nil).
        let (itemId, eTag) = try await fetchItemIdAndETag(driveId: driveId, fileName: settings.fileName, token: token)

        let target = ResolvedTarget(siteId: siteId, driveId: driveId, itemId: itemId, eTag: eTag)
        cachedTarget = target
        cachedTargetKey = key
        return target
    }

    private func fetchSiteId(host: String, sitePath: String, token: String) async throws -> String {
        // Format Graph : /sites/{hostname}:{serverRelativeUrl}
        // Exemple : /sites/contoso.sharepoint.com:/sites/IT
        let encodedPath = sitePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sitePath
        let urlString = "\(Self.graphBaseURL)/sites/\(host):\(encodedPath)"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidSiteUrl }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }

        if http.statusCode == 404 { throw SharePointInventoryError.siteNotFound }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SharePointInventoryError.invalidResponse
        }
        return id
    }

    private func fetchDriveId(siteId: String, libraryName: String, token: String) async throws -> String {
        let urlString = "\(Self.graphBaseURL)/sites/\(siteId)/drives"
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let drives = json["value"] as? [[String: Any]] else {
            throw SharePointInventoryError.invalidResponse
        }

        let wantedLower = libraryName.trimmingCharacters(in: .whitespaces).lowercased()

        // Matching tolérant : nom de drive ou displayName (Documents ↔ "Documents partagés" ↔ "Shared Documents").
        for drive in drives {
            let name = (drive["name"] as? String ?? "").lowercased()
            if name == wantedLower, let id = drive["id"] as? String {
                return id
            }
        }
        // Fallback : si l'utilisateur a tapé "Documents" et que le drive s'appelle autrement,
        // prendre le premier drive de type "documentLibrary".
        if wantedLower == "documents" {
            for drive in drives {
                let type = (drive["driveType"] as? String ?? "").lowercased()
                if type == "documentlibrary", let id = drive["id"] as? String {
                    return id
                }
            }
        }

        throw SharePointInventoryError.libraryNotFound(libraryName)
    }

    private func fetchItemIdAndETag(driveId: String, parentItemId: String? = nil, fileName: String, token: String)
        async throws -> (String?, String?)
    {
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        // Adressage relatif : racine de la bibliothèque, ou dossier parent si précisé.
        let urlString: String
        if let parentItemId {
            urlString = "\(Self.graphBaseURL)/drives/\(driveId)/items/\(parentItemId):/\(encodedName)"
        } else {
            urlString = "\(Self.graphBaseURL)/drives/\(driveId)/root:/\(encodedName)"
        }
        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        let (data, response) = try await authGet(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }

        if http.statusCode == 404 {
            return (nil, nil) // Fichier absent — sera créé au 1er upload.
        }
        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SharePointInventoryError.invalidResponse
        }
        let etag = json["eTag"] as? String
        return (id, etag)
    }

    // MARK: - Private: PUT

    private func putContent(body: Data, target: ResolvedTarget, settings: InventorySettings) async throws {
        let token = try await requireToken()

        let urlString: String
        var ifMatch: String?
        var ifNoneMatch: String?

        if let itemId = target.itemId {
            // Update existing file.
            urlString = "\(Self.graphBaseURL)/drives/\(target.driveId)/items/\(itemId)/content"
            if let etag = target.eTag { ifMatch = etag }
        } else {
            // Create new file by path : racine de la bibliothèque, ou dossier parent si précisé.
            let encodedName = settings.fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settings.fileName
            if let parentItemId = settings.parentItemId {
                urlString = "\(Self.graphBaseURL)/drives/\(target.driveId)/items/\(parentItemId):/\(encodedName):/content"
            } else {
                urlString = "\(Self.graphBaseURL)/drives/\(target.driveId)/root:/\(encodedName):/content"
            }
            ifNoneMatch = "*" // Fail si un autre client a créé le fichier entre-temps.
        }

        guard let url = URL(string: urlString) else { throw SharePointInventoryError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SharePointInventoryError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            throw SharePointInventoryError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        // Capturer le nouvel ETag + itemId pour le prochain upload.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var updated = target
            if let id = json["id"] as? String { updated.itemId = id }
            if let etag = json["eTag"] as? String { updated.eTag = etag }
            cachedTarget = updated
        }
    }

    // MARK: - Private: HTTP helper

    private func authGet(url: URL, token: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: request)
    }
}
