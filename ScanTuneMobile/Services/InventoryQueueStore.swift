import Foundation
import Network
import Combine

/// File d'attente locale des enregistrements d'inventaire en attente d'upload vers SharePoint.
///
/// - Persiste dans `Documents/inventory_queue.json`.
/// - Surveille la connectivité via `NWPathMonitor` et tente un flush dès que le réseau revient.
/// - Fournit `pending` pour que la VM puisse afficher les records encore non synchronisés.
@MainActor
final class InventoryQueueStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var pending: [QueuedRecord] = []
    @Published private(set) var isOnline: Bool = true
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastSyncAt: Date?

    // MARK: - Dependencies

    private let sharePoint: SharePointInventoryService
    private let settingsStore: InventorySettingsStore

    // MARK: - Persistence

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("inventory_queue.json")
    }()

    // MARK: - Network monitoring

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.scantune.mobile.inventory.netmonitor")

    // MARK: - Flush debounce

    /// Délai de regroupement : plusieurs scans rapprochés ne déclenchent qu'un seul
    /// upload (le fichier SharePoint est ré-écrit en entier à chaque PUT). Réduit le
    /// trafic et les conflits ETag pendant un inventaire actif.
    private static let flushDebounceNanos: UInt64 = 2_000_000_000 // 2 s
    private var debounceTask: Task<Void, Never>?

    // MARK: - Init

    init(sharePoint: SharePointInventoryService, settingsStore: InventorySettingsStore) {
        self.sharePoint = sharePoint
        self.settingsStore = settingsStore
        load()
        startMonitoring()
    }

    deinit {
        pathMonitor.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Public API

    /// Ajoute un record à la file et planifie un flush regroupé (débounce).
    /// Un burst de scans rapprochés ne déclenche ainsi qu'un seul upload.
    func enqueue(_ record: InventoryRecord) {
        pending.append(QueuedRecord(record: record))
        persist()
        AppLog.shared.info(
            "Enqueued record \(record.clientRecordId) for device \(record.deviceName) (status=\(record.status.rawValue))",
            category: "queue"
        )
        scheduleFlush()
    }

    /// Planifie un flush différé en regroupant les scans rapprochés (débounce).
    /// Chaque nouvel appel repousse l'échéance — un burst de scans = un seul upload.
    /// Le retour réseau, le passage en premier plan et le pull-to-refresh appellent
    /// `flush()` directement (immédiat), sans passer par ce débounce.
    private func scheduleFlush() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushDebounceNanos)
            if Task.isCancelled { return }
            await self?.flush()
        }
    }

    /// Vide la file et supprime le fichier de persistance (déconnexion / reset).
    func clear() {
        debounceTask?.cancel()
        pending = []
        lastSyncError = nil
        lastSyncAt = nil
        isSyncing = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Déclenche un flush manuel (pull-to-refresh ou retour app foreground).
    func flush() async {
        guard !isSyncing else { return }
        guard !pending.isEmpty else { return }
        guard settingsStore.settings.isConfigured else {
            lastSyncError = "Réglages SharePoint incomplets."
            return
        }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        // Snapshot immuable des records à uploader (les nouveaux arrivant en cours de route
        // seront traités au prochain flush).
        let toUpload = pending.map(\.record)

        AppLog.shared.info("Flush start: \(toUpload.count) record(s) to upload", category: "queue")

        do {
            _ = try await sharePoint.upload(newRecords: toUpload, settings: settingsStore.settings)
            // Retirer de la queue uniquement ceux qu'on a tenté d'uploader dans ce snapshot.
            let uploadedIds = Set(toUpload.map(\.clientRecordId))
            pending.removeAll { uploadedIds.contains($0.record.clientRecordId) }
            persist()
            lastSyncAt = Date()
            AppLog.shared.info("Flush success: \(toUpload.count) record(s) uploaded", category: "queue")
            // Des scans sont arrivés pendant l'upload (ignorés par le garde `isSyncing`) :
            // planifier un nouveau cycle pour ne pas les laisser en attente.
            if !pending.isEmpty { scheduleFlush() }
        } catch {
            let message = error.localizedDescription
            lastSyncError = message
            // Marquer les records tentés avec l'erreur, pour affichage dans l'UI.
            let now = Date()
            let triedIds = Set(toUpload.map(\.clientRecordId))
            for idx in pending.indices where triedIds.contains(pending[idx].record.clientRecordId) {
                pending[idx].lastError = message
                pending[idx].lastTriedAt = now
            }
            persist()
            AppLog.shared.error("Flush failed: \(message)", category: "queue")
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try InventoryFile.jsonDecoder.decode([QueuedRecord].self, from: data)
            self.pending = decoded
        } catch {
            self.pending = []
        }
    }

    private func persist() {
        do {
            let data = try InventoryFile.jsonEncoder.encode(pending)
            // Protection des données au repos : la file contient des PII (n° série,
            // UPN/emails, noms). `untilFirstUserAuthentication` chiffre le fichier sur
            // un appareil éteint/au démarrage avant 1er déverrouillage, tout en restant
            // accessible ensuite — y compris pour le flush automatique en arrière-plan
            // (retour réseau alors que l'écran est verrouillé), que `completeFileProtection`
            // bloquerait.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Silencieux : la file en mémoire reste la source de vérité pour cette session.
        }
    }

    // MARK: - Network monitoring

    private func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                if online && wasOffline {
                    AppLog.shared.info("Network back online — triggering auto flush", category: "queue")
                    await self.flush()
                } else if !online && !wasOffline {
                    AppLog.shared.warning("Network went offline", category: "queue")
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
}
