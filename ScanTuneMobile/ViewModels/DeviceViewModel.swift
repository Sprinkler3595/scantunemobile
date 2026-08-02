import Foundation

/// ViewModel pour la vue de détail d'un appareil. Lecture seule — affichage uniquement.
@MainActor
final class DeviceViewModel: ObservableObject {

    // MARK: - Dependencies

    private let graphService: GraphService

    // MARK: - Published state

    @Published var device: Device?
    @Published var assignedUser: User?
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Type de jointure Azure AD (chargé à la demande après un scan) :
    // hybride (AD on-prem + Intune) vs 100% Intune (Azure AD Join).
    @Published var joinType: DeviceJoinType?

    // Autres appareils Intune partageant le même numéro de série que celui scanné
    // (doublons). Vide si le numéro est unique. Chargé à la demande après un scan.
    @Published var serialDuplicates: [Device] = []

    // BitLocker (chargé à la demande — opération sensible et auditée)
    @Published var bitlockerKeys: [BitLockerKey] = []
    @Published var isLoadingBitLocker = false
    @Published var bitlockerError: String?
    /// Vrai une fois la récupération tentée (succès, vide ou erreur) — pilote l'affichage.
    @Published var bitlockerLoaded = false

    // MARK: - Init

    init(graphService: GraphService) {
        self.graphService = graphService
    }

    // MARK: - Load device details (READ-ONLY)

    func loadDevice(_ device: Device) {
        self.device = device

        Task {
            await loadUserDetails(for: device)
        }
    }

    func loadDeviceById(_ deviceId: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            device = try await graphService.getDeviceById(deviceId)
            if let device = device {
                await loadUserDetails(for: device)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - User lookup (READ-ONLY)

    /// Charge le profil de l'utilisateur assigné si ce n'est pas déjà fait.
    /// Appelée par la vue détail quand le device est fourni directement
    /// (flux scanner) sans passer par `loadDeviceById`.
    func loadAssignedUserIfNeeded() async {
        guard assignedUser == nil, let device else { return }
        await loadUserDetails(for: device)
    }

    private func loadUserDetails(for device: Device) async {
        guard !device.userPrincipalName.isEmpty else { return }

        do {
            let users = try await graphService.getAllUsers()
            assignedUser = users.first {
                $0.userPrincipalName.lowercased() == device.userPrincipalName.lowercased()
            }
        } catch {
            // Pas critique si on ne trouve pas l'utilisateur
        }
    }

    // MARK: - Type de jointure Azure AD (READ-ONLY, à la demande)

    /// Détermine si l'appareil est hybride (Intune + AD on-prem) ou 100% Intune.
    /// Appelée par la vue détail après un scan. Échec silencieux (`.unknown`) :
    /// l'indication est purement informative et ne doit pas perturber l'écran.
    func loadJoinTypeIfNeeded() async {
        guard joinType == nil, let device else { return }
        let azureId = device.azureADDeviceId.trimmingCharacters(in: .whitespaces)
        guard !azureId.isEmpty else {
            joinType = .unknown
            return
        }
        do {
            joinType = try await graphService.getDeviceJoinType(azureADDeviceId: azureId)
        } catch {
            joinType = .unknown
        }
    }

    // MARK: - Doublons de numéro de série (READ-ONLY, à la demande)

    /// Détecte les autres appareils Intune portant le même numéro de série que
    /// l'appareil scanné. Échec silencieux : information complémentaire, ne doit
    /// pas perturber l'écran.
    func loadSerialDuplicatesIfNeeded() async {
        guard serialDuplicates.isEmpty, let device else { return }
        let serial = device.serialNumber.trimmingCharacters(in: .whitespaces)
        guard !serial.isEmpty else { return }

        do {
            let matches = try await graphService.findDevicesBySerialNumber(serial)
            // On exclut l'appareil courant ; il ne reste que les doublons.
            serialDuplicates = matches.filter { $0.id != device.id }
        } catch {
            // Pas critique.
        }
    }

    // MARK: - BitLocker (READ-ONLY, à la demande)

    /// Récupère les clés de récupération BitLocker de l'appareil scanné.
    /// Charge les métadonnées puis la valeur de chaque clé (chaque lecture est auditée côté Azure).
    func loadBitLockerKeys() async {
        guard let device else { return }

        let azureId = device.azureADDeviceId.trimmingCharacters(in: .whitespaces)
        guard !azureId.isEmpty else {
            bitlockerError = "Aucun identifiant Azure AD associé à cet appareil."
            bitlockerLoaded = true
            return
        }

        isLoadingBitLocker = true
        bitlockerError = nil
        defer {
            isLoadingBitLocker = false
            bitlockerLoaded = true
        }

        do {
            var keys = try await graphService.getBitLockerRecoveryKeys(azureADDeviceId: azureId)
            for index in keys.indices {
                keys[index].key = try? await graphService.getBitLockerKeyValue(keyId: keys[index].id)
            }
            bitlockerKeys = keys
        } catch {
            bitlockerError = error.localizedDescription
        }
    }

    // MARK: - Refresh (READ-ONLY)

    func refresh() async {
        guard let deviceId = device?.id else { return }
        await loadDeviceById(deviceId)
    }

    // MARK: - Computed properties

    var complianceColor: String {
        device?.displayStatus.color ?? "gray"
    }

    var complianceIcon: String {
        device?.displayStatus.icon ?? "questionmark.circle"
    }

    var lastSyncFormatted: String {
        guard let date = device?.lastSyncDateTime else { return "Jamais" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var enrolledDateFormatted: String {
        guard let date = device?.enrolledDateTime else { return "Inconnue" }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "fr_CA")
        return formatter.string(from: date)
    }

    var storagePercent: Double {
        device?.storageUsedPercent ?? 0
    }
}
