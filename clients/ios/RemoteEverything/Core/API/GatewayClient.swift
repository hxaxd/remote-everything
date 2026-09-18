import Foundation

/// The protocol client: the endpoints of clients/contracts and nothing else. One
/// instance per gateway origin, because a credential, a pin and a connection
/// belong to an origin — a client bound to one cannot be asked for another by
/// mistake, and the connection pool is reused across a poll rather than
/// handshaking again every time.
///
/// Application traffic never comes through here: it belongs to the WebView and
/// to the origin `open` answers with.
///
/// How long a request is given comes from `Cadence`, the table this client shares
/// with the other two: everything here is an ordinary request except the node
/// list, which is asked with the shorter probe timeout because it is also the
/// path probe.
final class GatewayClient {

    enum Paths {
        static let pair = "/__remote_everything_pair"
        static let activate = "/__remote_everything_activate"
        static let nodes = "/__remote_everything/nodes"
        static let apps = "/__remote_everything/apps"
        static func status(_ id: String) -> String { "/__remote_everything/apps/\(id)/status" }
        static func start(_ id: String) -> String { "/__remote_everything/apps/\(id)/start" }
        static func stop(_ id: String) -> String { "/__remote_everything/apps/\(id)/stop" }
        static func open(_ id: String) -> String { "/__remote_everything/open/\(id)" }
    }

    /// The header that names the node a request is for. Every request except the
    /// node list carries it, because a gateway serves several nodes.
    static let nodeHeader = "X-Remote-Everything-Node"

    let origin: String
    let originURL: URL
    let handler: GatewayChallengeHandler

    private let session: URLSession
    private let sessionDelegate: GatewaySessionDelegate

    init(origin: String, credential: DeviceCredential?, pin: ServerPin?) {
        self.origin = origin
        self.originURL = GatewayClient.url(forOrigin: origin)
        let handler = GatewayChallengeHandler(gatewayOrigin: origin, pin: pin, credential: credential)
        self.handler = handler
        self.sessionDelegate = GatewaySessionDelegate(handler: handler)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Cadence.requestTimeout
        configuration.timeoutIntervalForResource = Cadence.requestTimeout * 2
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        self.session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Endpoints

    /// Redeem an invitation. The one request made without a credential.
    func pair(invitation: String, deviceName: String, credentialPassword: String) async throws -> PairingResponse {
        let body = PairingRequest(deviceName: deviceName, credentialPassword: credentialPassword)
        var request = try makeRequest(method: "POST", path: Paths.pair, nodeID: nil, timeout: Cadence.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Invitation \(invitation)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200:
            return try decode(PairingResponse.self, from: data)
        default:
            throw refusal(from: data, status: response.statusCode)
        }
    }

    /// Be admitted for one node. A device waiting for its operator is told so
    /// rather than refused, and HTTP 202 is that sentence.
    func activate(nodeID: String) async throws -> ActivationOutcome {
        let request = try makeRequest(method: "POST", path: Paths.activate, nodeID: nodeID, timeout: Cadence.requestTimeout)
        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200:
            return .approved(try decode(CatalogResponse.self, from: data))
        case 202:
            let refusal = refusal(from: data, status: 202)
            if refusal.code == .approvalPending { return .pendingApproval }
            throw refusal
        default:
            throw refusal(from: data, status: response.statusCode)
        }
    }

    /// Which nodes this device may reach — the one request that names no node.
    func nodes(timeout: TimeInterval = Cadence.requestTimeout) async throws -> NodesResponse {
        let request = try makeRequest(method: "GET", path: Paths.nodes, nodeID: nil, timeout: timeout)
        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else { throw refusal(from: data, status: response.statusCode) }
        return try decode(NodesResponse.self, from: data)
    }

    /// What one node runs.
    func catalog(nodeID: String) async throws -> CatalogResponse {
        let request = try makeRequest(method: "GET", path: Paths.apps, nodeID: nodeID, timeout: Cadence.requestTimeout)
        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else { throw refusal(from: data, status: response.statusCode) }
        return try decode(CatalogResponse.self, from: data)
    }

