import Foundation
import SwiftUI
import Combine

// MARK: - Company Progress

/// Snapshot de l'avancement pour une entreprise donnée.
struct CompanyProgress: Identifiable, Hashable {
    let companyName: String
    let totalDevices: Int
    let checkedDevices: Int

    var id: String { companyName }
    var remaining: Int { max(0, totalDevices - checkedDevices) }
    var progressRatio: Double {
        totalDevices == 0 ? 0 : Double(checkedDevices) / Double(totalDevices)
    }
    var isComplete: Bool { totalDevices > 0 && remaining == 0 }
}

// MARK: - Device Row

/// Affichage d'un appareil dans la liste d'une entreprise (vérifié ou non).
struct InventoryDeviceRow: Identifiable, Hashable {
    let device: Device
    let isChecked: Bool
    /// Date du dernier check (local ou distant), si vérifié.
    let lastCheckedAt: Date?
    /// Nom du technicien qui a vérifié en dernier.
    let lastCheckedBy: String?

    var id: String { device.id }
}

// MARK: - Inventory ViewModel

/// Orchestre l'onglet Inventaire :
/// - Charge devices + users depuis Graph (filtrés par périmètre).
/// - Joint Device → User → `companyName`.
/// - Télécharge le fichier d'inventaire distant depuis SharePoint.
/// - Calcule la progression par entreprise en combinant records distants + queue locale.
/// - Ajoute de nouveaux records à la queue locale (qui gère l'upload).
@MainActor
final class InventoryViewModel: ObservableObject {

    // MARK: - Dependencies

    let graphService: GraphService
    let authService: AuthService
    let sharePointService: SharePointInventoryService
    let queueStore: InventoryQueueStore
    let settingsStore: InventorySettingsStore
    let snapshotStore: DeviceSnapshotStore

    // MARK: - Published state

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastRefreshAt: Date?
    /// Vrai si l'écran actuel s'appuie sur le snapshot local (refresh Graph a échoué).
    @Published private(set) var isUsingSnapshot: Bool = false

    /// Devices Intune filtrés selon le périmètre actif (Windows + macOS par défaut).
    @Published private(set) var scopedDevices: [Device] = []
    /// Records distants du dernier download (cumulés avec la queue pour l'affichage).
    @Published private(set) var remoteRecords: [InventoryRecord] = []

    // MARK: - Private

