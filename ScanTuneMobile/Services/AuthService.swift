import Foundation
import MSAL

/// Service d'authentification Microsoft Entra ID via MSAL pour iOS.
/// Utilise la même App Registration que l'application Desktop ScanTune.
/// Mode LECTURE SEULE uniquement.
@MainActor
final class AuthService: ObservableObject {

    // MARK: - Configuration

    /// Tenant et App Registration utilisés pour la connexion (voir `TenantConfiguration`).
    /// Modifiables depuis l'écran de connexion via `updateTenantConfiguration(_:)`.
    @Published private(set) var tenantConfiguration: TenantConfiguration

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
    private let tenantStore: TenantConfigurationStore

    // MARK: - Init

    init(tenantStore: TenantConfigurationStore = TenantConfigurationStore()) {
        self.tenantStore = tenantStore
        self.tenantConfiguration = tenantStore.load()
        initializeClient()
    }

    // MARK: - Client initialization

    private func initializeClient() {
        msalApplication = nil
        do {
            guard let url = URL(string: tenantConfiguration.authority) else {
                statusMessage = "Tenant invalide : \(tenantConfiguration.tenantId)"
                return
            }
            let authorityURL = try MSALAADAuthority(url: url)

            let config = MSALPublicClientApplicationConfig(
                clientId: tenantConfiguration.clientId,
                redirectUri: TenantConfiguration.redirectUri,
                authority: authorityURL
            )

            msalApplication = try MSALPublicClientApplication(configuration: config)
        } catch {
            statusMessage = "Erreur d'initialisation MSAL : \(error.localizedDescription)"
        }
    }

    // MARK: - Tenant

    /// Change le tenant (et/ou l'App Registration) de connexion.
    /// Uniquement hors session : les comptes MSAL en cache de l'ancien tenant sont
    /// supprimés puis le client MSAL est recréé sur la nouvelle autorité.
    /// La prochaine connexion sera interactive.
    func updateTenantConfiguration(_ newConfiguration: TenantConfiguration) {
        guard !isAuthenticated else { return }
        let configuration = newConfiguration.normalized
        guard configuration.isValid, configuration != tenantConfiguration else { return }

        // Purger les comptes de l'ancien tenant pour éviter qu'un login silencieux
        // ne réutilise un compte qui n'appartient pas au nouveau tenant.
        if let application = msalApplication,
           let accounts = try? application.allAccounts() {
            for account in accounts {
                try? application.remove(account)
            }
        }
        clearAccountIdentifier()

        tenantStore.save(configuration)
        tenantConfiguration = configuration
        statusMessage = "Déconnecté"
        initializeClient()
        AppLog.shared.info("Tenant de connexion changé : \(configuration.tenantId)", category: "auth")
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
