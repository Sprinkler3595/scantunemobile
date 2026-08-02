import Foundation
import Combine

// MARK: - Device Scope (périmètre d'inventaire)

/// Types d'appareils à inclure dans l'inventaire. Le dénominateur « X / Y PC vérifiés »
/// est calculé sur les devices dont `operatingSystem` matche l'un des scopes actifs.
enum DeviceScope: String, Codable, CaseIterable, Identifiable, Hashable {
    case windows = "Windows"
    case macOS = "macOS"
    case iOS = "iOS"
    case android = "Android"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .windows: return "desktopcomputer"
        case .macOS: return "laptopcomputer"
        case .iOS: return "iphone"
        case .android: return "candybarphone"
        }
    }

    /// Teste si un `operatingSystem` Intune matche ce scope (tolérant à la casse et aux variantes).
    func matches(operatingSystem os: String) -> Bool {
        let lower = os.lowercased()
        switch self {
        case .windows:
            return lower.contains("windows")
        case .macOS:
            // Intune peut retourner "macOS" ou "Mac OS X"
            return lower.contains("mac")
        case .iOS:
            // Couvre iOS et iPadOS
            return lower.contains("ios") || lower.contains("ipad")
        case .android:
            return lower.contains("android")
        }
    }
}

// MARK: - Inventory Settings

/// Paramètres persistants de l'onglet Inventaire, configurés via l'écran Réglages.
/// Persistés dans `UserDefaults` via `InventorySettingsStore`.
struct InventorySettings: Codable, Equatable {
    /// URL complète du site SharePoint, ex: `https://contoso.sharepoint.com/sites/IT`.
    var sharePointSiteUrl: String
    /// Nom de la bibliothèque de documents. Par défaut : `Documents`.
    var documentLibraryName: String
    /// Nom du fichier JSON. Par défaut : `inventaire-<annéeCourante>.json`.
    var fileName: String
    /// Année d'inventaire (permet de rouvrir un inventaire antérieur).
    var inventoryYear: Int
    /// Périmètre d'appareils actif. Par défaut : Windows + macOS.
    var activeScopes: Set<DeviceScope>
    /// Pointeur direct vers la bibliothèque (drive) résolue via le sélecteur.
    /// Quand renseigné, le service l'utilise directement et court-circuite la
    /// résolution `URL du site → bibliothèque`. nil = repli sur les champs texte.
    var driveId: String? = nil
    /// Pointeur direct vers le fichier résolu (sélection d'un fichier existant,
    /// y compris dans un sous-dossier). nil = fichier adressé par nom relatif au
    /// dossier parent (sera créé au 1er upload s'il n'existe pas).
    var itemId: String? = nil
    /// Dossier parent (itemId) où créer le fichier quand `itemId` est nil et que la
    /// cible n'est pas la racine de la bibliothèque. nil = racine.
    var parentItemId: String? = nil

    static var defaults: InventorySettings {
        let year = Calendar.current.component(.year, from: Date())
        return InventorySettings(
            sharePointSiteUrl: "",
            documentLibraryName: "Documents",
            fileName: "inventaire-\(year).json",
            inventoryYear: year,
            activeScopes: [.windows, .macOS]
        )
    }

    /// Vrai si tous les champs requis pour atteindre le fichier SharePoint sont remplis.
    var isConfigured: Bool {
        !sharePointSiteUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !documentLibraryName.trimmingCharacters(in: .whitespaces).isEmpty
            && !fileName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// URL normalisée (sans query string, sans trailing slash, host en minuscules).
    /// Retourne nil si non parsable.
    func normalizedSiteUrl() -> URL? {
        let raw = sharePointSiteUrl.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: raw) else { return nil }
        components.query = nil
        components.fragment = nil
        if let host = components.host {
            components.host = host.lowercased()
        }
        // Retirer trailing slash du path
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}

// MARK: - Inventory Settings Store

/// Persistance simple des réglages dans `UserDefaults`.
@MainActor
final class InventorySettingsStore: ObservableObject {

    @Published private(set) var settings: InventorySettings

    private let defaults: UserDefaults
    private static let key = "com.scantune.mobile.inventory.settings.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(InventorySettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .defaults
        }
    }

    func update(_ newSettings: InventorySettings) {
        self.settings = newSettings
        if let data = try? JSONEncoder().encode(newSettings) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Remet les réglages à zéro (déconnexion) : supprime la persistance et
    /// repart des valeurs par défaut, comme à la première installation.
    func reset() {
        defaults.removeObject(forKey: Self.key)
        self.settings = .defaults
    }
}
