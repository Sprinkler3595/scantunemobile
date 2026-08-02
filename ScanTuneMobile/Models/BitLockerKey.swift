import Foundation

/// Représente une clé de récupération BitLocker récupérée via Microsoft Graph API
/// (`informationProtection/bitlocker/recoveryKeys`). Lecture seule.
/// La valeur `key` n'est renseignée qu'après un appel explicite (opération auditée côté Azure).
struct BitLockerKey: Identifiable, Hashable {
    let id: String
    let createdDateTime: Date?
    let volumeType: String
    /// Valeur de la clé de récupération. `nil` tant qu'elle n'a pas été récupérée.
    var key: String?

    // MARK: - Propriétés calculées

    /// Libellé lisible du type de volume.
    var volumeTypeLabel: String {
        switch volumeType.lowercased() {
        case "operatingsystemvolume": return "Volume système (OS)"
        case "fixeddatavolume": return "Volume de données"
        case "removabledatavolume": return "Volume amovible"
        case "none", "": return "—"
        default: return volumeType
        }
    }

    var createdDateFormatted: String {
        guard let date = createdDateTime else { return "Inconnue" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "fr_CA")
        return formatter.string(from: date)
    }
}

extension BitLockerKey {
    /// Crée une instance à partir d'un dictionnaire JSON Graph API.
    static func from(graphJSON json: [String: Any]) -> BitLockerKey {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        func parseDate(_ value: Any?) -> Date? {
            guard let str = value as? String else { return nil }
            return dateFormatter.date(from: str) ?? fallbackFormatter.date(from: str)
        }

        return BitLockerKey(
            id: json["id"] as? String ?? "",
            createdDateTime: parseDate(json["createdDateTime"]),
            volumeType: json["volumeType"] as? String ?? "",
            key: json["key"] as? String
        )
    }
}
