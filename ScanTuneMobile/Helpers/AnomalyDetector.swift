import Foundation

/// Types d'anomalie remontés par `AnomalyDetector`.
enum AnomalyKind: String, Codable, CaseIterable, Hashable {
    /// Appareil inscrit Intune mais sans synchronisation depuis plus de 90 jours.
    case staleSync
    /// Appareil non-compliant ET assigné à un utilisateur actif.
    case nonCompliantActiveUser
    /// Deux appareils Intune distincts partagent le même numéro de série.
    case duplicateSerial

    var title: String {
        switch self {
        case .staleSync: return "Sync ancienne (>90j)"
        case .nonCompliantActiveUser: return "Non-conforme + utilisateur actif"
        case .duplicateSerial: return "Doublon de n° série"
        }
    }

    var icon: String {
        switch self {
        case .staleSync: return "clock.badge.exclamationmark"
        case .nonCompliantActiveUser: return "exclamationmark.shield.fill"
        case .duplicateSerial: return "doc.on.doc.fill"
        }
    }

    /// Niveau de sévérité — utilisé pour le tri et la couleur d'affichage.
    var severity: AnomalySeverity {
        switch self {
        case .duplicateSerial: return .high
        case .nonCompliantActiveUser: return .high
        case .staleSync: return .medium
        }
    }
}

enum AnomalySeverity: Int, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: AnomalySeverity, rhs: AnomalySeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var colorName: String {
        switch self {
        case .high: return "red"
        case .medium: return "orange"
        case .low: return "yellow"
        }
    }
}

/// Une anomalie détectée pour un device donné.
struct DeviceAnomaly: Identifiable, Hashable {
    let deviceId: String
    let kind: AnomalyKind
    let detail: String

    var id: String { "\(deviceId)|\(kind.rawValue)" }
    var severity: AnomalySeverity { kind.severity }
}

/// Règles de détection côté client appliquées aux devices Intune en cache.
/// Pas d'I/O, pas d'appel réseau — entrée/sortie en mémoire.
enum AnomalyDetector {

    /// Seuil "stale sync" en jours.
    static let staleSyncDays = 90

    /// Analyse le parc et retourne toutes les anomalies détectées.
    ///
    /// - Parameters:
    ///   - devices: parc Intune (typiquement `scopedDevices` du VM).
    ///   - usersByUPN: dictionnaire UPN→User pour évaluer si l'utilisateur
    ///     assigné est actif. Si nil, la règle `nonCompliantActiveUser`
    ///     est désactivée.
    static func analyze(
        devices: [Device],
        usersByUPN: [String: User]? = nil
    ) -> [DeviceAnomaly] {
        var results: [DeviceAnomaly] = []

        // 1. Stale sync.
        for device in devices {
            if device.daysSinceLastSync > staleSyncDays {
                results.append(DeviceAnomaly(
                    deviceId: device.id,
                    kind: .staleSync,
                    detail: "Dernière sync il y a \(device.daysSinceLastSync) jours"
                ))
            }
        }

        // 2. Non-compliant + user actif.
        if let usersByUPN {
            for device in devices where !device.isCompliant {
                let upn = device.userPrincipalName.lowercased()
                guard !upn.isEmpty, let user = usersByUPN[upn], user.accountEnabled else {
                    continue
                }
                results.append(DeviceAnomaly(
                    deviceId: device.id,
                    kind: .nonCompliantActiveUser,
                    detail: "\(device.complianceState) — \(user.displayName)"
                ))
            }
        }

        // 3. Doublons de numéro de série (case-insensitive, ignore vides).
        var serialGroups: [String: [Device]] = [:]
        for device in devices {
            let key = device.serialNumber.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            serialGroups[key, default: []].append(device)
        }
        for (_, dups) in serialGroups where dups.count > 1 {
            for device in dups {
                let others = dups.filter { $0.id != device.id }
                    .map(\.deviceName)
                    .joined(separator: ", ")
                results.append(DeviceAnomaly(
                    deviceId: device.id,
                    kind: .duplicateSerial,
                    detail: "Partagé avec : \(others)"
                ))
            }
        }

        return results
    }

    /// Indexation `deviceId → [anomalies]` pour lookup O(1) côté UI.
    static func indexByDevice(_ anomalies: [DeviceAnomaly]) -> [String: [DeviceAnomaly]] {
        Dictionary(grouping: anomalies, by: \.deviceId)
    }
}
