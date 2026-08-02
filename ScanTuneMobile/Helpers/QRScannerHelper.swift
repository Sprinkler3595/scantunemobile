import AVFoundation
import SwiftUI

/// Représentable UIKit pour capturer les QR codes via la caméra arrière.
/// Lecture seule — ne fait que lire le contenu des QR codes.
struct QRScannerView: UIViewControllerRepresentable {

    let onCodeScanned: (String) -> Void
    let onError: (QRScannerError) -> Void
    /// Bump ce token depuis le ViewModel (UUID différent) pour forcer le scanner à reprendre la capture.
    var resetToken: Binding<UUID>? = nil

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        context.coordinator.lastResetToken = resetToken?.wrappedValue
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        if let token = resetToken?.wrappedValue, token != context.coordinator.lastResetToken {
            context.coordinator.lastResetToken = token
            uiViewController.resetScanner()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, onError: onError)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, QRScannerViewControllerDelegate {
        let onCodeScanned: (String) -> Void
        let onError: (QRScannerError) -> Void
        var lastResetToken: UUID?

        init(onCodeScanned: @escaping (String) -> Void, onError: @escaping (QRScannerError) -> Void) {
            self.onCodeScanned = onCodeScanned
            self.onError = onError
        }

        func didScanCode(_ code: String) {
            onCodeScanned(code)
        }

        func didFailWithError(_ error: QRScannerError) {
            onError(error)
        }
    }
}

// MARK: - Delegate Protocol

protocol QRScannerViewControllerDelegate: AnyObject {
    func didScanCode(_ code: String)
    func didFailWithError(_ error: QRScannerError)
}

// MARK: - Errors

enum QRScannerError: LocalizedError {
    case cameraUnavailable
    case cameraPermissionDenied
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "La caméra n'est pas disponible sur cet appareil."
        case .cameraPermissionDenied:
            return "L'accès à la caméra a été refusé. Veuillez l'activer dans Réglages."
        case .setupFailed(let reason):
            return "Erreur de configuration de la caméra : \(reason)"
        }
    }
}

// MARK: - Scanner ViewController

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    weak var delegate: QRScannerViewControllerDelegate?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkCameraPermission()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasScanned = false
        startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    // MARK: - Camera Permission

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.delegate?.didFailWithError(.cameraPermissionDenied)
                    }
                }
            }
        case .denied, .restricted:
            delegate?.didFailWithError(.cameraPermissionDenied)
        @unknown default:
            delegate?.didFailWithError(.cameraPermissionDenied)
        }
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let videoCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            delegate?.didFailWithError(.cameraUnavailable)
            return
        }

        guard let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else {
            delegate?.didFailWithError(.setupFailed("Impossible de créer l'entrée vidéo"))
            return
        }

        guard session.canAddInput(videoInput) else {
            delegate?.didFailWithError(.setupFailed("Impossible d'ajouter l'entrée vidéo"))
            return
        }
        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()

        guard session.canAddOutput(metadataOutput) else {
            delegate?.didFailWithError(.setupFailed("Impossible d'ajouter la sortie métadonnées"))
            return
        }
        session.addOutput(metadataOutput)

        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr, .code128, .code39, .ean13, .ean8, .dataMatrix]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        addScanOverlay()

        captureSession = session
        previewLayer = preview

        startScanning()
    }

    // MARK: - Overlay visuel

    private func addScanOverlay() {
        let overlayView = UIView(frame: view.bounds)
        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        view.addSubview(overlayView)

        // Zone de scan centrale
        let scanSize: CGFloat = 250
        let scanRect = CGRect(
            x: (view.bounds.width - scanSize) / 2,
            y: (view.bounds.height - scanSize) / 2,
            width: scanSize,
            height: scanSize
        )

        // Masque semi-transparent autour
        let maskPath = UIBezierPath(rect: view.bounds)
        maskPath.append(UIBezierPath(roundedRect: scanRect, cornerRadius: 12).reversing())

        let maskLayer = CAShapeLayer()
        maskLayer.path = maskPath.cgPath
        maskLayer.fillColor = UIColor.black.withAlphaComponent(0.5).cgColor
        overlayView.layer.addSublayer(maskLayer)

        // Bordure de la zone de scan
        let borderLayer = CAShapeLayer()
        borderLayer.path = UIBezierPath(roundedRect: scanRect, cornerRadius: 12).cgPath
        borderLayer.strokeColor = UIColor.systemBlue.cgColor
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.lineWidth = 3
        overlayView.layer.addSublayer(borderLayer)

        // Coins décoratifs
        let cornerLength: CGFloat = 30
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            // Haut-gauche
            (CGPoint(x: scanRect.minX, y: scanRect.minY + cornerLength),
             CGPoint(x: scanRect.minX, y: scanRect.minY),
             CGPoint(x: scanRect.minX + cornerLength, y: scanRect.minY)),
            // Haut-droit
            (CGPoint(x: scanRect.maxX - cornerLength, y: scanRect.minY),
             CGPoint(x: scanRect.maxX, y: scanRect.minY),
             CGPoint(x: scanRect.maxX, y: scanRect.minY + cornerLength)),
            // Bas-gauche
            (CGPoint(x: scanRect.minX, y: scanRect.maxY - cornerLength),
             CGPoint(x: scanRect.minX, y: scanRect.maxY),
             CGPoint(x: scanRect.minX + cornerLength, y: scanRect.maxY)),
            // Bas-droit
            (CGPoint(x: scanRect.maxX - cornerLength, y: scanRect.maxY),
             CGPoint(x: scanRect.maxX, y: scanRect.maxY),
             CGPoint(x: scanRect.maxX, y: scanRect.maxY - cornerLength))
        ]

        for (start, mid, end) in corners {
            let path = UIBezierPath()
            path.move(to: start)
            path.addLine(to: mid)
            path.addLine(to: end)

            let cornerLayer = CAShapeLayer()
            cornerLayer.path = path.cgPath
            cornerLayer.strokeColor = UIColor.white.cgColor
            cornerLayer.fillColor = UIColor.clear.cgColor
            cornerLayer.lineWidth = 4
            cornerLayer.lineCap = .round
            overlayView.layer.addSublayer(cornerLayer)
        }

        // Label instruction
        let label = UILabel()
        label.text = "Alignez le QR code dans le cadre"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.frame = CGRect(
            x: 20,
            y: scanRect.maxY + 20,
            width: view.bounds.width - 40,
            height: 30
        )
        overlayView.addSubview(label)
    }

    // MARK: - Scanning control

    func startScanning() {
        guard let session = captureSession, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func stopScanning() {
        guard let session = captureSession, session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    func resetScanner() {
        hasScanned = false
        startScanning()
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let metadataObject = metadataObjects.first,
              let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue else {
            return
        }

        hasScanned = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        stopScanning()

        delegate?.didScanCode(stringValue)
    }
}
