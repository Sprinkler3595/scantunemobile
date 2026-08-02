import Foundation

/// Représente le payload JSON encodé dans les QR codes générés par ScanTune WPF.
/// Format attendu : {"id":"...","name":"...","serial":"...","source":"intune","generated":"yyyy-MM-dd"}
struct QRPayload {
    let id: String
    let name: String
    let serial: String
    let source: String
    let generated: String

    /// Tente de parser une chaîne scannée comme payload QR JSON ScanTune.
    /// Retourne nil si la chaîne n'est pas un JSON valide ou ne contient pas les champs attendus.
    static func parse(_ code: String) -> QRPayload? {
        guard let data = code.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serial = json["serial"] as? String, !serial.isEmpty else {
            return nil
        }

        return QRPayload(
            id: json["id"] as? String ?? "",
            name: json["name"] as? String ?? "",
            serial: serial,
            source: json["source"] as? String ?? "",
            generated: json["generated"] as? String ?? ""
        )
    }
}
