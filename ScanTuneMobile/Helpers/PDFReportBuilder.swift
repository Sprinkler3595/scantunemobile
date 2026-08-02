import Foundation
import UIKit
import PDFKit

/// Construit un rapport PDF synthétique d'une session d'inventaire.
/// Pas de dépendance externe — usage direct de UIGraphicsPDFRenderer.
///
/// Le PDF généré contient :
/// - Page de garde (titre, période, périmètre, technicien, horodatage).
/// - Résumé exécutif (KPIs : couverture, statuts, anomalies).
/// - Répartition par entreprise (tableau, complétion).
/// - Annexe : top 20 anomalies si présentes.
struct PDFReportBuilder {

    // MARK: - Input

    /// Données nécessaires à la génération du rapport. Récupérées depuis le VM.
    struct Input {
        let year: Int
        let generatedAt: Date
        let technicianName: String
        let scopes: [DeviceScope]
        let totalDevices: Int
        let checkedDevices: Int
        let recordsByStatus: [InventoryStatus: Int]
        let companies: [CompanyProgress]
        let anomalies: [DeviceAnomaly]
        /// Lookup deviceId → deviceName pour les anomalies.
        let deviceNames: [String: String]
    }

    // MARK: - Page geometry (A4 portrait, points : 595 × 842)

    private static let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 48

    // MARK: - Public

    /// Génère le PDF et retourne son URL dans le dossier temporaire.
    static func build(_ input: Input) throws -> URL {
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let fm = FileManager.default
        let fileName = "scantune-rapport-\(input.year)-\(fileTimestamp(input.generatedAt)).pdf"
        let url = fm.temporaryDirectory.appendingPathComponent(fileName)

        try renderer.writePDF(to: url) { ctx in
            drawCoverPage(input, ctx: ctx)
            drawSummaryPage(input, ctx: ctx)
            drawCompaniesPage(input, ctx: ctx)
            if !input.anomalies.isEmpty {
                drawAnomaliesPage(input, ctx: ctx)
            }
        }
        AppLog.shared.info("PDF report generated: \(fileName)", category: "report")
        return url
    }

    // MARK: - Pages

    private static func drawCoverPage(_ input: Input, ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y: CGFloat = 120

        drawText("ScanTune Mobile",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 14, weight: .medium),
                 color: .systemBlue)
        y += 18

