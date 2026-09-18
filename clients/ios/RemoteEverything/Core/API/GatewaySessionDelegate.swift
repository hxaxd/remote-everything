import Foundation

/// What activation answered: admitted, or waiting for the operator.
enum ActivationOutcome: Equatable {
    case approved(CatalogResponse)
    case pendingApproval
}

/// One delegate for one client: it answers the TLS challenges with the shared
/// handler and refuses to be redirected anywhere.
final class GatewaySessionDelegate: NSObject, URLSessionTaskDelegate {

    private let handler: GatewayChallengeHandler

    init(handler: GatewayChallengeHandler) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handler.respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handler.respond(to: challenge, completionHandler: completionHandler)
    }

    /// The API layer does not follow redirects. A redirect is how a response —
    /// and the credential that asked for it — would end up at another origin.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
