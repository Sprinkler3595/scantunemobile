import Foundation

// MARK: - Tenant Configuration

/// Tenant Microsoft Entra ID (et App Registration) auquel l'application se connecte.
/// Persisté dans `UserDefaults` via `TenantConfigurationStore`, modifiable depuis l'écran
/// de connexion. Conservé lors d'une déconnexion : c'est un réglage de l'appareil,
/// pas une donnée de session.
struct TenantConfiguration: Codable, Equatable {
    /// ID du tenant (GUID) ou domaine vérifié, ex: `contoso.onmicrosoft.com`.
    var tenantId: String
    /// Client ID (Application ID) de l'App Registration dans ce tenant.
    var clientId: String

    /// Tenant et App Registration d'origine (même App Registration que Desktop).
    static let defaults = TenantConfiguration(
        tenantId: "fc0bfa0c-a170-400a-b053-14db47a1a6a6",
        clientId: "6f92a499-4b73-482f-851a-e58bfbdec60d"
    )

    /// Redirect URI MSAL : lié au bundle ID de l'app, identique quel que soit le tenant.
    /// Doit être déclaré dans l'App Registration de chaque tenant.
    static let redirectUri = "msauth.com.scantune.mobile://auth"

    var authority: String {
        "https://login.microsoftonline.com/\(tenantId)"
    }

    /// Retire les espaces et passe en minuscules (GUID et domaines sont insensibles à la casse).
    var normalized: TenantConfiguration {
        TenantConfiguration(
            tenantId: tenantId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    var isValid: Bool {
        Self.isValidTenantId(tenantId) && Self.isValidClientId(clientId)
    }

    var isDefault: Bool {
        normalized == Self.defaults
    }

    // MARK: - Validation

    /// Accepte un GUID ou un nom de domaine (ex: `contoso.onmicrosoft.com`, `contoso.ch`).
    /// `common` / `organizations` / `consumers` sont refusés : l'app cible un tenant précis.
    static func isValidTenantId(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil { return true }
        let domainPattern = #"^(?=.{4,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$"#
        return trimmed.range(of: domainPattern, options: .regularExpression) != nil
    }

    static func isValidClientId(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
}

// MARK: - Tenant Configuration Store

/// Persistance simple de la configuration du tenant dans `UserDefaults`.
struct TenantConfigurationStore {

    private let defaults: UserDefaults
    private static let key = "com.scantune.mobile.tenant.configuration"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> TenantConfiguration {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(TenantConfiguration.self, from: data),
              decoded.isValid else {
            return .defaults
        }
        return decoded
    }

    func save(_ configuration: TenantConfiguration) {
        // Ne rien persister pour la configuration d'origine : une future mise à jour
        // des valeurs par défaut s'appliquera alors automatiquement.
        if configuration.isDefault {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