        drawText("Rapport d'inventaire \(input.year)",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 30, weight: .bold))
        y += 60

        let coverage = input.totalDevices == 0 ? 0 :
            Int((Double(input.checkedDevices) / Double(input.totalDevices) * 100).rounded())

        drawCoverKPI(label: "Couverture", value: "\(coverage)%", y: y)
        y += 50
        drawCoverKPI(label: "Appareils vérifiés", value: "\(input.checkedDevices) / \(input.totalDevices)", y: y)
        y += 50
        drawCoverKPI(label: "Anomalies détectées", value: "\(input.anomalies.count)", y: y)
        y += 80

        let scopeLabel = input.scopes.map(\.displayName).joined(separator: ", ")
        drawText("Périmètre : \(scopeLabel)",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 12),
                 color: .darkGray)
        y += 18
        drawText("Technicien : \(input.technicianName)",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 12),
                 color: .darkGray)
        y += 18
        drawText("Généré le \(dateLabel(input.generatedAt))",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 12),
                 color: .darkGray)

        // Filet en pied de page
        drawFooter(page: 1)
    }

    private static func drawCoverKPI(label: String, value: String, y: CGFloat) {
        drawText(label,
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 13),
                 color: .gray)
        drawText(value,
                 at: CGPoint(x: margin, y: y + 16),
                 font: .systemFont(ofSize: 22, weight: .semibold))
    }

    private static func drawSummaryPage(_ input: Input, ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y: CGFloat = margin

        drawText("Résumé exécutif",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 22, weight: .bold))
        y += 32

        // Statuts
        drawText("Répartition par statut",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 14, weight: .semibold))
        y += 22

        for status in InventoryStatus.allCases {
            let count = input.recordsByStatus[status] ?? 0
            drawText("• \(status.rawValue)",
                     at: CGPoint(x: margin + 8, y: y),
                     font: .systemFont(ofSize: 12))
            drawText("\(count)",
                     at: CGPoint(x: pageRect.width - margin - 50, y: y),
                     font: .systemFont(ofSize: 12, weight: .medium))
            y += 18
        }
        y += 12

        // Anomalies
        drawText("Anomalies détectées",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 14, weight: .semibold))
        y += 22

        let byKind = Dictionary(grouping: input.anomalies, by: \.kind)
        if byKind.isEmpty {
            drawText("Aucune anomalie sur le périmètre actif.",
                     at: CGPoint(x: margin + 8, y: y),
                     font: .systemFont(ofSize: 12),
                     color: .systemGreen)
            y += 18
        } else {
            for kind in AnomalyKind.allCases {
                let count = byKind[kind]?.count ?? 0
                drawText("• \(kind.title)",
                         at: CGPoint(x: margin + 8, y: y),
                         font: .systemFont(ofSize: 12))
                drawText("\(count)",
                         at: CGPoint(x: pageRect.width - margin - 50, y: y),
                         font: .systemFont(ofSize: 12, weight: .medium))
                y += 18
            }
        }

        drawFooter(page: 2)
    }

    private static func drawCompaniesPage(_ input: Input, ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y: CGFloat = margin

        drawText("Progression par entreprise",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 22, weight: .bold))
        y += 32

        // En-tête de tableau
        drawText("Entreprise",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 11, weight: .semibold),
                 color: .gray)
        drawText("Vérifiés",
                 at: CGPoint(x: pageRect.width - margin - 160, y: y),
                 font: .systemFont(ofSize: 11, weight: .semibold),
                 color: .gray)
        drawText("Total",
                 at: CGPoint(x: pageRect.width - margin - 100, y: y),
                 font: .systemFont(ofSize: 11, weight: .semibold),
                 color: .gray)
        drawText("%",
                 at: CGPoint(x: pageRect.width - margin - 40, y: y),
                 font: .systemFont(ofSize: 11, weight: .semibold),
                 color: .gray)
        y += 18

        // Filet
        drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: pageRect.width - margin, y: y))
        y += 8

        for company in input.companies {
            if y > pageRect.height - margin - 40 {
                drawFooter(page: 3)
                ctx.beginPage()
                y = margin
            }
            let pct = Int((company.progressRatio * 100).rounded())
            drawText(truncate(company.companyName, max: 50),
                     at: CGPoint(x: margin, y: y),
                     font: .systemFont(ofSize: 11))
            drawText("\(company.checkedDevices)",
                     at: CGPoint(x: pageRect.width - margin - 160, y: y),
                     font: .systemFont(ofSize: 11))
            drawText("\(company.totalDevices)",
                     at: CGPoint(x: pageRect.width - margin - 100, y: y),
                     font: .systemFont(ofSize: 11))
            drawText("\(pct)%",
                     at: CGPoint(x: pageRect.width - margin - 40, y: y),
                     font: .systemFont(ofSize: 11, weight: .medium),
                     color: company.isComplete ? .systemGreen : .darkGray)
            y += 16
        }

        drawFooter(page: 3)
    }

    private static func drawAnomaliesPage(_ input: Input, ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y: CGFloat = margin

        drawText("Annexe — Anomalies",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 22, weight: .bold))
        y += 32

        let top = Array(input.anomalies
            .sorted { $0.severity > $1.severity }
            .prefix(20))

        drawText("Top \(top.count) anomalies (sur \(input.anomalies.count) au total) :",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 11),
                 color: .darkGray)
        y += 22

        for anomaly in top {
            if y > pageRect.height - margin - 60 {
                drawFooter(page: 4)
                ctx.beginPage()
                y = margin
            }
            let name = input.deviceNames[anomaly.deviceId] ?? anomaly.deviceId
            drawText("• \(name)",
                     at: CGPoint(x: margin, y: y),
                     font: .systemFont(ofSize: 12, weight: .semibold))
            y += 14
            drawText("  \(anomaly.kind.title) — \(anomaly.detail)",
                     at: CGPoint(x: margin, y: y),
                     font: .systemFont(ofSize: 10),
                     color: .darkGray)
            y += 18
        }

        drawFooter(page: 4)
    }

    // MARK: - Drawing primitives

    private static func drawText(_ text: String,
                                 at point: CGPoint,
                                 font: UIFont,
                                 color: UIColor = .black) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    private static func drawLine(from p1: CGPoint, to p2: CGPoint) {
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setStrokeColor(UIColor.lightGray.cgColor)
        ctx?.setLineWidth(0.5)
        ctx?.move(to: p1)
        ctx?.addLine(to: p2)
        ctx?.strokePath()
    }

    private static func drawFooter(page: Int) {
        let y = pageRect.height - margin + 12
        drawLine(from: CGPoint(x: margin, y: y - 4),
                 to: CGPoint(x: pageRect.width - margin, y: y - 4))
        drawText("ScanTune Mobile",
                 at: CGPoint(x: margin, y: y),
                 font: .systemFont(ofSize: 9),
                 color: .gray)
        let pageStr = "Page \(page)"
        let size = (pageStr as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 9)])
        drawText(pageStr,
                 at: CGPoint(x: pageRect.width - margin - size.width, y: y),
                 font: .systemFont(ofSize: 9),
                 color: .gray)
    }

    // MARK: - Formatting

    private static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        f.locale = Locale(identifier: "fr_FR")
        return f.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
