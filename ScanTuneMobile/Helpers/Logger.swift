import Foundation
import OSLog

/// Niveaux de log supportés par `AppLog`.
enum LogLevel: String, Codable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// Entrée structurée du buffer de log en mémoire.
/// Sérialisable en JSON pour l'export diagnostic.
struct LogEntry: Codable {
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
}

/// Logger applicatif : combine `os.Logger` (visible dans Console.app) et un
/// buffer circulaire en mémoire des 1000 dernières entrées, exportable
/// depuis l'écran Réglages pour diagnostiquer un incident terrain.
///
/// Thread-safe via une `NSLock` interne. Appelable depuis n'importe quel
/// actor / thread.
final class AppLog: @unchecked Sendable {

    static let shared = AppLog()

    private static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.scantune.mobile"
    private static let maxEntries = 1000

    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private var loggersByCategory: [String: Logger] = [:]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        buffer.reserveCapacity(Self.maxEntries)
    }

    // MARK: - Public

    func info(_ message: @autoclosure () -> String, category: String = "app") {
        log(level: .info, message: message(), category: category)
    }

    func warning(_ message: @autoclosure () -> String, category: String = "app") {
        log(level: .warning, message: message(), category: category)
    }

    func error(_ message: @autoclosure () -> String, category: String = "app") {
        log(level: .error, message: message(), category: category)
    }

    /// Snapshot immuable du buffer pour affichage / export.
    func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Vide le buffer en mémoire. Les entrées déjà écrites dans `os.Logger`
    /// (Console.app) restent disponibles côté système.
    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Écrit le buffer courant dans un fichier `.log` temporaire et retourne
    /// son URL — prête à passer à un `UIActivityViewController`.
    func exportToTemporaryFile() throws -> URL {
        let entries = snapshot()
        let lines = entries.map { Self.formatLine($0) }
        let header = """
        ScanTune Mobile — Diagnostic log
        Exported: \(Self.isoFormatter.string(from: Date()))
        Entries: \(entries.count)
        App version: \(Self.appVersionString())
        ------------------------------------------------------------

        """
        let body = header + lines.joined(separator: "\n") + "\n"

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
        let fileName = "scantune-diagnostic-\(Self.fileTimestamp()).log"
        let url = tmpDir.appendingPathComponent(fileName)
        try body.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Private

    private func log(level: LogLevel, message: String, category: String) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message
        )

        // 1. Append au buffer circulaire (sous lock).
        lock.lock()
        buffer.append(entry)
        if buffer.count > Self.maxEntries {
            buffer.removeFirst(buffer.count - Self.maxEntries)
        }
        lock.unlock()

        // 2. Forward vers os.Logger pour visibilité Console.app + persistance système.
        //    Les messages sont marqués `.private` : ils peuvent contenir des PII
        //    (numéros de série, UPN/emails, noms d'appareils et d'utilisateurs). Le
        //    système les rédige (`<private>`) dans Console.app / sysdiagnose. Le
        //    contenu complet reste disponible dans le buffer en mémoire ci-dessus,
        //    exportable depuis l'app (fichier protégé, derrière déverrouillage).
        let osLogger = osLogger(forCategory: category)
        switch level {
        case .info:
            osLogger.info("\(message, privacy: .private)")
        case .warning:
            osLogger.warning("\(message, privacy: .private)")
        case .error:
            osLogger.error("\(message, privacy: .private)")
        }
    }

    private func osLogger(forCategory category: String) -> Logger {
        lock.lock()
        defer { lock.unlock() }
        if let existing = loggersByCategory[category] {
            return existing
        }
        let new = Logger(subsystem: Self.subsystem, category: category)
        loggersByCategory[category] = new
        return new
    }

    private static func formatLine(_ entry: LogEntry) -> String {
        let ts = isoFormatter.string(from: entry.timestamp)
        return "\(ts) [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)"
    }

    private static func fileTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
