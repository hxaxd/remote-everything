import Combine
import Foundation
import SwiftUI
import UIKit

/// The app's single coordinator: coordinates state across Controllers and exposes
/// unified state for SwiftUI views.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var settings: ClientSettings
    @Published var notice: Notice?
    @Published var path: [AppRoute] = []
    @Published var selectedNodeID: String?
    /// What the wide (two-column) layout's right pane shows instead of a node:
    /// settings or pairing, embedded beside the list the way Android embeds
    /// them (084aa92). On a phone these are a sheet and a pushed page instead.
    @Published var pane: AppPane?
    @Published private(set) var updateState: UpdateState = .idle

    /// The two panes a wide screen may hold beside the node list.
    enum AppPane: Equatable {
        case settings
        case addNode
    }

    // S2 View Bindings (delegated to pairingSession)
    var addNodeText: String {
        get { pairingSession.addNodeText }
        set { pairingSession.addNodeText = newValue }
    }
    var deviceNameDraft: String {
        get { pairingSession.deviceNameDraft }
        set { pairingSession.deviceNameDraft = newValue }
    }

    // MARK: - Controllers

    let nodesController: NodesController
    let catalogController: CatalogController
    let pairingSession: PairingSession

    // MARK: - Collaborators

    private let store: ClientStore
    private let vault: IdentityVault
    private let pairingCoordinator: PairingCoordinator
    private let clients: GatewayClientPool
    private let pathSelector = PathSelector.Cache()
    private let network = NetworkMonitor()
    private let updateChecker: UpdateChecker

    private var refreshLoop: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Forwarded Properties for Views

    var identities: [Identity] { nodesController.identities }
    var nodes: [Node] { nodesController.nodes }
    var stagedSetups: [StagedSetup] { nodesController.stagedSetups }
    var identityConditions: [String: IdentityCondition] { nodesController.identityConditions }
    var isRefreshing: Bool { nodesController.isRefreshing }
    var catalogs: [String: CatalogState] { catalogController.catalogs }
    var pairingPhase: PairingPhase { pairingSession.pairingPhase }
    var invitation: SetupURI.Invitation? { pairingSession.invitation }
    var invitationError: SetupURI.Rejected? { pairingSession.invitationError }

    init(
        store: ClientStore = ClientStore(),
        vault: IdentityVault = IdentityVault(),
        updateChecker: UpdateChecker = UpdateChecker(),
        clients: GatewayClientPool = GatewayClientPool()
    ) {
        self.store = store
        self.vault = vault
        self.updateChecker = updateChecker
        self.clients = clients
        self.settings = store.loadSettings()

        let stages = StagedSetupStore(directory: store.pairingDirectory)
        let pairingCoord = PairingCoordinator(vault: vault, stages: stages) { origin, credential, pin in
            if credential == nil {
                return clients.pairingClient(origin: origin, pin: pin)
            }
            return GatewayClient(origin: origin, credential: credential, pin: pin)
        }
        self.pairingCoordinator = pairingCoord

        let nodesCtrl = NodesController(
            store: store,
            vault: vault,
            clients: clients,
            pathSelector: pathSelector,
            network: network
        )
        self.nodesController = nodesCtrl

        let catalogCtrl = CatalogController(
            nodesController: nodesCtrl,
            clients: clients,
            vault: vault,
            pathSelector: pathSelector
        )
        self.catalogController = catalogCtrl

        let pairingSess = PairingSession(
            pairing: pairingCoord,
            nodesController: nodesCtrl,
            clients: clients
        )
        self.pairingSession = pairingSess

        // Wire event handlers between controllers
        catalogCtrl.onNotice = { [weak self] notice in
            self?.notice = notice
        }
        pairingSess.onNotice = { [weak self] notice in
            self?.notice = notice
        }
        pairingSess.onCatalogReady = { [weak self] nodeID, catalog in
            self?.catalogController.setCatalog(.ready(catalog.applicationInfos), forNodeID: nodeID)
        }
        pairingSess.onClosePairPage = { [weak self] in
            self?.closePairPresentation()
        }

        // Propagate objectWillChange from child controllers to AppModel
        nodesCtrl.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        catalogCtrl.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        pairingSess.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        Localization.apply(settings.language)
        // The window exists by now: apply the stored appearance at the level
        // that reaches every sheet and cover.
        applyAppearanceToWindows()
        network.onPathChange = { [weak self] in
            guard let self else { return }
            // The chosen path belongs to the network that is gone: it is retired
            // here so the next look re-decides between what is left, and whatever
            // node is on screen is asked again now rather than at the next tick
            // (Android networkChanged).
            self.pathSelector.reset()
            Task { await self.refreshNodes() }
            self.catalogController.recheckNow()
        }
        network.start()
        let (_, lost) = nodesController.reconcile(pairing: pairingCoordinator)
        if let first = lost.first {
            notice = .credentialLost(first)
        }
        Task { await refreshNodes() }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startForegroundLoops()
            Task { await refreshNodes() }
        case .background:
            stopForegroundLoops()
        default:
            break
        }
    }

    private func startForegroundLoops() {
        startRefreshLoop()
        pairingSession.startPendingLoop()
    }

    private func stopForegroundLoops() {
        refreshLoop?.cancel()
        refreshLoop = nil
        pairingSession.stopLoops()
        catalogController.stopLoops()
    }

    private func startRefreshLoop() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNodes()
                do {
                    try await Task.sleep(nanoseconds: Cadence.nodeRefreshNanos)
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Nodes

    func refreshNodes() async {
        // The minimum working-line time lives in the controller, next to
        // `isRefreshing`, so a fast refresh is still visible as the thing it is.
        await nodesController.refreshNodes()
    }

    func status(of node: Node) -> NodeStatus {
        nodesController.status(of: node)
    }

    func preferredPath(for node: Node) -> Path? { nodesController.preferredPath(for: node) }

    func node(withID id: String) -> Node? {
        nodesController.node(withID: id)
    }

    func identity(forPath path: Path) -> Identity? {
        nodesController.identity(forPath: path)
    }

    func nodeCount(forIdentity identity: Identity) -> Int {
        nodesController.nodeCount(forIdentity: identity)
    }

    // MARK: - Catalog & App Control

    func beginCatalogPolling(nodeID: String) {
        catalogController.beginCatalogPolling(nodeID: nodeID)
    }

    func endCatalogPolling() {
        catalogController.endCatalogPolling()
    }

    func loadCatalog(nodeID: String) async {
        await catalogController.loadCatalog(nodeID: nodeID)
    }

    func startApplication(nodeID: String, appID: String) {
        catalogController.startApplication(nodeID: nodeID, appID: appID)
    }

    func stopApplication(nodeID: String, appID: String) {
        catalogController.stopApplication(nodeID: nodeID, appID: appID)
    }

    func resolveWebTarget(nodeID: String, appID: String) async throws -> WebTarget {
        try await catalogController.resolveWebTarget(nodeID: nodeID, appID: appID)
    }

    // MARK: - S2 Pairing

    func beginAddNode() {
        pairingSession.beginAddNode()
        pushPairRoute()
    }

    /// Cancels the attempt in flight, keeping the invitation in the field.
    func cancelPairingAttempt() {
        pairingSession.cancelPairingAttempt()
    }

    func parseInvitation(_ text: String) {
        pairingSession.parseInvitation(text)
    }

    func handleIncomingURL(_ url: URL) {
        pairingSession.handleIncomingURL(url)
        addNodeText = url.absoluteString
        pushPairRoute()
    }

    func confirmPairing() async {
        await pairingSession.confirmPairing()
    }

    func resumeStagedSetups() async {
        await pairingSession.resumeStagedSetups()
    }

    // MARK: - The wide layout's panes

    /// Opens one of the wide screen's panes. Pairing starts a fresh flow; the
    /// detail column is cleared so the pane stands alone beside the list.
    func setPane(_ pane: AppPane?) {
        if pane == .addNode {
            pairingSession.beginAddNode()
            path.removeAll()
            selectedNodeID = nil
        }
        self.pane = pane
    }

    /// Opens settings: the pane on a wide screen, a pushed page on a phone — a
    /// sheet is not used, because a presented sheet cannot be relied on to
    /// follow an appearance change (the other clients' settings are a screen).
    func pushSettings() {
        guard !path.contains(where: { if case .settings = $0 { return true }; return false }) else { return }
        path.append(.settings)
    }

    /// Closes settings, whichever presentation it is: the pushed page on a
    /// phone, the pane on a wide screen.
    func closeSettings() {
        path.removeAll { if case .settings = $0 { return true }; return false }
        if pane == .settings { pane = nil }
    }

    /// Closes the pairing page, whichever presentation it is.
    func closePairPresentation() {
        popPairRoute()
        if pane == .addNode { pane = nil }
    }

    /// The pairing page is a pushed page on a phone and a pane on a wide
    /// screen; this is the pushed half, a sheet's worth of navigation.
    private func pushPairRoute() {
        guard !path.contains(where: { if case .pair = $0 { return true }; return false }) else { return }
        path.append(.pair)
    }

    private func popPairRoute() {
        path.removeAll { if case .pair = $0 { return true }; return false }
    }

    static func defaultDeviceName() -> String {
        PairingSession.defaultDeviceName()
    }

    // MARK: - S5 Settings

    var preferredColorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func setLanguage(_ language: Language) {
        settings.language = language
        store.saveSettings(settings)
        // "Follow the system" is answered by what the system says *after* the
        // previous choice has stopped overriding it: persist first, resolve after.
        Localization.persistPreferredLanguage(language)
        Localization.apply(language)
    }

    func setAppearance(_ appearance: Appearance) {
        settings.appearance = appearance
        store.saveSettings(settings)
        applyAppearanceToWindows()
    }

    /// Appearance is applied at the window level, not through SwiftUI's
    /// preferredColorScheme: a window's overrideUserInterfaceStyle reaches
    /// every view the scene presents — the settings sheet included — through
    /// its trait collection, immediately and in both directions (including
    /// back to "follow the system"). preferredColorScheme alone left a
    /// presented sheet behind.
    func applyAppearanceToWindows() {
        let style: UIUserInterfaceStyle
        switch settings.appearance {
        case .light: style = .light
        case .dark: style = .dark
        case .system: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    func forget(origin: String) async {
        guard identities.contains(where: { $0.origin == origin }) else { return }
        // A pairing staged against this gateway is part of what is being
        // forgotten: its row, its resume file and the credential it names go
        // with the identity (behavior README — forgetting does not leave a
        // half-pairing behind).
        pairingSession.discardStagedSetups(origin: origin)
        catalogController.clear()
        nodesController.forget(origin: origin)
        await refreshNodes()
    }

    func checkForUpdates() async {
        guard updateState != .checking else { return }
        updateState = .checking
        let result = await updateChecker.check(
            currentBuildNumber: AppVersion.buildNumber,
            currentProtocolVersion: AppVersion.protocolVersion
        )
        updateState = .result(result)
    }

    func dismissNotice(_ notice: Notice) {
        if self.notice == notice { self.notice = nil }
    }

    // --- connections & diagnostics -------------------------------------------

    func troubleFor(_ origin: String) -> LinkTrouble? {
        nodesController.troubleFor(origin)
    }

    /// The report a person copies out of a connection that will not answer.
    ///
    /// It is built here rather than on the screen because most of it is not on the
    /// screen: what the last few probes failed with, when this connection last
    /// answered, and which road each machine was reachable by.
    func troubleReport(identity: Identity) -> String {
        guard let trouble = nodesController.troubleFor(identity.origin) else { return "" }
        let say: (String, String?) -> String = { key, arg in
            if let arg {
                return l10n(key, arg)
            } else {
                return l10n(key)
            }
        }
        let machines = nodes
            .filter { node in node.paths.contains { $0.origin == identity.origin } }
            .map { node -> String in
                let roads = node.paths
                    .filter { $0.origin == identity.origin }
                    .map { path -> String in
                        let label = say(
                            path.link == .local ? MessageKeys.NODE_LAN : MessageKeys.NODE_TUNNEL,
                            nil
                        )
                        let mark = path.reachable == true ? "✓" : "✗"
                        let latency = (path.reachable == true && path.latencyMs != nil) ? " \(path.latencyMs!)ms" : ""
                        return "\(label) \(mark)\(latency)"
                    }
                    .joined(separator: " ")
                return "\(node.name) \(roads)"
            }

        let deviceModel = UIDevice.current.model
        let osVersion = UIDevice.current.systemVersion
        let system = "iOS \(osVersion) · \(deviceModel)"

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"

        return buildLinkReport(
            input: LinkReportInput(
                appName: say(MessageKeys.APP_NAME, nil),
                client: "\(AppVersion.versionName) (\(AppVersion.buildNumber))",
                protocolVersion: "\(AppVersion.protocolVersion)",
                system: system,
                origin: identity.origin,
                deviceName: identity.deviceName,
                network: network.describe(),
                machines: machines,
                trouble: trouble,
                attempts: nodesController.failedProbesFor(identity.origin),
                time: { formatter.string(from: $0) }
            ),
            say: say
        )
    }
}
