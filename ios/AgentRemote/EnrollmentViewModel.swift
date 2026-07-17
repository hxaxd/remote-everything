import SwiftUI
import UIKit

@MainActor
final class EnrollmentViewModel: ObservableObject {
    @Published var status = "正在生成设备身份并申请注册…"
    @Published var registrationCode = ""
    @Published var error: String?
    var approved: (() -> Void)?

    func start() {
        Task {
            do {
                let identity = DeviceIdentity.shared
                let model = UIDevice.current.model
                let name = "\(UIDevice.current.name) · \(model) · iOS".prefix(80).description
                let proof = try identity.createProof(deviceName: name)
                let bootstrap = try SecureHTTP.bootstrap()
                let request = try await bootstrap.json(
                    url: AppConfig.enrollRequestURL,
                    method: "POST",
                    headers: ["X-Kimi-Bootstrap-Fingerprint": AppConfig.bootstrapFingerprint],
                    body: [
                        "device_name": name,
                        "public_key_pem": try identity.publicKeyPEM(),
                        "proof_nonce": proof.nonce,
                        "proof_signature": proof.signature
                    ]
                )
                guard let requestID = request["request_id"] as? String,
                      let code = request["registration_code"] as? String else {
                    throw NetworkError.invalidResponse
                }
                registrationCode = code
                status = "等待服务端批准"
                while !Task.isCancelled {
                    var parts = URLComponents(url: AppConfig.enrollStatusURL, resolvingAgainstBaseURL: false)!
                    parts.queryItems = [URLQueryItem(name: "id", value: requestID)]
                    let result = try await bootstrap.json(
                        url: parts.url!,
                        method: "GET",
                        headers: ["X-Kimi-Bootstrap-Fingerprint": AppConfig.bootstrapFingerprint]
                    )
                    if result["status"] as? String == "approved",
                       let pem = result["certificate_pem"] as? String {
                        try identity.installCertificate(pem: pem)
                        approved?()
                        return
                    }
                    let state = result["status"] as? String ?? ""
                    if ["rejected", "revoked"].contains(state) {
                        throw NetworkError.response(403, "此设备的注册申请已被拒绝")
                    }
                    try await Task.sleep(for: .seconds(3))
                }
            } catch {
                self.error = error.localizedDescription
                status = "连接失败"
            }
        }
    }
}
