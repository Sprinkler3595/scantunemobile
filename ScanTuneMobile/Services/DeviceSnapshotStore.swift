import Foundation
import Combine

/// Snapshot persisté localement du parc (devices + users) chargé depuis Graph.
/// Permet à l'inventaire de continuer à fonctionner en mode hors-ligne (zones
/// blanches : entrepôts, sous-sols) — le scan résout depuis le snapshot, et
/// les records partent vers SharePoint via `InventoryQueueStore` dès que le
/// réseau revient.
///
/// Stocké en JSON dans `Documents/device_snapshot.json`. Pas chiffré au-delà
/// de la protection système des données (Data Protection / NSFileProtection
/// Complete via les défauts iOS). N'inclut aucun secret : que des métadonnées
/// d'appareil déjà visibles dans Intune.
struct DeviceSnapshot: Codable {
    let schemaVersion: Int
    let capturedAt: Date
    let devices: [Device]
    let users: [User]

    init(devices: [Device], users: [User]) {
        self.schemaVersion = 1
        self.capturedAt = Date()
        self.devices = devices
        self.users = users
    }
}

@MainActor
final class DeviceSnapshotStore: ObservableObject {

    @Published private(set) var snapshot: DeviceSnapshot?
    @Published private(set) var isSaving = false

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("device_snapshot.json")
    }()

    init() {
        load()
    }

    // MARK: - Public

    /// Vrai si un snapshot est présent (utilisable hors-ligne).
    var hasSnapshot: Bool { snapshot != nil }

    /// Âge du snapshot en secondes, ou nil si absent.
    var ageInSeconds: TimeInterval? {
        guard let s = snapshot else { return nil }
        return Date().timeIntervalSince(s.capturedAt)
    }

    /// Libellé court de l'âge (« il y a 14 min », « hier à 09:32 »…).
    var ageLabel: String? {
        guard let s = snapshot else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.localizedString(for: s.capturedAt, relativeTo: Date())
    }

    /// Sauvegarde un snapshot complet et le publie.
    func save(devices: [Device], users: [User]) {
        let new = DeviceSnapshot(devices: devices, users: users)
        isSaving = true
        defer { isSaving = false }
        do {
            let data = try Self.encoder.encode(new)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            self.snapshot = new
            AppLog.shared.info(
                "Snapshot saved: \(devices.count) device(s), \(users.count) user(s)",
                category: "snapshot"
            )
        } catch {
            AppLog.shared.error("Snapshot save failed: \(error.localizedDescription)", category: "snapshot")
        }
    }

    /// Supprime le snapshot local. Appelé typiquement au logout.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        snapshot = nil
        AppLog.shared.info("Snapshot cleared", category: "snapshot")
    }

    // MARK: - Private

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try Self.decoder.decode(DeviceSnapshot.self, from: data)
            self.snapshot = decoded
            AppLog.shared.info(
                "Snapshot loaded: \(decoded.devices.count) device(s), age=\(Int(Date().timeIntervalSince(decoded.capturedAt)))s",
                category: "snapshot"
            )
        } catch {
            AppLog.shared.warning("Snapshot load failed: \(error.localizedDescription)", category: "snapshot")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
