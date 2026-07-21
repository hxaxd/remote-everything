import SwiftUI
import AVFoundation

/// QR code scanner view that only accepts `remote-everything://setup` URIs.
/// When camera permission is denied, falls back to clipboard paste.
struct ScannerView: View {
    @State private var permissionDenied = false
    @State private var pastedURI = ""
    @State private var scannedCode: String?
    @State private var errorMessage: String?

    var onScan: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let code = scannedCode {
                // Success state
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("已识别")
                    .font(.headline)
                Text(code)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            onScan(code)
                        }
                    }
            } else if let error = errorMessage {
                // Error state
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text(error)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("重试") {
                    errorMessage = nil
                }
                .buttonStyle(.bordered)
            } else if permissionDenied {
                // Paste fallback when camera denied
                ContentUnavailableView(
                    "相机权限未授权",
                    systemImage: "camera.fill",
                    description: Text("请在设置中允许相机权限，或粘贴 setup 链接")
                )
                HStack(spacing: 12) {
                    Button {
                        if let text = UIPasteboard.general.string,
                           text.contains("remote-everything://setup") {
                            scannedCode = text
                        } else {
                            errorMessage = "剪贴板中没有有效的 setup 链接"
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("打开设置", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                // Camera view
                CameraPreview(
                    onCodeFound: { code in
                        scannedCode = code
                    },
                    onPermissionDenied: {
                        permissionDenied = true
                    }
                )
                .overlay(alignment: .top) {
                    Text("将二维码放入框内")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.top, 48)
                }
            }
        }
        .navigationTitle("扫描二维码")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

private struct CameraPreview: UIViewRepresentable {
    let onCodeFound: (String) -> Void
    let onPermissionDenied: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            setupCaptureSession(on: view, context: context)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        setupCaptureSession(on: view, context: context)
                    } else {
                        onPermissionDenied()
                    }
                }
            }
        default:
            DispatchQueue.main.async { onPermissionDenied() }
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeFound: onCodeFound)
    }

    private func setupCaptureSession(on view: UIView, context: Context) {
        let session = AVCaptureSession()
        context.coordinator.session = session

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCodeFound: (String) -> Void
        var session: AVCaptureSession?
        private var found = false

        init(onCodeFound: @escaping (String) -> Void) {
            self.onCodeFound = onCodeFound
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !found,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let code = object.stringValue,
                  code.hasPrefix("remote-everything://setup") else {
                return
            }
            found = true
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            session?.stopRunning()
            onCodeFound(code)
        }
    }
}
