import Foundation

// MARK: - Inventory Record (un enregistrement atomique de vérification)

/// Un enregistrement d'inventaire : un technicien a scanné un appareil à un instant donné.
/// Append-only : une fois écrit dans le fichier centralisé SharePoint, il n'est jamais modifié ni supprimé.
/// Identifié de manière unique par `clientRecordId` (UUID généré localement) pour permettre
/// une fusion idempotente lors des uploads concurrents.
struct InventoryRecord: Codable, Identifiable, Hashable {
    /// Identifiant métier (identique à `clientRecordId` — dupliqué par lisibilité dans le JSON).
    let id: String
    /// UUID généré localement. Sert de clé de déduplication lors des merges ETag.
    let clientRecordId: String

    let deviceId: String
    let deviceName: String
    let serialNumber: String
    let userPrincipalName: String
    let userDisplayName: String
    /// Nom d'entreprise dérivé de l'utilisateur Entra ID, ou `"Non assigné"` si absent.
    let companyName: String

    let status: InventoryStatus
    /// Note libre. Obligatoire si `status == .autre` ou si attribution
    /// unassigned saisie sans utilisateur précis.
    let note: String

    let checkedAt: Date
    /// UPN (email) du technicien qui a effectué le scan.
    let checkedBy: String
    /// Nom d'affichage du technicien.
    let checkedByName: String

    // MARK: - Attribution manuelle (devices originellement "Non assigné")
    //
    // Ces champs sont renseignés quand le technicien scanne un device qui
    // n'a pas d'utilisateur dans Intune et saisit manuellement son
    // propriétaire. Dans ce cas, les champs top-level ci-dessus
    // (`companyName`, `userPrincipalName`, `userDisplayName`) sont
    // directement écrits avec les valeurs attribuées — le record
    // SharePoint reflète donc immédiatement l'entreprise/utilisateur
    // choisi par le tech, et n'apparaît plus comme "Non assigné". Les
    // champs `assigned*` restent en parallèle comme marqueur
    // « attribution manuelle » permettant de distinguer un record
    // attribué à la main d'un record dérivé directement d'Intune.

    /// Entreprise choisie manuellement. Nil pour un device déjà assigné
    /// dans Intune. Quand non-nil, `companyName` ci-dessus porte la
    /// même valeur.
    let assignedCompanyName: String?
    /// Utilisateur précis choisi (optionnel, même si l'entreprise est
    /// renseignée). Nil si le tech ne connaît pas la personne. Quand
    /// non-nil, `userPrincipalName` / `userDisplayName` ci-dessus portent
    /// les valeurs de cet utilisateur.
    let assignedUserPrincipalName: String?
    let assignedUserDisplayName: String?

    init(
        deviceId: String,
        deviceName: String,
        serialNumber: String,
        userPrincipalName: String,
        userDisplayName: String,
        companyName: String,
        status: InventoryStatus,
        note: String,
        checkedBy: String,
        checkedByName: String,
        checkedAt: Date = Date(),
        assignedCompanyName: String? = nil,
        assignedUserPrincipalName: String? = nil,
        assignedUserDisplayName: String? = nil
    ) {
        let uuid = UUID().uuidString
        self.id = uuid
        self.clientRecordId = uuid
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.serialNumber = serialNumber
        self.userPrincipalName = userPrincipalName
        self.userDisplayName = userDisplayName
        self.companyName = companyName
        self.status = status
        self.note = note
        self.checkedAt = checkedAt
        self.checkedBy = checkedBy
        self.checkedByName = checkedByName
        self.assignedCompanyName = assignedCompanyName
        self.assignedUserPrincipalName = assignedUserPrincipalName
        self.assignedUserDisplayName = assignedUserDisplayName
    }
}

// MARK: - Inventory Status

/// Statut d'une vérification. Les rawValues françaises sont la forme canonique stockée dans le JSON.
enum InventoryStatus: String, Codable, CaseIterable, Hashable {
    case trouve = "Trouvé"
    case endommage = "Endommagé"
    case autre = "Autre"

    var icon: String {
        switch self {
        case .trouve: return "checkmark.seal.fill"
        case .endommage: return "exclamationmark.triangle.fill"
        case .autre: return "questionmark.circle.fill"
        }
    }

    /// Nom de couleur SwiftUI correspondant.
    var colorName: String {
        switch self {
        case .trouve: return "green"
        case .endommage: return "orange"
        case .autre: return "purple"
        }
    }
}

// MARK: - Inventory File (format du JSON sur SharePoint)

/// Format de haut niveau du fichier JSON stocké sur SharePoint.
/// Un fichier par année d'inventaire. Append-log de `records`.
struct InventoryFile: Codable {
    let schemaVersion: Int
    let year: Int
    let createdAt: Date
    var records: [InventoryRecord]

    init(year: Int, records: [InventoryRecord] = []) {
        // v2 : ajout des champs d'attribution manuelle (assigned*) pour les
        // devices originellement "Non assigné". Rétro-compatible avec les
        // fichiers v1 — les optionnels manquants décodent en nil.
        self.schemaVersion = 2
        self.year = year
        self.createdAt = Date()
        self.records = records
    }

    /// Fusion append-only par `clientRecordId`. Si un record existe déjà à distance avec le même id,
    /// on garde la version existante (elle est stable) — on ajoute uniquement les nouveaux.
    mutating func merge(appending newRecords: [InventoryRecord]) {
        let existingIds = Set(records.map(\.clientRecordId))
        for r in newRecords where !existingIds.contains(r.clientRecordId) {
            records.append(r)
        }
    }

    // MARK: - JSON encoder/decoder partagés

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Label utilisé pour les devices sans utilisateur ou dont l'utilisateur n'a pas de `companyName`.
    static let unassignedCompanyLabel = "Non assigné"
}

// MARK: - Queued Record (file d'attente locale)

/// Enveloppe locale d'un `InventoryRecord` en attente d'upload vers SharePoint.
struct QueuedRecord: Codable, Identifiable, Hashable {
    let record: InventoryRecord
    var lastError: String?
    var lastTriedAt: Date?

    var id: String { record.clientRecordId }

    init(record: InventoryRecord) {
        self.record = record
        self.lastError = nil
        self.lastTriedAt = nil
    }
}
