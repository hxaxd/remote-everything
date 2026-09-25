import Foundation

/// The pairing flow: an invitation becomes a credential, the credential becomes
/// an admitted device, and the client is killed between any two of those steps
/// without losing the attempt (stage → activate → promote).
///
/// The one-shot password lives in this type and nowhere else: it is generated
/// per attempt, held only while the attempt runs, and written to the Keychain
/// only merged with the bytes it opens.
final class PairingService {

    /// One attempt, held in memory for as long as the flow is on screen. The
    /// password is part of it because an interrupted pairing must be retried with
    /// the same one: the gateway answers the same (device_name, password) with
    /// the same credential, and a second attempt with a fresh password is a
    /// second redemption of an invitation that is already spent.
    final class Attempt {
        let invitation: SetupURI.Invitation
        let deviceName: String
        let credentialPassword: String

        init(invitation: SetupURI.Invitation, deviceName: String) {
            self.invitation = invitation
            self.deviceName = deviceName
            self.credentialPassword = PairingService.makeCredentialPassword()
        }
    }

    enum Outcome: Equatable {
        /// The device is admitted, and this is the identity to keep.
        case approved(identity: Identity, catalog: CatalogResponse)
        /// The device paired and is waiting for its operator: the staged setup
        /// stays, and the row says "waiting for approval".
        case pendingApproval(staged: StagedSetup)
    }

    private let vault: IdentityVault
    private let stages: StagedSetupStore
    private let makeClient: (String, DeviceCredential?, ServerPin?) -> GatewayClient

    init(
        vault: IdentityVault,
        stages: StagedSetupStore,
        makeClient: @escaping (String, DeviceCredential?, ServerPin?) -> GatewayClient
    ) {
        self.vault = vault
        self.stages = stages
        self.makeClient = makeClient
    }

    // MARK: - The flow

    /// Redeems the invitation, checks what came back, stores the credential and
    /// asks to be activated. Everything before the activation is local and
    /// reversible; from the pairing call on, the gateway is the authority.
    func run(_ attempt: Attempt) async throws -> Outcome {
        let origin = attempt.invitation.origin
        let deviceName = attempt.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SetupURI.isValidNodeName(deviceName) else { throw ClientError(.invalidDeviceName) }

        let client = makeClient(origin, nil, attempt.invitation.serverPin)
        let response = try await client.pair(
            invitation: attempt.invitation.invitation,
            deviceName: deviceName,
            credentialPassword: attempt.credentialPassword
        )

        guard let pkcs12 = Data(base64Encoded: response.credentialPKCS12) else {
            throw ClientError(.pairingFailed)
        }
        let imported = try importCredential(pkcs12: pkcs12, password: attempt.credentialPassword)
        // The fingerprint the response named has to be the one this client
        // computes: a fingerprint that is only claimed is not a fingerprint.
        try CredentialMaterial.verifyFingerprint(imported, expected: response.certificateFingerprint)
        try CredentialMaterial.verifyKeyPair(imported)

        let credentialRef = try vault.store(
            origin: origin,
            pkcs12: pkcs12,
            password: attempt.credentialPassword
        )

        // Everything the resumed attempt needs, in one file, one rename. The
        // gateway names when a pending pairing stops being worth resuming, and
        // the strict decoder guarantees the answer carries that instant — a
        // pairing that could not be read is refused, never given a window the
        // client made up.
        let staged = StagedSetup(
            origin: origin,
            nodeID: attempt.invitation.node,
            nodeName: attempt.invitation.nodeName,
            deviceName: deviceName,
            certificateFingerprint: response.certificateFingerprint,
            credentialRef: credentialRef,
            serverPin: attempt.invitation.serverPin,
            pendingExpiresAt: response.pendingExpiresAt,
            createdAt: Date()
        )
        try stages.stage(staged)

        return try await activate(staged, credential: imported.credential)
    }

    /// Asks to be admitted for the staged node. Success promotes the identity and
    /// drops the stage; waiting keeps it; a refusal that says the attempt cannot
    /// succeed drops it and the credential with it.
    func activate(_ staged: StagedSetup, credential: DeviceCredential) async throws -> Outcome {
        let client = makeClient(staged.origin, credential, staged.serverPin)
        do {
            switch try await client.activate(nodeID: staged.nodeID) {
            case .pendingApproval:
                return .pendingApproval(staged: staged)
            case .approved(let catalog):
                let identity = Identity(
                    origin: staged.origin,
                    deviceName: staged.deviceName,
                    certFingerprint: staged.certificateFingerprint,
                    credentialRef: staged.credentialRef,
                    serverPin: staged.serverPin,
                    createdAt: staged.createdAt
                )
                stages.clear(origin: staged.origin)
                return .approved(identity: identity, catalog: catalog)
            }
        } catch let error as ClientError {
            if PairingCoordinator.endsTheAttempt(error.code) {
                discard(staged)
            }
            throw error
        }
    }

    /// Resumes a staged setup whose activation had not happened yet. The
    /// credential comes back out of the Keychain — this is the case the stage
    /// file exists for.
    func resume(_ staged: StagedSetup) async throws -> Outcome {
        guard !staged.isExpired else {
            discard(staged)
            throw ClientError(.invitationExpired)
        }
        let credential = try vault.credential(origin: staged.origin)
        return try await activate(staged, credential: credential)
    }

    // MARK: - Startup reconcile

    /// What a restart does with what it finds: a staged setup whose pending
    /// window is still open and whose credential is still in the Keychain is
    /// worth resuming; everything else is dropped, because half of it is worse
    /// than none of it.
    func reconcileStages() -> (resumable: [StagedSetup], dropped: [StagedSetup]) {
        var resumable: [StagedSetup] = []
        var dropped: [StagedSetup] = []
        for staged in stages.loadAll() {
            if staged.isExpired || !vault.hasCredential(origin: staged.origin) {
                stages.clear(origin: staged.origin)
                dropped.append(staged)
            } else {
                resumable.append(staged)
            }
        }
        return (resumable, dropped)
    }

    /// Drops a staged setup and the credential that went with it. Used when the
    /// attempt is over and it did not end in an identity.
    func discard(_ staged: StagedSetup) {
        stages.clear(origin: staged.origin)
        vault.forget(aliasRef: staged.credentialRef)
    }

    // MARK: - Tokens

    /// 32 random bytes as base64url with the padding removed: 43 characters,
    /// which is the shape the gateway accepts and nothing else carries.
    static func makeCredentialPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The refusals that mean this attempt cannot succeed: the invitation is
    /// gone, or the gateway says the operator has to look at it.
    static func endsTheAttempt(_ code: ErrorCode) -> Bool {
        switch code {
        case .invitationExpired, .invitationDenied, .activationFailed, .pairingFailed:
            return true
        default:
            return false
        }
    }

    private func importCredential(pkcs12: Data, password: String) throws -> CredentialMaterial.Imported {
        do {
            return try CredentialMaterial.importPKCS12(pkcs12, password: password)
        } catch {
            // A credential that cannot be opened is a pairing that failed, and
            // saying so is the client's own error to own.
            throw ClientError(.pairingFailed)
        }
    }
}

typealias PairingCoordinator = PairingService
