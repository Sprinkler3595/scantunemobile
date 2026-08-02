import Foundation
import SwiftUI

/// ViewModel pour la vue Scanner QR. Lecture seule — recherche d'appareil après scan.
@MainActor
final class ScannerViewModel: ObservableObject {

    // MARK: - Dependencies

    /// Exposé pour que la vue puisse le transmettre à `DeviceDetailView`
    /// (chargement du profil utilisateur après un scan).
    let graphService: GraphService

    // MARK: - Published state

    @Published var scannedCode: String?
    @Published var foundDevice: Device?
    @Published var isSearching = false
    @Published var showDeviceDetail = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var isScannerActive = true
    /// Bumped chaque fois qu'on veut réinitialiser la caméra (ex. retour sur l'onglet, dismiss du sheet).
    @Published var scanSessionToken = UUID()

    // MARK: - Init

    init(graphService: GraphService) {
        self.graphService = graphService
    }

    // MARK: - Scan handling

    func handleScannedCode(_ code: String) {
        // Éviter les scans multiples en rafale pendant qu'une recherche est en cours.
        guard !isSearching else { return }
        scannedCode = code

        Task {
            await searchDevice(for: code)
        }
    }

    func handleScanError(_ error: QRScannerError) {
        errorMessage = error.localizedDescription
        showError = true
    }

    // MARK: - Device search (READ-ONLY)

    private func searchDevice(for code: String) async {
        isSearching = true
        defer { isSearching = false }

        // Parser le payload JSON si le QR code vient de ScanTune WPF
        let serial: String
        let deviceId: String
        let deviceName: String

        if let payload = QRPayload.parse(code) {
            serial = payload.serial
            deviceId = payload.id
            deviceName = payload.name
        } else {
            serial = code
            deviceId = code
            deviceName = code
        }

        do {
            // Tenter une recherche par numéro de série d'abord
            if let device = try await graphService.findDeviceBySerialNumber(serial) {
                foundDevice = device
                showDeviceDetail = true
                return
            }

            // Tenter une recherche par ID d'appareil
            if !deviceId.isEmpty, let device = try await graphService.getDeviceById(deviceId) {
                foundDevice = device
                showDeviceDetail = true
                return
            }

            // Tenter une recherche par nom d'appareil
            let results = try await graphService.searchDevices(query: deviceName)
            if let first = results.first {
                foundDevice = first
                showDeviceDetail = true
                return
            }

            // Aucun appareil trouvé
            errorMessage = "Aucun appareil trouvé pour le code : \(code)"
            showError = true
        } catch {
            errorMessage = "Erreur de recherche : \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Actions

    /// Réinitialise l'état du scanner et force la caméra à relancer la capture
    /// en bumpant le token (détecté par QRScannerView).
    func resetScanner() {
        scannedCode = nil
        foundDevice = nil
        showDeviceDetail = false
        showError = false
        errorMessage = ""
        isScannerActive = true
        scanSessionToken = UUID()
    }
}
