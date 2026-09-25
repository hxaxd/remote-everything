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
    /// The pairing page is pushed by the app model, so only it can close it: a
    /// waiting pairing that just ended asks through this callback.
    var onClosePairPage: (() -> Void)?

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

    /// Cancels the attempt in flight, back to the input with the invitation
    /// kept — Android's cancelPairing leaves the field as it was. The answer
    /// that still arrives is committed but touches neither page nor phase.
    func cancelPairingAttempt() {
        pairingAttempt = nil
        if case .pairing = pairingPhase {
            pairingPhase = .idle
        }
    }

    func parseInvitation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Editing the text is a new attempt: the failure it replaces goes with
        // it, the way Android's resetPairing clears the line under the field.
        if case .failed = pairingPhase {
            pairingPhase = .idle
        }
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
                finishIfCurrent(attempt)
            case .pendingApproval(let staged):
                nodesController.setStaged(staged)
                // The page stays open, saying the device is waiting — the same
                // screen Android keeps, with the same retry and the same way back.
                pairingPhase = .pendingApproval(nodeName: staged.nodeName)
                startPendingLoop()
                await nodesController.refreshNodes()
            }
        } catch let error as ClientError {
            failIfCurrent(attempt, .refusal(error))
        } catch is NetworkFailure {
            failIfCurrent(attempt, .network)
        } catch {
            failIfCurrent(attempt, .client)
        }
    }

    /// The sheet belongs to the attempt it is showing: a fresh invitation or a
    /// retry may have replaced this attempt while it was in flight, and an
    /// answer arriving late must not wipe the new attempt's input or fail a
    /// pairing the user did not ask about. The durable half of an outcome is
    /// committed above either way; only the attempt the user is still on may
    /// reset the sheet it sits on. The attempt is a class instance, so identity
    /// is reference equality, not value equality.
    private func finishIfCurrent(_ attempt: PairingCoordinator.Attempt) {
        guard pairingAttempt === attempt else { return }
        finishPairingSheet()
        // Success closes the page itself — Android's pair screen navigates
        // back the moment the gateway admits the device.
        onClosePairPage?()
    }

    private func failIfCurrent(_ attempt: PairingCoordinator.Attempt, _ failure: PairingFailure) {
        guard pairingAttempt === attempt else { return }
        pairingPhase = .failed(failure)
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

    /// Forgetting a gateway takes the pairing still waiting on it with it: the
    /// staged row leaves the list, and the file that would have resumed it — and
    /// the credential it names — go too, exactly as an expired stage does in
    /// `resumeStagedSetups`. The coordinator owns the stage store, so the
    /// discard goes through it; the row removal is the controller's.
    func discardStagedSetups(origin: String) {
        for staged in nodesController.stagedSetups where staged.origin == origin {
            pairing.discard(staged)
        }
        nodesController.removeStaged(origin: origin)
    }

    func resumeStagedSetups() async {
        for staged in nodesController.stagedSetups {
            if staged.isExpired {
                pairing.discard(staged)
                nodesController.removeStaged(origin: staged.origin)
                onNotice?(.invitationExpired)
                closePendingPageIfOpen()
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
                    closePendingPageIfOpen()
                case .pendingApproval:
                    break
                }
            } catch let error as ClientError {
                if PairingCoordinator.endsTheAttempt(error.code) {
                    nodesController.removeStaged(origin: staged.origin)
                    closePendingPageIfOpen()
                    onNotice?(error.code == .invitationExpired ? .invitationExpired : .nodeGone)
                }
            } catch {
            }
        }
    }

    /// A pairing the page is still showing has ended: the page closes itself
    /// the way Android's pair screen navigates back on success or expiry.
    private func closePendingPageIfOpen() {
        if case .pendingApproval = pairingPhase {
            finishPairingSheet()
            onClosePairPage?()
        }
    }

    /// The name this phone introduces itself with: the device's own name as
    /// iOS reports it. (The local hostname was tried as a fallback and came
    /// back "localhost", so the device name stands alone.)
    static func defaultDeviceName() -> String {
        let systemName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return systemName.isEmpty ? kind : systemName
    }
}
