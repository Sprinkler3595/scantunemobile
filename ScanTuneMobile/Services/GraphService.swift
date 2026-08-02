import Foundation

/// Service Graph API en LECTURE SEULE pour récupérer les appareils Intune et utilisateurs Entra ID.
/// Aucune opération d'écriture n'est effectuée.
@MainActor
final class GraphService: ObservableObject {

    // MARK: - Dependencies

    private let authService: AuthService

    // MARK: - Published state

    @Published var isLoading = false
    @Published var loadedDeviceCount = 0
    @Published var errorMessage: String?

    // MARK: - Cache

    private var cachedDevices: [Device]?
    private var deviceCacheTimestamp = Date.distantPast
    private var cachedUsers: [User]?
    private var userCacheTimestamp = Date.distantPast
    private let cacheDuration: TimeInterval = 300 // 5 minutes

    private var isDeviceCacheValid: Bool {
        cachedDevices != nil && Date().timeIntervalSince(deviceCacheTimestamp) < cacheDuration
    }

    private var isUserCacheValid: Bool {
        cachedUsers != nil && Date().timeIntervalSince(userCacheTimestamp) < cacheDuration
    }

    // MARK: - Graph API config

    private static let graphBaseURL = "https://graph.microsoft.com/v1.0"

    private static let deviceSelectProperties = [
        "id", "deviceName", "managedDeviceOwnerType",
        "operatingSystem", "osVersion", "complianceState",
        "model", "manufacturer", "serialNumber",
        "userPrincipalName", "userDisplayName",
        "enrolledDateTime", "lastSyncDateTime",
        "totalStorageSpaceInBytes", "freeStorageSpaceInBytes",
        "managementAgent", "deviceRegistrationState",
        "azureADDeviceId", "deviceCategoryDisplayName",
        "notes"
    ]

    private static let userSelectProperties = [
        "id", "displayName", "userPrincipalName", "mail",
        "jobTitle", "department", "companyName", "officeLocation",
        "mobilePhone", "accountEnabled"
    ]

    // MARK: - Init

    init(authService: AuthService) {
        self.authService = authService
    }

    // MARK: - Private HTTP helpers

    private func makeAuthenticatedRequest(url: URL) async throws -> Data {
        guard let token = await authService.getAccessToken() else {
            throw GraphError.notAuthenticated
        }

        let (data, httpResponse) = try await sendRequest(url: url, token: token)

        // Token rejeté côté serveur malgré un cache MSAL « valide » (révocation,
        // décalage d'horloge, token tué côté Azure) : on force un token neuf et
        // on retente UNE seule fois avant d'abandonner.
        if httpResponse.statusCode == 401 {
            AppLog.shared.warning("Graph 401 sur \(url.path) — refresh forcé puis retry", category: "auth")
            guard let freshToken = await authService.forceRefreshAccessToken() else {
                throw GraphError.httpError(statusCode: 401, data: data)
            }
            let (retryData, retryResponse) = try await sendRequest(url: url, token: freshToken)
            guard (200...299).contains(retryResponse.statusCode) else {
                AppLog.shared.error(
                    "Graph HTTP \(retryResponse.statusCode) on \(url.path) (après retry)",
                    category: "graph"
                )
                throw GraphError.httpError(statusCode: retryResponse.statusCode, data: retryData)
            }
            return retryData
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            AppLog.shared.error(
                "Graph HTTP \(httpResponse.statusCode) on \(url.path)",
                category: "graph"
            )
            throw GraphError.httpError(statusCode: httpResponse.statusCode, data: data)
        }

        return data
    }

    /// Envoie une requête GET authentifiée et renvoie le couple (données, réponse HTTP).
    /// Ne juge pas le code de statut — c'est l'appelant qui décide (retry, erreur…).
    private func sendRequest(url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GraphError.invalidResponse
        }

