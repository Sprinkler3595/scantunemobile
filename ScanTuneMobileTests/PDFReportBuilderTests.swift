import XCTest
import PDFKit
@testable import ScanTuneMobile

final class PDFReportBuilderTests: XCTestCase {

    func test_build_minimalInput_producesNonEmptyPDF() throws {
        let input = PDFReportBuilder.Input(
            year: 2026,
            generatedAt: Date(),
            technicianName: "Test Tech",
            scopes: [.windows],
            totalDevices: 0,
            checkedDevices: 0,
            recordsByStatus: [:],
            companies: [],
            anomalies: [],
            deviceNames: [:]
        )
        let url = try PDFReportBuilder.build(input)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? UInt64 ?? 0
        XCTAssertGreaterThan(size, 500, "Le PDF doit faire au moins quelques centaines d'octets")

        // Vérifie que le PDF est ouvrable.
        let doc = PDFDocument(url: url)
        XCTAssertNotNil(doc)
        XCTAssertGreaterThanOrEqual(doc!.pageCount, 3, "Page de garde + résumé + entreprises minimum")
    }

    func test_build_withAnomalies_addsAnnexePage() throws {
        let anomalies = (0..<5).map { i in
            DeviceAnomaly(
                deviceId: "dev\(i)",
                kind: .staleSync,
                detail: "Stale \(i)"
            )
        }
        let input = PDFReportBuilder.Input(
            year: 2026,
            generatedAt: Date(),
            technicianName: "Tech",
            scopes: [.windows, .macOS],
            totalDevices: 5,
            checkedDevices: 3,
            recordsByStatus: [.trouve: 3],
            companies: [
                CompanyProgress(companyName: "Corp A", totalDevices: 5, checkedDevices: 3)
            ],
            anomalies: anomalies,
            deviceNames: Dictionary(uniqueKeysWithValues: (0..<5).map { ("dev\($0)", "PC-\($0)") })
        )
        let url = try PDFReportBuilder.build(input)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = PDFDocument(url: url)!
        XCTAssertGreaterThanOrEqual(doc.pageCount, 4, "Page anomalies attendue en plus")
    }
}
