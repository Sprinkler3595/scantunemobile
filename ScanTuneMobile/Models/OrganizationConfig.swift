import Foundation
import Combine

// MARK: - Organization Config

/// Identité d'organisation Azure (App Registration + tenant) utilisée par MSAL.
/// Permet de basculer l'application vers une autre organisation sans recompiler,
/// par exemple lors d'un changement de client / de tenant Entra ID.
struct OrganizationConfig: Codable, Equatable {

    /// Identifiant d'application (client ID) de l'App Registration Azure.
    var clientId: String
    /// Identifiant de l'annuaire (tenant ID) Entra ID.
    var tenantId: String

    /// Autorité MSAL dérivée du tenant.
    var authority: String {
        "https://login.microsoftonline.com/\(tenantId)"
    }

    /// Configuration d'usine : la même App Registration que l'application Desktop ScanTune.
    static let factoryDefault = OrganizationConfig(
        clientId: "6f92a499-4b73-482f-851a-e58bfbdec60d",
        tenantId: "fc0bfa0c-a170-400a-b053-14db47a1a6a6"
    )

    /// Vrai si `clientId` et `tenantId` sont tous deux des GUID Azure valides.
    var isValid: Bool {
        Self.isGuid(clientId) && Self.isGuid(tenantId)
    }

    /// Vrai si la configuration diffère de l'usine (organisation personnalisée).
    var isCustom: Bool { self != .factoryDefault }

    /// Valide un GUID au format `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
    static func isGuid(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespaces)) != nil
    }
}

// MARK: - Organization Config Store

/// Persistance simple de l'identité d'organisation dans `UserDefaults`.
/// Repli sur la configuration d'usine tant qu'aucune bascule n'a été enregistrée.
@MainActor
final class OrganizationConfigStore: ObservableObject {

    @Published private(set) var config: OrganizationConfig

    private let defaults: UserDefaults
    private static let key = "com.scantune.mobile.organization.config.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(OrganizationConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = .factoryDefault
        }
    }

    func update(_ newConfig: OrganizationConfig) {
        self.config = newConfig
        if let data = try? JSONEncoder().encode(newConfig) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
