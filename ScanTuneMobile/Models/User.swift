import Foundation

/// Représente un utilisateur Entra ID récupéré via Microsoft Graph API (lecture seule).
struct User: Identifiable, Codable, Hashable {
    let id: String
    let displayName: String
    let userPrincipalName: String
    let mail: String
    let jobTitle: String
    let department: String
    let companyName: String
    let officeLocation: String
    let mobilePhone: String
    let accountEnabled: Bool

    var initials: String {
        let parts = displayName.split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let last = parts.count > 1 ? parts.last?.prefix(1) ?? "" : ""
        return "\(first)\(last)".uppercased()
    }
}

extension User {
    /// Crée une instance User à partir d'un dictionnaire JSON Graph API.
    static func from(graphJSON json: [String: Any]) -> User {
        return User(
            id: json["id"] as? String ?? "",
            displayName: json["displayName"] as? String ?? "",
            userPrincipalName: json["userPrincipalName"] as? String ?? "",
            mail: json["mail"] as? String ?? "",
            jobTitle: json["jobTitle"] as? String ?? "",
            department: json["department"] as? String ?? "",
            companyName: json["companyName"] as? String ?? "",
            officeLocation: json["officeLocation"] as? String ?? "",
            mobilePhone: json["mobilePhone"] as? String ?? "",
            accountEnabled: json["accountEnabled"] as? Bool ?? false
        )
    }
}