        return (data, httpResponse)
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GraphError.invalidJSON
        }
        return json
    }

    // MARK: - Devices (READ-ONLY)

    func getAllDevices() async throws -> [Device] {
        if isDeviceCacheValid, let cached = cachedDevices {
            return cached
        }

        isLoading = true
        loadedDeviceCount = 0
        errorMessage = nil
        defer { isLoading = false }

        var allDevices: [Device] = []
        let selectQuery = Self.deviceSelectProperties.joined(separator: ",")
        var urlString = "\(Self.graphBaseURL)/deviceManagement/managedDevices?$select=\(selectQuery)&$top=100"

        while true {
            guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
            let data = try await makeAuthenticatedRequest(url: url)
            let json = try parseJSON(data)

            if let values = json["value"] as? [[String: Any]] {
                let devices = values.map { Device.from(graphJSON: $0) }
                allDevices.append(contentsOf: devices)
                loadedDeviceCount = allDevices.count
            }

            if let nextLink = json["@odata.nextLink"] as? String {
                urlString = nextLink
            } else {
                break
            }
        }

        cachedDevices = allDevices
        deviceCacheTimestamp = Date()

        AppLog.shared.info("Loaded \(allDevices.count) device(s) from Graph", category: "graph")

        return allDevices
    }

    func getDeviceById(_ deviceId: String) async throws -> Device? {
        let selectQuery = Self.deviceSelectProperties.joined(separator: ",")
        let urlString = "\(Self.graphBaseURL)/deviceManagement/managedDevices/\(deviceId)?$select=\(selectQuery)"

        guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
        let data = try await makeAuthenticatedRequest(url: url)
        let json = try parseJSON(data)

        return Device.from(graphJSON: json)
    }

    func searchDevices(query: String) async throws -> [Device] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return try await getAllDevices()
        }

        let escaped = query.replacingOccurrences(of: "'", with: "''")
        let filter = "contains(deviceName,'\(escaped)') or contains(serialNumber,'\(escaped)') or contains(userDisplayName,'\(escaped)')"
        let selectQuery = Self.deviceSelectProperties.joined(separator: ",")
        let encodedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        var urlString = "\(Self.graphBaseURL)/deviceManagement/managedDevices?$select=\(selectQuery)&$filter=\(encodedFilter)&$top=100"

        var results: [Device] = []

        while true {
            guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
            let data = try await makeAuthenticatedRequest(url: url)
            let json = try parseJSON(data)

            if let values = json["value"] as? [[String: Any]] {
                results.append(contentsOf: values.map { Device.from(graphJSON: $0) })
            }

            if let nextLink = json["@odata.nextLink"] as? String {
                urlString = nextLink
            } else {
                break
            }
        }

        return results
    }

    /// Recherche un appareil par numéro de série (utilisé après scan QR).
    func findDeviceBySerialNumber(_ serialNumber: String) async throws -> Device? {
        try await findDevicesBySerialNumber(serialNumber).first
    }

    /// Retourne TOUS les appareils Intune partageant un même numéro de série.
    /// Utilisé pour détecter les doublons (poste inscrit deux fois, même série
    /// sur deux objets distincts) et indiquer lesquels après un scan.
    func findDevicesBySerialNumber(_ serialNumber: String) async throws -> [Device] {
        let trimmed = serialNumber.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let escaped = trimmed.replacingOccurrences(of: "'", with: "''")
        let filter = "serialNumber eq '\(escaped)'"
        let selectQuery = Self.deviceSelectProperties.joined(separator: ",")
        let encodedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        var urlString = "\(Self.graphBaseURL)/deviceManagement/managedDevices?$select=\(selectQuery)&$filter=\(encodedFilter)"

        var results: [Device] = []

        while true {
            guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
            let data = try await makeAuthenticatedRequest(url: url)
            let json = try parseJSON(data)

            if let values = json["value"] as? [[String: Any]] {
                results.append(contentsOf: values.map { Device.from(graphJSON: $0) })
            }

            if let nextLink = json["@odata.nextLink"] as? String {
                urlString = nextLink
            } else {
                break
            }
        }

        return results
    }

    /// Récupère le type de jointure Azure AD d'un appareil via l'objet device
    /// Entra ID correspondant (`/devices`, champ `trustType`), retrouvé par son
    /// `azureADDeviceId`. Distingue Hybrid Azure AD Join, Azure AD Join (cloud)
    /// et Azure AD Registered (BYOD). Nécessite la permission `Device.Read.All`.
    /// Renvoie `.unknown` si l'objet est introuvable ou le champ absent.
    func getDeviceJoinType(azureADDeviceId: String) async throws -> DeviceJoinType {
        let trimmed = azureADDeviceId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .unknown }

        let escaped = trimmed.replacingOccurrences(of: "'", with: "''")
        let filter = "deviceId eq '\(escaped)'"
        let encodedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        let urlString = "\(Self.graphBaseURL)/devices?$filter=\(encodedFilter)&$select=trustType"

        guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
        let data = try await makeAuthenticatedRequest(url: url)
        let json = try parseJSON(data)

        guard let values = json["value"] as? [[String: Any]],
              let first = values.first,
              let trustType = first["trustType"] as? String else {
            return .unknown
        }

        return DeviceJoinType(trustType: trustType)
    }

    // MARK: - BitLocker (READ-ONLY, sensible & audité)

    /// Liste les clés de récupération BitLocker associées à un appareil (par Azure AD device ID).
    /// Retourne uniquement les métadonnées (id, date, type de volume) — PAS la valeur de la clé.
    /// Le filtre `deviceId` est obligatoire côté Graph pour cet endpoint.
    func getBitLockerRecoveryKeys(azureADDeviceId: String) async throws -> [BitLockerKey] {
        let trimmed = azureADDeviceId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let escaped = trimmed.replacingOccurrences(of: "'", with: "''")
        let filter = "deviceId eq '\(escaped)'"
        let encodedFilter = filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filter
        var urlString = "\(Self.graphBaseURL)/informationProtection/bitlocker/recoveryKeys?$filter=\(encodedFilter)"

        var results: [BitLockerKey] = []

        while true {
            guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
            let data = try await makeAuthenticatedRequest(url: url)
            let json = try parseJSON(data)

            if let values = json["value"] as? [[String: Any]] {
                results.append(contentsOf: values.map { BitLockerKey.from(graphJSON: $0) })
            }

            if let nextLink = json["@odata.nextLink"] as? String {
                urlString = nextLink
            } else {
                break
            }
        }

        AppLog.shared.info("BitLocker: \(results.count) clé(s) listée(s) pour le device", category: "graph")

        return results
    }

    /// Récupère la VALEUR d'une clé de récupération BitLocker par son id.
    /// Opération sensible et auditée côté Azure (`$select=key`).
    func getBitLockerKeyValue(keyId: String) async throws -> String {
        let urlString = "\(Self.graphBaseURL)/informationProtection/bitlocker/recoveryKeys/\(keyId)?$select=key"

        guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
        let data = try await makeAuthenticatedRequest(url: url)
        let json = try parseJSON(data)

        return json["key"] as? String ?? ""
    }

    // MARK: - Users (READ-ONLY)

    func getAllUsers() async throws -> [User] {
        if isUserCacheValid, let cached = cachedUsers {
            return cached
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var allUsers: [User] = []
        let selectQuery = Self.userSelectProperties.joined(separator: ",")
        var urlString = "\(Self.graphBaseURL)/users?$select=\(selectQuery)&$top=100"

        while true {
            guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
            let data = try await makeAuthenticatedRequest(url: url)
            let json = try parseJSON(data)

            if let values = json["value"] as? [[String: Any]] {
                allUsers.append(contentsOf: values.map { User.from(graphJSON: $0) })
            }

            if let nextLink = json["@odata.nextLink"] as? String {
                urlString = nextLink
            } else {
                break
            }
        }

        cachedUsers = allUsers
        userCacheTimestamp = Date()

        return allUsers
    }

    func getUserById(_ userId: String) async throws -> User? {
        let selectQuery = Self.userSelectProperties.joined(separator: ",")
        let urlString = "\(Self.graphBaseURL)/users/\(userId)?$select=\(selectQuery)"

        guard let url = URL(string: urlString) else { throw GraphError.invalidURL }
        let data = try await makeAuthenticatedRequest(url: url)
        let json = try parseJSON(data)

        return User.from(graphJSON: json)
    }

    // MARK: - Companies & Departments (dérivés des users)

    /// Extrait la liste des entreprises et des départements depuis Entra ID.
    /// Les utilisateurs sans companyName/department sont groupés sous "(Sans entreprise)" / "(Sans département)".
    /// Retourne une liste d'entreprises triées et un dictionnaire entreprise → départements triés.
    func getCompaniesAndDepartments() async throws
        -> (companies: [String], departmentsByCompany: [String: [String]])
    {
        let users = try await getAllUsers()

        let noCompanyLabel = "(Sans entreprise)"
        let noDepartmentLabel = "(Sans département)"

        var grouped: [String: Set<String>] = [:]

        for user in users {
            let company = user.companyName.trimmingCharacters(in: .whitespaces)
            let department = user.department.trimmingCharacters(in: .whitespaces)
            let companyKey = company.isEmpty ? noCompanyLabel : company
            let departmentKey = department.isEmpty ? noDepartmentLabel : department
            grouped[companyKey, default: []].insert(departmentKey)
        }

        let locale = Locale(identifier: "fr_CA")
        let companies = grouped.keys.sorted {
            $0.compare($1, options: .caseInsensitive, range: nil, locale: locale) == .orderedAscending
        }

        var departmentsByCompany: [String: [String]] = [:]
        for (company, deps) in grouped {
            departmentsByCompany[company] = deps.sorted {
                $0.compare($1, options: .caseInsensitive, range: nil, locale: locale) == .orderedAscending
            }
        }

        return (companies, departmentsByCompany)
    }

    // MARK: - Cache management

    func refreshDeviceCache() async throws {
        cachedDevices = nil
        _ = try await getAllDevices()
    }

    func refreshUserCache() async throws {
        cachedUsers = nil
        _ = try await getAllUsers()
    }

    func invalidateAllCaches() {
        cachedDevices = nil
        cachedUsers = nil
    }

    // MARK: - Connection test

    func testConnection() async -> Bool {
        guard let token = await authService.getAccessToken() else { return false }

        guard let url = URL(string: "\(Self.graphBaseURL)/me") else { return false }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum GraphError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case invalidJSON
    case httpError(statusCode: Int, data: Data)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Non authentifié. Veuillez vous connecter."
        case .invalidURL:
            return "URL invalide."
        case .invalidResponse:
            return "Réponse invalide du serveur."
        case .invalidJSON:
            return "Format de données invalide."
        case .httpError(let statusCode, let data):
            let body = String(data: data, encoding: .utf8) ?? ""
            return "Erreur HTTP \(statusCode) : \(body)"
        }
    }
}
