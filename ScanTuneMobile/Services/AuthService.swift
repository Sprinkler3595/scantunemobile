import Foundation
import MSAL

/// Service d'authentification Microsoft Entra ID via MSAL pour iOS.
/// Utilise la même App Registration que l'application Desktop ScanTune.
/// Mode LECTURE SEULE uniquement.
@MainActor
final class AuthService: ObservableObject {

    // MARK: - Configuration (même App Registration que Desktop)

    /// Redirect URI de l'App (indépendant du tenant, défini dans les entitlements/Info.plist).
    private static let redirectUri = "msauth.com.scantune.mobile://auth"

    /// Identité d'organisation active (client ID + tenant ID). Persistée et modifiable
    /// via l'écran « Organisation » pour basculer vers un autre tenant sans recompiler.
    /// Par défaut : la même App Registration que l'application Desktop ScanTune.
    private let organizationStore: OrganizationConfigStore

    /// Configuration Azure courante, exposée à l'UI (bascule d'organisation).
    @Published private(set) var organization: OrganizationConfig

    /// Scopes : lecture Intune/Entra ID + écriture OneDrive + lecture/écriture SharePoint (fichier d'inventaire partagé)
    /// + lecture des clés de récupération BitLocker.
    /// `Sites.ReadWrite.All`, `BitLockerKey.Read.All` et `Device.Read.All` nécessitent un consentement admin du tenant Azure.
    /// `Device.Read.All` sert à lire le `trustType` de l'objet device Entra ID (hybride vs 100% Intune).
    static let scopes: [String] = [
        "DeviceManagementManagedDevices.Read.All",
        "Device.Read.All",
        "User.Read.All",
        "Files.ReadWrite",
        "Sites.ReadWrite.All",
        "BitLockerKey.Read.All"
    ]

    // MARK: - Published state

    @Published var isAuthenticated = false
    @Published var userName: String = ""
    @Published var userEmail: String = ""
    @Published var statusMessage: String = "Déconnecté"
    @Published var isLoading = false

    // MARK: - Private

    private var msalApplication: MSALPublicClientApplication?

    // MARK: - Init

    init(organizationStore: OrganizationConfigStore? = nil) {
        let store = organizationStore ?? OrganizationConfigStore()
        self.organizationStore = store
        self.organization = store.config
        initializeClient()
    }

    // MARK: - Client initialization

    private func initializeClient() {
        do {
            let authorityURL = try MSALAADAuthority(url: URL(string: organization.authority)!)

            let config = MSALPublicClientApplicationConfig(
                clientId: organization.clientId,
                redirectUri: Self.redirectUri,
                authority: authorityURL
            )

            msalApplication = try MSALPublicClientApplication(configuration: config)
        } catch {
            statusMessage = "Erreur d'initialisation MSAL : \(error.localizedDescription)"
        }
    }

    // MARK: - Organization switch

    /// Bascule l'application vers une autre organisation Azure (client ID + tenant ID).
    /// Déconnecte proprement le compte du tenant courant, persiste la nouvelle identité,
    /// puis réinitialise le client MSAL. La prochaine connexion se fera sur le nouveau tenant.
    func updateOrganization(_ newConfig: OrganizationConfig) async {
        // Purger le compte et le token en cache du tenant courant avant de basculer,
        // sinon un identifiant de compte périmé traînerait dans le Keychain.
        await signOut()

        organizationStore.update(newConfig)
        organization = newConfig
        initializeClient()

        AppLog.shared.info("Organisation basculée vers le tenant \(newConfig.tenantId)", category: "auth")
        statusMessage = "Organisation changée — reconnectez-vous"
    }

    // MARK: - Sign In (Interactive)

