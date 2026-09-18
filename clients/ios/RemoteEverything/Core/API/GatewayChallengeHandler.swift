import Foundation

/// How a TLS challenge is answered, wherever it arrives from.
///
/// The three places iOS asks a client to authenticate — URLSession, WKWebView
/// navigation and WKDownload — are three separate callbacks with the same shape,
/// and three copies of this logic is how they drift apart. They all answer
/// through this one type.
///
/// It is resolved before the traffic that needs it starts: a credential handed
/// to a challenge arrives from the vault already imported, and a host check that
/// needed a round trip would be a host check that arrives too late.
final class GatewayChallengeHandler {

    /// What to hand back to whichever callback asked.
    struct Answer {
        let disposition: URLSession.AuthChallengeDisposition
        let credential: URLCredential?
    }

    /// The gateway's host, as the invitation wrote it (no port, lowercase).
    let gatewayHost: String
    /// Present for a gateway that signs its own certificate.
    let pin: ServerPin?
    /// The device credential to present, when this origin has one.
    let credential: DeviceCredential?

    init(gatewayOrigin: String, pin: ServerPin?, credential: DeviceCredential?) {
        self.gatewayHost = GatewayChallengeHandler.host(ofOrigin: gatewayOrigin)
        self.pin = pin
        self.credential = credential
    }

    /// The host part of an origin, lowercased, port dropped.
    static func host(ofOrigin origin: String) -> String {
        var value = origin
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[value.startIndex..<slash])
        }
        if let at = value.lastIndex(of: "@") {
            value = String(value[value.index(after: at)...])
        }
        if let colon = value.lastIndex(of: ":") {
            let port = value[value.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy({ $0.isNumber }) {
                value = String(value[value.startIndex..<colon])
            }
        }
        return value.lowercased()
    }

    /// Whether a host belongs to this gateway. An application origin of a
    /// gateway with a domain is a subdomain of it; on a LAN it is the gateway's
    /// address and a port of its own. A suffix match is only ever done with the
    /// separating dot, so `evil-example.com` is not `example.com`.
    func isGatewayHost(_ host: String) -> Bool {
        let candidate = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !gatewayHost.isEmpty else { return false }
        if candidate == gatewayHost { return true }
        return candidate.hasSuffix("." + gatewayHost)
    }

    /// The answer to one challenge.
    func answer(_ challenge: URLAuthenticationChallenge) -> Answer {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return Answer(disposition: .performDefaultHandling, credential: nil) }
            // A gateway signed by an authority is the system's business: the
            // certificate renews and pinning it is how a client locks itself out.
            guard let pin else { return Answer(disposition: .performDefaultHandling, credential: nil) }
            if PinnedTrust.evaluate(trust, pin: pin) {
                return Answer(disposition: .useCredential, credential: URLCredential(trust: trust))
            }
            return Answer(disposition: .cancelAuthenticationChallenge, credential: nil)

        case NSURLAuthenticationMethodClientCertificate:
            // The device certificate is the gateway's, and it is presented to
            // that gateway and to nothing else: any site that asks for a client
            // certificate gets no answer rather than someone else's identity.
            guard let credential, isGatewayHost(space.host) else {
                return Answer(disposition: .performDefaultHandling, credential: nil)
            }
            return Answer(
                disposition: .useCredential,
                credential: URLCredential(
                    identity: credential.identity,
                    certificates: credential.certificates,
                    persistence: .forSession
                )
            )

        default:
            return Answer(disposition: .performDefaultHandling, credential: nil)
        }
    }

    /// Answers a challenge through one of the three callbacks.
    func respond(
        to challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let answer = answer(challenge)
        completionHandler(answer.disposition, answer.credential)
    }
}
