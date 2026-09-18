import AVFoundation
import SwiftUI
import UIKit

/// Reading the invitation out of a QR code. The code carries the same URI the
/// paste field accepts, and it goes through the same parser.
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
        .onAppear(perform: requestAccess)
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
