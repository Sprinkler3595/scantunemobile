import SwiftUI
import MSAL

/// Point d'entrée de ScanTune Mobile.
/// Application 100% LECTURE SEULE — lit les données Intune via Graph API sans aucune modification.
@main
struct ScanTuneMobileApp: App {
    @StateObject private var authService: AuthService
    @StateObject private var graphService: GraphService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.runLegacyMigrationIfNeeded()
        let auth = AuthService()
        let graph = GraphService(authService: auth)
        _authService = StateObject(wrappedValue: auth)
        _graphService = StateObject(wrappedValue: graph)
    }

    /// Migration unique depuis l'ancien format de sessions locales (v1) vers le nouveau
    /// format d'inventaire centralisé SharePoint (v2). Par sécurité, on renomme l'ancien
    /// fichier plutôt que de le supprimer — les données restent sur l'iPhone si besoin.
    private static func runLegacyMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        let migratedKey = "com.scantune.mobile.inventory.migratedToV2"
        guard !defaults.bool(forKey: migratedKey) else { return }

        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let legacy = docs.appendingPathComponent("inventory_sessions.json")
            if fm.fileExists(atPath: legacy.path) {
                let archived = docs.appendingPathComponent("inventory_sessions.legacy.json")
                try? fm.removeItem(at: archived) // idempotent
                try? fm.moveItem(at: legacy, to: archived)
            }
        }
        defaults.set(true, forKey: migratedKey)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(graphService: graphService, authService: authService)
                .environmentObject(authService)
                .environmentObject(graphService)
                .task {
                    await authService.trySilentLogin()
                }
                .onChange(of: scenePhase) { phase in
                    // Re-validation silencieuse du token au retour au premier plan,
                    // pour éviter un « chemin froid » sur la première action.
                    if phase == .active {
                        Task { await authService.revalidateSessionIfNeeded() }
                    }
                }
                .onOpenURL { url in
                    // Transmettre le callback URL à MSAL pour compléter l'authentification
                    MSALPublicClientApplication.handleMSALResponse(
                        url,
                        sourceApplication: nil
                    )
                }
        }
    }
}
