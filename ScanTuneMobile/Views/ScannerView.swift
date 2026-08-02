import SwiftUI

/// Vue Scanner QR — scanne un code et recherche l'appareil correspondant dans Intune.
/// Mode lecture seule : aucune modification des données.
/// Caméra toujours active, aucune historique affichée.
struct ScannerView: View {
    @ObservedObject var viewModel: ScannerViewModel

    var body: some View {
        ZStack {
            QRScannerView(
                onCodeScanned: { code in
                    viewModel.handleScannedCode(code)
                },
                onError: { error in
                    viewModel.handleScanError(error)
                },
                resetToken: $viewModel.scanSessionToken
            )
            .ignoresSafeArea()

            if viewModel.isSearching {
                VStack {
                    Spacer()
                    ProgressView("Recherche de l'appareil...")
                        .font(.headline)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    Spacer()
                }
            }
        }
        .sheet(
            isPresented: $viewModel.showDeviceDetail,
            onDismiss: { viewModel.resetScanner() }
        ) {
            if let device = viewModel.foundDevice {
                NavigationStack {
                    DeviceDetailView(
                        device: device,
                        graphService: viewModel.graphService
                    )
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Fermer") {
                                viewModel.showDeviceDetail = false
                            }
                        }
                    }
                }
                .presentationDetents([.large])
            }
        }
        .alert("Erreur", isPresented: $viewModel.showError) {
            Button("Rescanner") {
                viewModel.resetScanner()
            }
            Button("OK", role: .cancel) {
                viewModel.resetScanner()
            }
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}
