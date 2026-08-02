import SwiftUI

/// Vue principale de ScanTune Mobile.
/// - Non connecté : écran de login avec bouton Microsoft.
/// - Connecté : TabView Scanner + Inventaire avec badge "Lecture seule".
struct ContentView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var graphService: GraphService

    @StateObject private var scannerVM: ScannerViewModel
    @StateObject private var inventoryVM: InventoryViewModel
    @StateObject private var settingsStore: InventorySettingsStore
    @StateObject private var queueStore: InventoryQueueStore
    @StateObject private var snapshotStore: DeviceSnapshotStore

    /// Conservé pour pouvoir invalider son cache lors de la déconnexion.
    private let sharePoint: SharePointInventoryService

    @State private var selectedTab = 0
    @State private var showLogoutConfirm = false

    init(graphService: GraphService, authService: AuthService) {
        let settings = InventorySettingsStore()
        let sharePoint = SharePointInventoryService(authService: authService)
        let queue = InventoryQueueStore(sharePoint: sharePoint, settingsStore: settings)
        let snapshots = DeviceSnapshotStore()

        self.sharePoint = sharePoint
        _settingsStore = StateObject(wrappedValue: settings)
        _queueStore = StateObject(wrappedValue: queue)
        _snapshotStore = StateObject(wrappedValue: snapshots)
        _scannerVM = StateObject(wrappedValue: ScannerViewModel(graphService: graphService))
        _inventoryVM = StateObject(
            wrappedValue: InventoryViewModel(
                graphService: graphService,
                authService: authService,
                sharePointService: sharePoint,
                queueStore: queue,
                settingsStore: settings,
                snapshotStore: snapshots
            )
        )
    }

    var body: some View {
        Group {
            if authService.isAuthenticated {
                authenticatedView
            } else {
                loginView
            }
        }
    }

    // MARK: - Login View

    private var loginView: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo & titre
            VStack(spacing: 16) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)

                Text("ScanTune Mobile")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Gestion d'inventaire IT via Intune")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                readOnlyBadge
            }

            Spacer()

            // Bouton Microsoft Sign-In
            Button {
                Task {
                    await authService.signIn()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.title3)
                    Text("Se connecter avec Microsoft")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(authService.isLoading)

            if authService.isLoading {
                ProgressView("Connexion en cours...")
                    .padding(.top, 8)
            }

            if !authService.statusMessage.isEmpty && authService.statusMessage != "Déconnecté" {
                Text(authService.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
                .frame(height: 40)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Authenticated View

    private var authenticatedView: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                ScannerView(viewModel: scannerVM)
                    .tabItem {
                        Label("Scanner", systemImage: "qrcode.viewfinder")
                    }
                    .tag(0)

                InventoryView(viewModel: inventoryVM)
                    .tabItem {
                        Label("Inventaire", systemImage: "checklist")
                    }
                    .tag(1)
            }
            .onChange(of: selectedTab) { newTab in
                // Chaque retour sur l'onglet Scanner repart d'un état neuf.
                if newTab == 0 {
                    scannerVM.resetScanner()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.blue)
                        Text(authService.userName)
                            .font(.subheadline)
                            .lineLimit(1)
                        readOnlyBadge
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        // Avertir si des vérifications ne sont pas encore synchronisées :
                        // le reset les supprimerait définitivement.
                        if queueStore.pending.isEmpty {
                            performLogout()
                        } else {
                            showLogoutConfirm = true
                        }
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Synchronisation incomplète",
                isPresented: $showLogoutConfirm,
                titleVisibility: .visible
            ) {
                Button("Se déconnecter quand même", role: .destructive) {
                    performLogout()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("\(queueStore.pending.count) vérification(s) ne sont pas encore synchronisées vers SharePoint et seront définitivement perdues si vous vous déconnectez maintenant.")
            }
        }
    }

    /// Remise à zéro complète puis déconnexion : l'app redevient comme à la 1re installation.
    private func performLogout() {
        Task {
            resetAllLocalData()
            await authService.signOut()
        }
    }

    // MARK: - Reset

    /// Efface toutes les données locales pour que la prochaine connexion reparte
    /// comme à la première installation : réglages SharePoint, file d'attente,
    /// snapshot d'appareils, et cache de résolution SharePoint.
    private func resetAllLocalData() {
        settingsStore.reset()
        queueStore.clear()
        snapshotStore.clear()
        sharePoint.invalidateCache()
    }

    // MARK: - Read-Only Badge

    private var readOnlyBadge: some View {
        Text("Lecture seule Intune")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.15))
            .foregroundColor(.orange)
            .cornerRadius(4)
    }
}