    func status(nodeID: String, appID: String) async throws -> ControlResponse {
        let request = try makeRequest(method: "GET", path: Paths.status(appID), nodeID: nodeID, timeout: Cadence.requestTimeout)
        return try await control(request)
    }

    func start(nodeID: String, appID: String) async throws -> ControlResponse {
        let request = try makeRequest(method: "POST", path: Paths.start(appID), nodeID: nodeID, timeout: Cadence.requestTimeout)
        return try await control(request)
    }

    func stop(nodeID: String, appID: String) async throws -> ControlResponse {
        let request = try makeRequest(method: "POST", path: Paths.stop(appID), nodeID: nodeID, timeout: Cadence.requestTimeout)
        return try await control(request)
    }

    /// Where an application lives: the absolute origin its WebView is loaded
    /// from. This call does not follow the redirect — the redirect *is* the
    /// answer, and following it would be asking for the application's bytes
    /// through a client that is not a browser.
    func open(nodeID: String, appID: String) async throws -> URL {
        let request = try makeRequest(method: "GET", path: Paths.open(appID), nodeID: nodeID, timeout: Cadence.requestTimeout)
        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 300...399:
            guard let location = response.value(forHTTPHeaderField: "Location") else {
                throw ClientError(.internalError, httpStatus: response.statusCode)
            }
            // The contract says absolute; resolving keeps a relative answer
            // pointing at the gateway instead of at nothing.
            guard let url = URL(string: location, relativeTo: originURL)?.absoluteURL else {
                throw ClientError(.internalError, httpStatus: response.statusCode)
            }
            return url
        case 200:
            throw ClientError(.internalError, httpStatus: 200)
        default:
            throw refusal(from: data, status: response.statusCode)
        }
    }

    // MARK: - Requests

    /// An origin a request can be built from. An origin that does not parse
    /// becomes a path-only URL whose host is empty, which every request below
    /// refuses: there is no gateway to talk to, and guessing one is not an option.
    private static func url(forOrigin origin: String) -> URL {
        URL(string: origin) ?? URL(fileURLWithPath: "/")
    }

    private func makeRequest(method: String, path: String, nodeID: String?, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: originURL)?.absoluteURL else {
            throw NetworkFailure(nil)
        }
        // Every request this client makes is to this client's gateway; nothing
        // else may ever be asked with this credential.
        guard handler.isGatewayHost(url.host ?? "") else { throw NetworkFailure(nil) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let nodeID {
            request.setValue(nodeID, forHTTPHeaderField: GatewayClient.nodeHeader)
        }
        return request
    }

    private func control(_ request: URLRequest) async throws -> ControlResponse {
        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else { throw refusal(from: data, status: response.statusCode) }
        return try decode(ControlResponse.self, from: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetworkFailure(nil) }
            return (data, http)
        } catch let failure as ClientError {
            throw failure
        } catch let error as DecodingError {
            throw error
        } catch {
            throw NetworkFailure(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // A body this client cannot read is not retried with a guess: the
            // refusal it carries is unknown, and internal_error is what the
            // contract calls an answer the gateway failed to write.
            throw ClientError(.internalError, httpStatus: nil)
        }
    }

    /// The refusal a body names, or the one its status names when the body is
    /// unreadable. The code wins whenever there is one — HTTP is the same
    /// decision written twice, not a second opinion.
    private func refusal(from data: Data, status: Int) -> ClientError {
        if let body = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return ClientError(body.code, httpStatus: status)
        }
        return ClientError(GatewayClient.code(forStatus: status), httpStatus: status)
    }

    static func code(forStatus status: Int) -> ErrorCode {
        switch status {
        case 400: return .invalidBody
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .rateLimited
        case 503: return .serverBusy
        default: return .internalError
        }
    }
}

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