    func signIn() async {
        guard let application = msalApplication else {
            statusMessage = "Client MSAL non initialisé"
            return
        }

        isLoading = true
        defer { isLoading = false }

        // D'abord tenter un login silencieux
        if await trySilentLogin() {
            return
        }

        // Sinon, login interactif via ASWebAuthenticationSession
        do {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootViewController = windowScene.windows.first?.rootViewController else {
                statusMessage = "Impossible d'obtenir le contrôleur de vue"
                return
            }

            let webviewParameters = MSALWebviewParameters(authPresentationViewController: rootViewController)
            webviewParameters.prefersEphemeralWebBrowserSession = false
            webviewParameters.webviewType = .authenticationSession

            let interactiveParameters = MSALInteractiveTokenParameters(
                scopes: Self.scopes,
                webviewParameters: webviewParameters
            )
            interactiveParameters.promptType = .selectAccount

            let result = try await application.acquireToken(with: interactiveParameters)

            isAuthenticated = true
            userName = result.account.username ?? "Utilisateur"
            userEmail = result.account.username ?? ""
            statusMessage = "Connecté : \(userName)"

            let accountId: String = result.account.identifier ?? ""
            if !accountId.isEmpty {
                storeAccountIdentifier(accountId)
            }
        } catch let error as NSError {
            if error.domain == MSALErrorDomain && error.code == MSALError.userCanceled.rawValue {
                statusMessage = "Connexion annulée"
            } else {
                statusMessage = "Erreur : \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Silent Login

    @discardableResult
    func trySilentLogin() async -> Bool {
        guard let application = msalApplication else { return false }

        guard let accountIdentifier = loadAccountIdentifier(),
              let account = try? application.account(forIdentifier: accountIdentifier) else {
            return false
        }

        do {
            let silentParameters = MSALSilentTokenParameters(scopes: Self.scopes, account: account)
            let result = try await application.acquireTokenSilent(with: silentParameters)

            isAuthenticated = true
            userName = result.account.username ?? "Utilisateur"
            userEmail = result.account.username ?? ""
            statusMessage = "Connecté : \(userName)"
            return true
        } catch {
            return false
        }
    }

    /// Re-valide silencieusement la session au retour au premier plan.
    /// N'affiche jamais d'UI et ne fait rien si l'utilisateur n'est pas déjà
    /// connecté (le lancement gère le cas initial via `trySilentLogin`).
    /// But : rafraîchir le token en cache pour éviter un « chemin froid » sur
    /// la première action après une longue mise en arrière-plan.
    func revalidateSessionIfNeeded() async {
        guard isAuthenticated else { return }
        await trySilentLogin()
    }

    // MARK: - Sign Out

    func signOut() async {
        guard let application = msalApplication else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let accounts = try application.allAccounts()
            for account in accounts {
                try application.remove(account)
            }
        } catch {
            // Continuer même en cas d'erreur de suppression du compte
        }

        clearAccountIdentifier()
        isAuthenticated = false
        userName = ""
        userEmail = ""
        statusMessage = "Déconnecté"
    }

    // MARK: - Get Access Token

    /// Tâche d'acquisition en vol, partagée par les appels concurrents.
    /// Les chargements parallèles (ex. devices + users) réutilisent ainsi la même
    /// tentative au lieu de déclencher plusieurs refresh — voire plusieurs
    /// connexions interactives — simultanés.
    private var tokenRefreshTask: Task<String?, Never>?

    func getAccessToken() async -> String? {
        if let existing = tokenRefreshTask {
            return await existing.value
        }
        let task = Task<String?, Never> { [weak self] in
            await self?.acquireAccessToken() ?? nil
        }
        tokenRefreshTask = task
        defer { tokenRefreshTask = nil }
        return await task.value
    }

    private func acquireAccessToken() async -> String? {
        guard let application = msalApplication else { return nil }

        guard let accountIdentifier = loadAccountIdentifier(),
              let account = try? application.account(forIdentifier: accountIdentifier) else {
            return nil
        }

        do {
            let silentParameters = MSALSilentTokenParameters(scopes: Self.scopes, account: account)
            let result = try await application.acquireTokenSilent(with: silentParameters)
            return result.accessToken
        } catch let error as NSError {
            if error.domain == MSALErrorDomain && error.code == MSALError.interactionRequired.rawValue {
                // Ne tenter une reconnexion interactive que si l'app est au premier
                // plan avec une fenêtre disponible. Sinon (flush réseau en arrière-plan)
                // on échoue proprement : la prochaine action utilisateur relancera l'auth.
                guard canPresentInteractiveLogin else {
                    AppLog.shared.warning("Token interaction requise mais app non au premier plan — report", category: "auth")
                    return nil
                }
                await signIn()
                return await getAccessTokenAfterInteractiveLogin()
            }
            statusMessage = "Erreur de token : \(error.localizedDescription)"
            return nil
        }
    }

    /// Force l'obtention d'un access token neuf en contournant le cache MSAL
    /// (`forceRefresh = true`). Utilisé après un 401 Graph : le token en cache
    /// peut être considéré « valide » par MSAL alors que le serveur le rejette
    /// (révocation, décalage d'horloge, token tué côté Azure).
    /// N'utilise PAS la déduplication `tokenRefreshTask` : on veut explicitement
    /// un token neuf, pas le résultat d'une acquisition « cache OK » en vol.
    func forceRefreshAccessToken() async -> String? {
        guard let application = msalApplication,
              let accountIdentifier = loadAccountIdentifier(),
              let account = try? application.account(forIdentifier: accountIdentifier) else {
            return nil
        }

        do {
            let silentParameters = MSALSilentTokenParameters(scopes: Self.scopes, account: account)
            silentParameters.forceRefresh = true
            let result = try await application.acquireTokenSilent(with: silentParameters)
            return result.accessToken
        } catch let error as NSError {
            if error.domain == MSALErrorDomain && error.code == MSALError.interactionRequired.rawValue {
                guard canPresentInteractiveLogin else {
                    AppLog.shared.warning("Refresh forcé : interaction requise mais app non au premier plan — report", category: "auth")
                    return nil
                }
                await signIn()
                return await getAccessTokenAfterInteractiveLogin()
            }
            AppLog.shared.warning("Refresh forcé échoué : \(error.localizedDescription)", category: "auth")
            return nil
        }
    }

    /// Vrai si une connexion interactive peut être présentée (scène active + fenêtre disponible).
    private var canPresentInteractiveLogin: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { scene in
                scene.activationState == .foregroundActive
                    && scene.windows.contains { $0.rootViewController != nil }
            }
    }

    private func getAccessTokenAfterInteractiveLogin() async -> String? {
        guard let application = msalApplication,
              let accountIdentifier = loadAccountIdentifier(),
              let account = try? application.account(forIdentifier: accountIdentifier) else {
            return nil
        }

        do {
            let silentParameters = MSALSilentTokenParameters(scopes: Self.scopes, account: account)
            let result = try await application.acquireTokenSilent(with: silentParameters)
            return result.accessToken
        } catch {
            return nil
        }
    }

    // MARK: - Keychain Storage (Account Identifier)

    private static let keychainAccountKey = "com.scantune.mobile.account-identifier"

    private func storeAccountIdentifier(_ identifier: String) {
        let data = Data(identifier.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccountKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadAccountIdentifier() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func clearAccountIdentifier() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccountKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}
