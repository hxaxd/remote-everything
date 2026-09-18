import Foundation
import UIKit

@MainActor
final class PairingSession: ObservableObject {

    @Published var isAddingNode = false
    @Published var addNodeText = ""
    @Published private(set) var invitation: SetupURI.Invitation?
    @Published private(set) var invitationError: SetupURI.Rejected?
    @Published var deviceNameDraft = ""
    @Published private(set) var pairingPhase: PairingPhase = .idle

    private var pairingAttempt: PairingCoordinator.Attempt?
    private var pendingLoop: Task<Void, Never>?

    private let pairing: PairingCoordinator
    private let nodesController: NodesController
    private let clients: GatewayClientPool

    var onNotice: ((Notice) -> Void)?
    var onCatalogReady: ((String, CatalogResponse) -> Void)?

    init(
        pairing: PairingCoordinator,
        nodesController: NodesController,
        clients: GatewayClientPool
    ) {
        self.pairing = pairing
        self.nodesController = nodesController
        self.clients = clients
    }

    func stopLoops() {
        pendingLoop?.cancel()
        pendingLoop = nil
    }

    func beginAddNode() {
        addNodeText = ""
        invitation = nil
        invitationError = nil
        pairingPhase = .idle
        pairingAttempt = nil
        deviceNameDraft = PairingSession.defaultDeviceName()
        isAddingNode = true
    }

    func cancelAddNode() {
        if case .pairing = pairingPhase { return }
        isAddingNode = false
        pairingAttempt = nil
        pairingPhase = .idle
        invitation = nil
        invitationError = nil
        addNodeText = ""
    }

    func parseInvitation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            invitation = nil
            invitationError = nil
            return
        }
        do {
            let parsed = try SetupURI.parse(trimmed)
            invitation = parsed
            invitationError = nil
        } catch let rejection as SetupURI.Rejected {
            invitation = nil
            invitationError = rejection
        } catch {
            invitation = nil
            invitationError = .notASetupURI
        }
    }

    func handleIncomingURL(_ url: URL) {
        let text = url.absoluteString
        if !isAddingNode {
            beginAddNode()
        }
        addNodeText = text
        parseInvitation(text)
    }

    func confirmPairing() async {
        guard let invitation, case .idle = pairingPhase else { return }
        let attempt = PairingCoordinator.Attempt(
            invitation: invitation,
            deviceName: deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        pairingAttempt = attempt
        await runPairing(attempt)
    }

    func retryPairing() async {
        guard let attempt = pairingAttempt else { return }
        await runPairing(attempt)
    }

    func finishPairingSheet() {
        isAddingNode = false
        pairingAttempt = nil
        pairingPhase = .idle
        invitation = nil
        invitationError = nil
        addNodeText = ""
    }

    private func runPairing(_ attempt: PairingCoordinator.Attempt) async {
        pairingPhase = .pairing
        do {
            let outcome = try await pairing.run(attempt)
            switch outcome {
            case .approved(let identity, let catalog):
                nodesController.record(identity)
                clients.drop(origin: identity.origin)
                onCatalogReady?(attempt.invitation.node, catalog)
                await nodesController.refreshNodes()
                finishPairingSheet()
            case .pendingApproval(let staged):
                nodesController.setStaged(staged)
                startPendingLoop()
                finishPairingSheet()
                await nodesController.refreshNodes()
            }
        } catch let error as ClientError {
            pairingPhase = .failed(.refusal(error))
        } catch is NetworkFailure {
            pairingPhase = .failed(.network)
        } catch {
            pairingPhase = .failed(.client)
        }
    }

    func startPendingLoop() {
        pendingLoop?.cancel()
        guard !nodesController.stagedSetups.isEmpty else { return }
        pendingLoop = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Cadence.approvalPollTimeout)
            while !Task.isCancelled, Date() < deadline {
                guard let self else { return }
                if self.nodesController.stagedSetups.isEmpty { return }
                await self.resumeStagedSetups()
                do {
                    try await Task.sleep(nanoseconds: Cadence.approvalPollNanos)
                } catch {
                    return
                }
            }
        }
    }

    func resumeStagedSetups() async {
        for staged in nodesController.stagedSetups {
            if staged.isExpired {
                pairing.discard(staged)
                nodesController.removeStaged(origin: staged.origin)
                onNotice?(.invitationExpired)
                continue
            }
            do {
                switch try await pairing.resume(staged) {
                case .approved(let identity, let catalog):
                    nodesController.record(identity)
                    clients.drop(origin: identity.origin)
                    onCatalogReady?(staged.nodeID, catalog)
                    nodesController.removeStaged(origin: staged.origin)
                    await nodesController.refreshNodes()
                case .pendingApproval:
                    break
                }
            } catch let error as ClientError {
                if PairingCoordinator.endsTheAttempt(error.code) {
                    nodesController.removeStaged(origin: staged.origin)
                    onNotice?(error.code == .invitationExpired ? .invitationExpired : .nodeGone)
                }
            } catch {
            }
        }
    }

    static func defaultDeviceName() -> String {
        let systemName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return systemName.isEmpty ? kind : systemName
    }
}
