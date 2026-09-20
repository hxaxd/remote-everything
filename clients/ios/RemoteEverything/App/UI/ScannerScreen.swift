import AVFoundation
import SwiftUI
import UIKit

/// Reading the invitation out of a QR code. The code carries the same URI the
/// paste field accepts, and it goes through the same parser.
///
/// Why this platform difference is not a choice (clients/README.md — the
/// scanner is one of the three sanctioned platform divergences): iOS ships no
/// system scanning API the other two can lean on. Android and Harmony can
/// inline a preview or a system scan into PairScreen; here the camera is a
/// hand-built AVCaptureSession that must ask for camera permission, answer its
/// refusal, and run only while its view is on screen — machinery that cannot
/// live inside the pairing sheet, so it is a screen of its own. The divergence
/// ends at the shell: what the scanner yields is the same invitation string,
/// parsed by the same strict SetupURI, and nothing else in the app knows a
/// scanner exists.
struct ScannerScreen: View {

    let onCode: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        let theme = Theme(colorScheme)
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch authorization {
                case .authorized, .notDetermined:
                    QRCodeScanner(onCode: onCode)
                        .ignoresSafeArea(edges: .bottom)
                default:
                    MessagePage(
                        title: l10n(MessageKeys.PAIR_SCAN_DENIED),
                        body: l10n(MessageKeys.PAIR_SCAN_BODY),
                        actionTitle: nil,
                        action: nil
                    )
                    .background(theme.bg)
                }
            }
            .navigationTitle(l10n(MessageKeys.PAIR_SCAN))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(l10n(MessageKeys.ACTION_CANCEL)) { dismiss() }
                }
            }
        }
        .onAppear {
            // The code is read in the hand it is held in: the scanner stands up,
            // whatever the phone was doing a moment ago, and goes back to the
            // system's own choice when it closes.
            OrientationLock.shared.apply(.portrait)
            requestAccess()
        }
        .onDisappear { OrientationLock.shared.release() }
    }

    private func requestAccess() {
        guard authorization == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                authorization = granted ? .authorized : .denied
            }
        }
    }
}

/// The camera view. It is a plain UIView so the session's lifetime matches the
/// view's own: the session starts when the view is on screen and stops when it
/// is not.
struct QRCodeScanner: UIViewRepresentable {

    let onCode: (String) -> Void

    func makeUIView(context: Context) -> QRScannerView {
        let view = QRScannerView()
        view.onCode = onCode
        return view
    }

    func updateUIView(_ uiView: QRScannerView, context: Context) {
        uiView.onCode = onCode
    }
}

final class QRScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {

    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let overlay = ScannerOverlayView()
    private var handled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        configure()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        overlay.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        layer.addSublayer(preview)
        previewLayer = preview

        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.frame = bounds
        addSubview(overlay)
    }

    func start() {
        guard !session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func stop() {
        guard session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !handled else { return }
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  let value = readable.stringValue
            else { continue }
            handled = true
            stop()
            DispatchQueue.main.async { [weak self] in
                self?.onCode?(value)
            }
            return
        }
    }
}

/// What sits over the camera: everything but the frame is dimmed, and the frame's
/// corners are drawn. The preview stays visible exactly where a code has to be,
/// which is the whole instruction — the same one the other two clients give.
private final class ScannerOverlayView: UIView {

    private let hint = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        hint.text = l10n(MessageKeys.PAIR_SCAN_BODY)
        hint.textColor = UIColor(white: 0.95, alpha: 1)
        hint.font = .systemFont(ofSize: 14)
        hint.textAlignment = .center
        hint.numberOfLines = 2
        addSubview(hint)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(min(bounds.width, bounds.height) * 0.68, 320)
        let hintWidth = min(bounds.width - 48, 360)
        hint.frame = CGRect(
            x: bounds.midX - hintWidth / 2,
            y: bounds.midY + side / 2 + 24,
            width: hintWidth,
            height: 44
        )
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let side = min(min(bounds.width, bounds.height) * 0.68, 320)
        let frame = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        let radius: CGFloat = 28

        // Everything outside the frame, dimmed: drawn as a path with the frame
        // punched out, so the camera stays bright where the code goes.
        let scrim = UIBezierPath(rect: bounds)
        scrim.append(UIBezierPath(roundedRect: frame, cornerRadius: radius).reversing())
        context.setFillColor(UIColor(white: 0, alpha: 0.6).cgColor)
        context.addPath(scrim.cgPath)
        context.fillPath()

        // The corners, starting past the rounded corner so they read as the
        // frame's own corners rather than as a box drawn over one.
        context.setStrokeColor(UIColor(red: 0.561, green: 0.706, blue: 0.863, alpha: 1).cgColor)
        context.setLineWidth(4)
        context.setLineCap(.round)
        let arm: CGFloat = 34
        let segments: [(CGPoint, CGPoint)] = [
            (CGPoint(x: frame.minX + radius, y: frame.minY), CGPoint(x: frame.minX + radius + arm, y: frame.minY)),
            (CGPoint(x: frame.minX, y: frame.minY + radius), CGPoint(x: frame.minX, y: frame.minY + radius + arm)),
            (CGPoint(x: frame.maxX - radius, y: frame.minY), CGPoint(x: frame.maxX - radius - arm, y: frame.minY)),
            (CGPoint(x: frame.maxX, y: frame.minY + radius), CGPoint(x: frame.maxX, y: frame.minY + radius + arm)),
            (CGPoint(x: frame.minX + radius, y: frame.maxY), CGPoint(x: frame.minX + radius + arm, y: frame.maxY)),
            (CGPoint(x: frame.minX, y: frame.maxY - radius), CGPoint(x: frame.minX, y: frame.maxY - radius - arm)),
            (CGPoint(x: frame.maxX - radius, y: frame.maxY), CGPoint(x: frame.maxX - radius - arm, y: frame.maxY)),
            (CGPoint(x: frame.maxX, y: frame.maxY - radius), CGPoint(x: frame.maxX, y: frame.maxY - radius - arm)),
        ]
        for (start, end) in segments {
            context.move(to: start)
            context.addLine(to: end)
        }
        context.strokePath()
    }
}
