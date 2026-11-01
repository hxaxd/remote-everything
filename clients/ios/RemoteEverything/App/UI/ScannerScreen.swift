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
/// refusal, and run only while its view is on screen. The divergence ends at
/// the shell: what the scanner yields is the same invitation string, parsed by
/// the same strict SetupURI, and nothing else in the app knows a scanner exists.
///
/// The shell itself is the one the other clients show: the whole window is the
/// camera, with the way out on one side, the name in the middle, and the light
/// on the other. No navigation chrome, no frame, and no sentence — the picture
/// is the instruction.
struct ScannerScreen: View {

    let onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @StateObject private var scanner = ScannerController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if authorization == .authorized || authorization == .notDetermined {
                QRCodeScanner(onCode: onCode, controller: scanner)
                    .ignoresSafeArea()
                controls
            } else {
                denied
            }
        }
        .statusBarHidden(true)
        .onAppear {
            // The code is read in the hand it is held in: the scanner stands up,
            // whatever the phone was doing a moment ago, and goes back to the
            // system's own choice when it closes.
            OrientationLock.shared.apply(.portrait)
            requestAccess()
        }
        .onDisappear {
            scanner.turnOff()
            OrientationLock.shared.release()
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: Theme.gapM) {
                circleButton("xmark") { dismiss() }
                    .accessibilityLabel(l10n(MessageKeys.ACTION_BACK))
                Spacer(minLength: 0)
                Text(l10n(MessageKeys.PAIR_SCAN))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if scanner.torchAvailable {
                    circleButton(scanner.torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                        scanner.toggleTorch()
                    }
                    .accessibilityIdentifier("scan.torch")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
    }

    private var denied: some View {
        VStack(spacing: Theme.gapM) {
            Text(l10n(MessageKeys.PAIR_SCAN_DENIED))
                .font(Theme.headline)
                .foregroundStyle(.white)
            Text(l10n(MessageKeys.PAIR_SCAN_BODY))
                .font(Theme.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button(l10n(MessageKeys.ACTION_BACK)) { dismiss() }
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.top, Theme.gapS)
        }
        .padding(Theme.gapXL)
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

/// The light, as the view holds it: the screen asks, the view answers.
final class ScannerController: ObservableObject {

    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false

    weak var view: QRScannerView?

    func attach(_ view: QRScannerView) {
        self.view = view
        torchAvailable = view.hasTorch
    }

    func toggleTorch() {
        guard let view, view.hasTorch else { return }
        torchOn.toggle()
        view.setTorch(torchOn)
    }

    func turnOff() {
        guard torchOn else { return }
        torchOn = false
        view?.setTorch(false)
    }
}

/// The camera view. It is a plain UIView so the session's lifetime matches the
/// view's own: the session starts when the view is on screen and stops when it
/// is not.
struct QRCodeScanner: UIViewRepresentable {

    let onCode: (String) -> Void
    let controller: ScannerController

    func makeUIView(context: Context) -> QRScannerView {
        let view = QRScannerView()
        view.onCode = onCode
        controller.attach(view)
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
    private var device: AVCaptureDevice?
    private var handled = false

    var hasTorch: Bool { device?.hasTorch ?? false }

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
        self.device = device

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

    func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
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
            setTorch(false)
            DispatchQueue.main.async { [weak self] in
                self?.onCode?(value)
            }
            return
        }
    }
}