    private var usersByUPN: [String: User] = [:]
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(
        graphService: GraphService,
        authService: AuthService,
        sharePointService: SharePointInventoryService,
        queueStore: InventoryQueueStore,
        settingsStore: InventorySettingsStore,
        snapshotStore: DeviceSnapshotStore
    ) {
        self.graphService = graphService
        self.authService = authService
        self.sharePointService = sharePointService
        self.queueStore = queueStore
        self.settingsStore = settingsStore
        self.snapshotStore = snapshotStore

        // Hydrate à partir du snapshot local pour pouvoir scanner même
        // avant le 1er refresh réussi (par exemple immédiatement après
        // relance offline). Le refresh ultérieur écrasera ces valeurs.
        if let s = snapshotStore.snapshot {
            self.usersByUPN = Dictionary(
                s.users.map { ($0.userPrincipalName.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            self.scopedDevices = Self.filterByScope(devices: s.devices, scopes: settingsStore.settings.activeScopes)
            self.isUsingSnapshot = true
        }

        // Redifuser les changements du queueStore et du settingsStore pour que les vues
        // qui observent directement le VM voient les mises à jour automatiquement.
        queueStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settingsStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        snapshotStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private static func filterByScope(devices: [Device], scopes: Set<DeviceScope>) -> [Device] {
        devices.filter { device in
            scopes.contains { $0.matches(operatingSystem: device.operatingSystem) }
        }
    }

    // MARK: - Public: Loading

    /// Recharge devices + users + fichier distant SharePoint.
    /// Sauvegarde un snapshot local après succès pour fallback hors-ligne.
    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // 1. Devices + users depuis Graph (caches internes à GraphService).
            async let devicesTask = graphService.getAllDevices()
            async let usersTask = graphService.getAllUsers()
            let devices = try await devicesTask
            let users = try await usersTask

            self.usersByUPN = Dictionary(
                users.map { ($0.userPrincipalName.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )

            // 2. Filtrage par périmètre (DeviceScope).
            let scopes = settingsStore.settings.activeScopes
            self.scopedDevices = Self.filterByScope(devices: devices, scopes: scopes)
            self.isUsingSnapshot = false

            // 3. Persistance snapshot complet (parc non filtré pour pouvoir
            //    changer de scope sans refresh).
            snapshotStore.save(devices: devices, users: users)

            // 4. Fichier distant SharePoint (si configuré).
            if settingsStore.settings.isConfigured {
                do {
                    let file = try await sharePointService.downloadFile(settings: settingsStore.settings)
                    self.remoteRecords = file.records
                } catch {
                    // Ne pas bloquer l'UI — l'utilisateur peut consulter le parc même si SP est KO.
                    self.errorMessage = "SharePoint : \(error.localizedDescription)"
                    self.remoteRecords = []
                }
            } else {
                self.remoteRecords = []
            }

            self.lastRefreshAt = Date()
        } catch {
            // Fallback offline : si un snapshot existe, on continue avec lui plutôt
            // que de laisser l'UI vide.
            if let s = snapshotStore.snapshot {
                let scopes = settingsStore.settings.activeScopes
                self.usersByUPN = Dictionary(
                    s.users.map { ($0.userPrincipalName.lowercased(), $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.scopedDevices = Self.filterByScope(devices: s.devices, scopes: scopes)
                self.isUsingSnapshot = true
                self.errorMessage = "Hors-ligne — données du snapshot local utilisées."
                AppLog.shared.warning(
                    "Refresh failed, falling back to local snapshot: \(error.localizedDescription)",
                    category: "inventory"
                )
            } else {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Public: Progression

    /// Tous les records considérés comme "vérifiés" par l'UI = remote + queue en attente.
    /// Les records en queue peuvent déjà être présents à distance (si un flush partiel a
    /// réussi) — on dédoublonne par `clientRecordId`.
    var effectiveRecords: [InventoryRecord] {
        let pending = queueStore.pending.map(\.record)
        let pendingIds = Set(pending.map(\.clientRecordId))
        let remoteFiltered = remoteRecords.filter { !pendingIds.contains($0.clientRecordId) }
        return remoteFiltered + pending
    }

    /// Set des deviceId déjà vérifiés (n'importe quel record suffit, append-only).
    var checkedDeviceIds: Set<String> {
        Set(effectiveRecords.map(\.deviceId))
    }

    /// Progression par entreprise, triée : non terminées d'abord, "Non assigné" en dernier,
    /// puis alphabétique.
    var companiesProgress: [CompanyProgress] {
        // 1. Regrouper les devices par companyName (dérivé via userPrincipalName → User.companyName).
        var devicesByCompany: [String: [Device]] = [:]
        for device in scopedDevices {
            let company = companyName(for: device)
            devicesByCompany[company, default: []].append(device)
        }

        let checked = checkedDeviceIds

        let progressList: [CompanyProgress] = devicesByCompany.map { (company, devices) in
            let checkedCount = devices.filter { checked.contains($0.id) }.count
            return CompanyProgress(
                companyName: company,
                totalDevices: devices.count,
                checkedDevices: checkedCount
            )
        }

        return progressList.sorted { lhs, rhs in
            // "Non assigné" toujours en dernier.
            let unassigned = InventoryFile.unassignedCompanyLabel
            if lhs.companyName == unassigned && rhs.companyName != unassigned { return false }
            if rhs.companyName == unassigned && lhs.companyName != unassigned { return true }
            // Non terminées avant terminées.
            if lhs.isComplete != rhs.isComplete { return !lhs.isComplete }
            // Alphabétique.
            return lhs.companyName.localizedCaseInsensitiveCompare(rhs.companyName) == .orderedAscending
        }
    }

    /// Progression globale (tous devices du périmètre confondus).
    var globalProgress: CompanyProgress {
        let total = scopedDevices.count
        let checked = scopedDevices.filter { checkedDeviceIds.contains($0.id) }.count
        return CompanyProgress(
            companyName: "Global",
            totalDevices: total,
            checkedDevices: checked
        )
    }

    /// Lignes d'affichage pour une entreprise : tous ses devices avec statut vérifié ou non.
    func deviceRows(forCompany company: String) -> [InventoryDeviceRow] {
        let records = effectiveRecords
        let recordsByDeviceId: [String: [InventoryRecord]] = Dictionary(grouping: records, by: \.deviceId)
        let devices = scopedDevices.filter { companyName(for: $0) == company }

        return devices
            .map { device -> InventoryDeviceRow in
                let deviceRecords = recordsByDeviceId[device.id] ?? []
                let mostRecent = deviceRecords.max(by: { $0.checkedAt < $1.checkedAt })
                return InventoryDeviceRow(
                    device: device,
                    isChecked: mostRecent != nil,
                    lastCheckedAt: mostRecent?.checkedAt,
                    lastCheckedBy: mostRecent?.checkedByName
                )
            }
            .sorted { lhs, rhs in
                // À vérifier en premier, puis alphabétique par nom de device.
                if lhs.isChecked != rhs.isChecked { return !lhs.isChecked }
                return lhs.device.deviceName.localizedCaseInsensitiveCompare(rhs.device.deviceName) == .orderedAscending
            }
    }

    // MARK: - Public: Scanning & validation

    /// Raison d'un échec de résolution scan, exposée à l'UI pour afficher
    /// un message précis (différent d'un simple « aucun appareil trouvé »).
    enum ScanResolutionFailure: Error, LocalizedError {
        case noMatchingDevice

        var errorDescription: String? {
            switch self {
            case .noMatchingDevice:
                return "Aucun appareil du périmètre actif ne correspond à ce code."
            }
        }
    }

    /// Résout un code scanné vers un device du périmètre actif.
    /// Lance `ScanResolutionFailure.noMatchingDevice` plutôt que de retourner nil
    /// pour permettre à l'UI d'afficher un message précis.
    func resolveDeviceFromScannedCodeStrict(_ code: String) throws -> Device {
        let serial: String
        let deviceId: String
        let deviceName: String

        if let payload = QRPayload.parse(code) {
            serial = payload.serial
            deviceId = payload.id
            deviceName = payload.name
        } else {
            serial = code
            deviceId = code
            deviceName = code
        }

        if let device = matchDevice(serial: serial, deviceId: deviceId, deviceName: deviceName) {
            return device
        }
        throw ScanResolutionFailure.noMatchingDevice
    }

    /// Variante historique : retourne nil au lieu de throw. Conservée pour
    /// rétrocompatibilité — appelle la version stricte et avale les erreurs.
    func resolveDeviceFromScannedCode(_ code: String) -> Device? {
        try? resolveDeviceFromScannedCodeStrict(code)
    }

    private func matchDevice(serial: String, deviceId: String, deviceName: String) -> Device? {

        // Matcher dans la liste en cache (pas d'aller-retour réseau — on veut un scan instant).
        if !serial.isEmpty,
           let match = scopedDevices.first(where: { $0.serialNumber.caseInsensitiveCompare(serial) == .orderedSame }) {
            return match
        }
        if !deviceId.isEmpty,
           let match = scopedDevices.first(where: { $0.id == deviceId }) {
            return match
        }
        if !deviceName.isEmpty,
           let match = scopedDevices.first(where: { $0.deviceName.caseInsensitiveCompare(deviceName) == .orderedSame }) {
            return match
        }
        return nil
    }

    /// Retourne le record le plus récent pour un device donné, ou nil.
    func latestRecord(forDevice deviceId: String) -> InventoryRecord? {
        effectiveRecords
            .filter { $0.deviceId == deviceId }
            .max(by: { $0.checkedAt < $1.checkedAt })
    }

    /// Crée un `InventoryRecord` et l'ajoute à la file d'attente (append-only).
    /// L'upload vers SharePoint est déclenché en arrière-plan par le queue store.
    ///
    /// Pour un device originellement "Non assigné", le technicien doit
    /// renseigner au moins `assignedCompany`. Il peut optionnellement
    /// préciser `assignedUser`. Quand une attribution est saisie, les
    /// champs top-level du record (`companyName`, `userPrincipalName`,
    /// `userDisplayName`) sont écrits avec les valeurs attribuées plutôt
    /// qu'avec l'état Intune brut — le record écrit sur SharePoint
    /// reflète donc directement l'attribution voulue. Les champs
    /// `assigned*` sont conservés en parallèle comme marqueur
    /// « attribution manuelle ».
    func submitCheck(
        device: Device,
        status: InventoryStatus,
        note: String,
        assignedCompany: String? = nil,
        assignedUser: User? = nil
    ) {
        // Normalisation : si un user est passé, sa company fait foi. Sinon
        // on utilise la company explicite. On nettoie les whitespaces et on
        // mappe la chaîne vide vers nil.
        let resolvedCompany: String? = {
            if let user = assignedUser {
                let trimmed = user.companyName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
            let trimmed = (assignedCompany ?? "").trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }()

        // Override des champs top-level quand une attribution est saisie :
        // - companyName : entreprise attribuée si présente, sinon dérivée du
        //   device (fallback "Non assigné").
        // - userPrincipalName / userDisplayName : issus de l'utilisateur
        //   attribué si présent, sinon snapshot Intune du device.
        let effectiveCompany = resolvedCompany ?? companyName(for: device)
        let effectiveUPN = assignedUser?.userPrincipalName ?? device.userPrincipalName
        let effectiveDisplayName = assignedUser?.displayName ?? device.userDisplayName

        let record = InventoryRecord(
            deviceId: device.id,
            deviceName: device.deviceName,
            serialNumber: device.serialNumber,
            userPrincipalName: effectiveUPN,
            userDisplayName: effectiveDisplayName,
            companyName: effectiveCompany,
            status: status,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            checkedBy: authService.userEmail.isEmpty ? authService.userName : authService.userEmail,
            checkedByName: authService.userName,
            assignedCompanyName: resolvedCompany,
            assignedUserPrincipalName: assignedUser?.userPrincipalName,
            assignedUserDisplayName: assignedUser?.displayName
        )
        queueStore.enqueue(record)
    }

    // MARK: - Public: Reporting

    /// Génère un rapport PDF exécutif de la session courante et retourne son URL.
    /// Lance l'erreur sous-jacente si la génération échoue.
    func generatePDFReport() throws -> URL {
        let records = effectiveRecords
        let byStatus = Dictionary(grouping: records, by: \.status)
            .mapValues(\.count)

        let deviceNames = Dictionary(
            scopedDevices.map { ($0.id, $0.deviceName) },
            uniquingKeysWith: { first, _ in first }
        )

        let input = PDFReportBuilder.Input(
            year: settingsStore.settings.inventoryYear,
            generatedAt: Date(),
            technicianName: authService.userName.isEmpty ? "—" : authService.userName,
            scopes: Array(settingsStore.settings.activeScopes).sorted { $0.rawValue < $1.rawValue },
            totalDevices: scopedDevices.count,
            checkedDevices: checkedDeviceIds.count,
            recordsByStatus: byStatus,
            companies: companiesProgress,
            anomalies: anomalies,
            deviceNames: deviceNames
        )
        return try PDFReportBuilder.build(input)
    }

    // MARK: - Public: Anomalies

    /// Analyse le parc actif et retourne les anomalies détectées (sync ancienne,
    /// non-compliant + user actif, doublons série). Calcul à la demande — pas
    /// de cache car le parc est en mémoire et la liste reste petite.
    var anomalies: [DeviceAnomaly] {
        AnomalyDetector.analyze(devices: scopedDevices, usersByUPN: usersByUPN)
    }

    /// Index `deviceId → [anomalies]` pour lookup O(1) depuis l'UI.
    var anomaliesByDevice: [String: [DeviceAnomaly]] {
        AnomalyDetector.indexByDevice(anomalies)
    }

    /// Retourne les anomalies d'un device spécifique.
    func anomalies(forDevice deviceId: String) -> [DeviceAnomaly] {
        anomaliesByDevice[deviceId] ?? []
    }

    /// Autres appareils du parc actif partageant le même numéro de série que
    /// `device` (doublons). Vide si le numéro est unique ou absent.
    /// Comparaison insensible à la casse et aux espaces.
    func serialDuplicates(for device: Device) -> [Device] {
        let serial = device.serialNumber.trimmingCharacters(in: .whitespaces).lowercased()
        guard !serial.isEmpty else { return [] }
        return scopedDevices.filter { other in
            other.id != device.id
                && other.serialNumber.trimmingCharacters(in: .whitespaces).lowercased() == serial
        }
    }

    // MARK: - Helpers

    /// Dérive le nom d'entreprise d'un device via son utilisateur assigné.
    /// Fallback vers "Non assigné" si pas d'utilisateur ou pas de companyName.
    func companyName(for device: Device) -> String {
        let upn = device.userPrincipalName.lowercased()
        guard !upn.isEmpty, let user = usersByUPN[upn] else {
            return InventoryFile.unassignedCompanyLabel
        }
        let trimmed = user.companyName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? InventoryFile.unassignedCompanyLabel : trimmed
    }

    /// Vrai si le device n'a pas d'entreprise dérivable depuis Intune.
    /// Utilisé par le formulaire de scan pour imposer une attribution manuelle.
    func isUnassigned(_ device: Device) -> Bool {
        companyName(for: device) == InventoryFile.unassignedCompanyLabel
    }

    /// Liste triée des entreprises distinctes parmi les utilisateurs Entra ID
    /// actifs chargés. Source du picker d'entreprise lors de l'attribution.
    var allCompanies: [String] {
        let raw = usersByUPN.values
            .filter { $0.accountEnabled }
            .map { $0.companyName.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(raw))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Utilisateurs actifs triés par displayName, optionnellement filtrés
    /// sur une entreprise (comparaison case-insensitive, whitespace-trim).
    /// Source du picker d'utilisateur lors de l'attribution.
    func users(inCompany company: String? = nil) -> [User] {
        let all = usersByUPN.values.filter { $0.accountEnabled }
        let filtered: [User]
        if let company = company?.trimmingCharacters(in: .whitespaces), !company.isEmpty {
            filtered = all.filter {
                $0.companyName.trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(company) == .orderedSame
            }
        } else {
            filtered = Array(all)
        }
        return filtered.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
