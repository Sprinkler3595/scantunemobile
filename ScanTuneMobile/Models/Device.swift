import Foundation

/// Représente un appareil managé Intune récupéré via Microsoft Graph API (lecture seule).
struct Device: Identifiable, Codable, Hashable {
    let id: String
    let deviceName: String
    let managedDeviceOwnerType: String
    let operatingSystem: String
    let osVersion: String
    let complianceState: String
    let model: String
    let manufacturer: String
    let serialNumber: String
    let userPrincipalName: String
    let userDisplayName: String
    let enrolledDateTime: Date?
    let lastSyncDateTime: Date?
    let totalStorageSpaceInBytes: Int64
    let freeStorageSpaceInBytes: Int64
    let managementAgent: String
    let deviceRegistrationState: String
    let azureADDeviceId: String
    let deviceCategoryDisplayName: String
    let notes: String

    // MARK: - Propriétés calculées

    var storageUsedPercent: Double {
        guard totalStorageSpaceInBytes > 0 else { return 0 }
        let used = totalStorageSpaceInBytes - freeStorageSpaceInBytes
        return Double(used) / Double(totalStorageSpaceInBytes) * 100.0
    }

    var daysSinceLastSync: Int {
        guard let lastSync = lastSyncDateTime else { return -1 }
        return Calendar.current.dateComponents([.day], from: lastSync, to: Date()).day ?? -1
    }

    var isCompliant: Bool {
        complianceState.lowercased() == "compliant"
    }

    var displayStatus: DeviceStatus {
        if !isCompliant { return .nonCompliant }
        if daysSinceLastSync > 30 { return .stale }
        if daysSinceLastSync > 7 { return .warning }
        return .healthy
    }

    /// Explication lisible du `displayStatus` courant — pourquoi l'appareil
    /// est en avertissement / non conforme. `nil` si l'appareil est sain.
    var statusReason: String? {
        switch displayStatus {
        case .healthy:
            return nil
        case .warning:
            return "Dernière synchronisation il y a \(daysSinceLastSync) jours (seuil d'avertissement : 7 jours)."
        case .stale:
            return "Dernière synchronisation il y a \(daysSinceLastSync) jours (seuil d'obsolescence : 30 jours)."
        case .nonCompliant:
            return complianceReason
        }
    }

    /// Motif de non-conformité dérivé de `complianceState` (valeurs Intune).
    private var complianceReason: String {
        switch complianceState.lowercased() {
        case "noncompliant":
            return "L'appareil ne respecte pas une ou plusieurs politiques de conformité Intune."
        case "ingraceperiod":
            return "Non conforme, mais encore dans la période de grâce avant blocage."
        case "conflict":
            return "Conflit entre plusieurs politiques de conformité."
        case "error":
            return "Erreur lors de l'évaluation de la conformité par Intune."
        case "unknown":
            return "État de conformité inconnu — l'appareil n'a pas encore été évalué."
        case "configmanager":
            return "Conformité gérée par Configuration Manager (hors Intune)."
        case "":
            return "État de conformité non renseigné."
        default:
            return "État de conformité signalé par Intune : « \(complianceState) »."
        }
    }

    var storageUsedFormatted: String {
        let usedBytes = totalStorageSpaceInBytes - freeStorageSpaceInBytes
        return "\(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalStorageSpaceInBytes, countStyle: .file))"
    }
}

enum DeviceStatus: String, CaseIterable {
    case healthy = "Healthy"
    case warning = "Warning"
    case stale = "Stale"
    case nonCompliant = "NonCompliant"

    var color: String {
        switch self {
        case .healthy: return "green"
        case .warning: return "orange"
        case .stale: return "gray"
        case .nonCompliant: return "red"
        }
    }

    var icon: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .stale: return "clock.fill"
        case .nonCompliant: return "xmark.circle.fill"
        }
    }
}

/// Type de jointure Azure AD d'un appareil, dérivé du champ `trustType`
/// de l'objet device Entra ID (`/devices`). Permet de distinguer un poste
/// Hybrid Azure AD Join (AD on-prem + Intune) d'un poste Azure AD Join (100% cloud).
enum DeviceJoinType: Equatable {
    /// Hybrid Azure AD Join — joint au domaine AD on-prem ET géré via Intune.
    case hybrid
    /// Azure AD Join — 100% cloud, géré uniquement par Intune.
    case azureAD
    /// Azure AD Registered — appareil personnel enregistré (BYOD).
    case registered
    /// Indéterminé (objet introuvable, permission manquante ou trustType absent).
    case unknown

    init(trustType: String) {
        switch trustType.lowercased() {
        case "serverad": self = .hybrid
        case "azuread": self = .azureAD
        case "workplace": self = .registered
        default: self = .unknown
        }
    }

    /// Libellé court affiché de façon discrète après un scan.
    var label: String {
        switch self {
        case .hybrid: return "Hybride (Intune + AD on-prem)"
        case .azureAD: return "100% Intune (Azure AD)"
        case .registered: return "Azure AD enregistré (BYOD)"
        case .unknown: return "Jointure inconnue"
        }
    }

    var icon: String {
        switch self {
        case .hybrid: return "link"
        case .azureAD: return "cloud"
        case .registered: return "person.badge.shield.checkmark"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension Device {
    /// Crée une instance Device à partir d'un dictionnaire JSON Graph API.
    static func from(graphJSON json: [String: Any]) -> Device {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        func parseDate(_ value: Any?) -> Date? {
            guard let str = value as? String else { return nil }
            return dateFormatter.date(from: str) ?? fallbackFormatter.date(from: str)
        }

        return Device(
            id: json["id"] as? String ?? "",
            deviceName: json["deviceName"] as? String ?? "",
            managedDeviceOwnerType: json["managedDeviceOwnerType"] as? String ?? "",
            operatingSystem: json["operatingSystem"] as? String ?? "",
            osVersion: json["osVersion"] as? String ?? "",
            complianceState: json["complianceState"] as? String ?? "",
            model: json["model"] as? String ?? "",
            manufacturer: json["manufacturer"] as? String ?? "",
            serialNumber: json["serialNumber"] as? String ?? "",
            userPrincipalName: json["userPrincipalName"] as? String ?? "",
            userDisplayName: json["userDisplayName"] as? String ?? "",
            enrolledDateTime: parseDate(json["enrolledDateTime"]),
            lastSyncDateTime: parseDate(json["lastSyncDateTime"]),
            totalStorageSpaceInBytes: json["totalStorageSpaceInBytes"] as? Int64 ?? 0,
            freeStorageSpaceInBytes: json["freeStorageSpaceInBytes"] as? Int64 ?? 0,
            managementAgent: json["managementAgent"] as? String ?? "",
            deviceRegistrationState: json["deviceRegistrationState"] as? String ?? "",
            azureADDeviceId: json["azureADDeviceId"] as? String ?? "",
            deviceCategoryDisplayName: json["deviceCategoryDisplayName"] as? String ?? "",
            notes: json["notes"] as? String ?? ""
        )
    }
}
