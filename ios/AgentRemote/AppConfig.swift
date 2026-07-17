import Foundation

enum AppConfig {
    static let gatewayHost = "__GATEWAY_HOST__"
    static let gatewayOrigin = "__GATEWAY_ORIGIN__"
    static let enrollRequestURL = URL(string: gatewayOrigin + "/__kimi_enroll/request")!
    static let enrollStatusURL = URL(string: gatewayOrigin + "/__kimi_enroll/status")!
    static let appsURL = URL(string: gatewayOrigin + "/__agent_remote/apps")!
    static let controlToken = "__CONTROL_TOKEN__"
    static let bootstrapPassword = "__BOOTSTRAP_PASSWORD__"
    static let bootstrapFingerprint = "__BOOTSTRAP_FINGERPRINT__"

    static func appActionURL(_ id: String, _ action: String) -> URL {
        URL(string: gatewayOrigin + "/__agent_remote/apps/\(id)/\(action)")!
    }
}
