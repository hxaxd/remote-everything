// The single view model facade: coordinates controllers and UI state.
//
// The navigation stack is held and driven here on purpose, and is not extracted
// into a coordinator: pushing and popping destinations is the platform shell's own
// idiom (NavPathStack belongs to the ability's UI, not to a use case), so the few
// wrappers below are the whole of it.

import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { LinkKind, AppInfo, AppState, Appearance, GatewayPath, Identity, Language, NodeStatus } from '../core/model/Models';
import { decodeRelease, ReleaseManifest, RELEASE_URL, UpdateCheck, verdictFor } from '../core/update/UpdateChecker';
import { IdentityVault } from '../core/identity/IdentityVault';
import { ProtocolClient } from '../core/api/ProtocolClient';
import { NetworkEnvironment } from '../core/pathselect/NetworkEnvironment';
import { PathSelector } from '../core/pathselect/PathSelector';
import { PairingService } from '../core/pairing/PairingService';
import { StagedSetup, StagedSetupStore } from '../core/pairing/StagedSetup';
import { parseSetupUri } from '../core/setup/SetupUri';
import { NodeCacheStore } from '../core/store/NodeCacheStore';
import { AtomicFile } from '../core/store/AtomicFile';
import { Settings, SettingsStore } from '../core/store/SettingsStore';
import { WebAppPrefs } from '../core/store/WebAppPrefs';
import { Cadence } from '../core/model/Cadence';
import { LinkReportInput, LinkTrouble, buildLinkReport } from '../core/diag/LinkReport';
import { MessageKeys } from '../core/model/MessageKeys';
import { Strings } from './i18n/Strings';
import { Metrics, TypeScale } from './theme/Tokens';
import { PROTOCOL_VERSION } from './BuildInfo';
import { CatalogPhase, CatalogState, NodeRow, PairingState, WebSession } from './State';
import { WindowLayout } from './WindowLayout';
import { NodesController } from './NodesController';
import { CatalogController } from './CatalogController';
import { PairingSession } from './PairingSession';

export { CatalogPhase, CatalogState, NodeRow, PairingState, PairingStage, WebSession } from './State';

const TOAST_MS = 2500;
/** The copy's own confirmation: the shortest thing this app says. */
const COPIED_MS = 1200;

/** Two digits, the way a timestamp reads. */
function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

@ObservedV2
export class AppModel {
  @Trace settings: Settings = Settings.defaults();
  @Trace dark: boolean = false;
  @Trace loaded: boolean = false;
  @Trace update: UpdateCheck | null = null;
  @Trace checkingUpdate: boolean = false;
  @Trace toast: string = '';
  /** A line already spoken, for the message that carries a name (a saved file). */
  @Trace toastText: string = '';
  @Trace wide: boolean = false;
  @Trace deviceName: string = '';
  @Trace selectedApp: AppInfo | null = null;
  @Trace pendingLink: string = '';
  /** The web host on top must own the whole window. Settings and pairing stay
   *  beside the list, so they never touch the bar — a system back that pops them
   *  inside Navigation would otherwise leave the bar hidden. */
  @Trace paneFullscreen: boolean = false;

  @Trace nodesController: NodesController;
  @Trace catalogController: CatalogController;
  @Trace pairingSession: PairingSession;

  get identities(): Identity[] { return this.nodesController.identities; }
  get nodes(): NodeRow[] { return this.nodesController.nodes; }
  get refreshing(): boolean { return this.nodesController.refreshing; }
  get trouble(): Map<string, LinkTrouble> { return this.nodesController.trouble; }
  get catalog(): CatalogState { return this.catalogController.catalog; }
  get catalogNodeId(): string { return this.catalogController.catalogNodeId; }
  get web(): WebSession | null { return this.catalogController.web; }
  get webFailed(): string { return this.catalogController.webFailed; }
  get pairing(): PairingState { return this.pairingSession.pairing; }
  get pairingBusy(): boolean { return this.pairingSession.pairingBusy; }

  private readonly vault: IdentityVault = new IdentityVault();
  private readonly cache: NodeCacheStore = new NodeCacheStore();
  private readonly settingsStore: SettingsStore = new SettingsStore();
  private readonly client: ProtocolClient;
  private readonly transaction: StagedSetupStore;
  private readonly pairingService: PairingService;
  private readonly selector: PathSelector = new PathSelector();
  private readonly environment: NetworkEnvironment = new NetworkEnvironment();

  private context: common.UIAbilityContext | null = null;
  private foreground: boolean = false;
  private started: boolean = false;
  private refreshTimer: number = -1;
  private toastTimer: number = -1;
  private stack: NavPathStack | null = null;
  private buildNumber: number = 0;
  private versionName: string = '';
  private systemDark: boolean = false;
  private openingApp: boolean = false;
  /** The pushed screens, mirroring the navigation stack, to know which one is on top. */
  private paneStack: string[] = [];
  /** The node page to return to after a cold start, until it is either found or given up. */
  private pendingRestoreNode: string = '';

  constructor() {
    this.client = new ProtocolClient(this.vault);
    this.transaction = new StagedSetupStore(this.vault);
    this.pairingService = new PairingService(this.client, this.vault, this.transaction, this.settingsStore);

    const nodesCtrl = new NodesController(
      this.vault,
      this.settingsStore,
      this.cache,
      this.client,
      this.selector,
      this.environment
    );
    this.nodesController = nodesCtrl;

    const catalogCtrl = new CatalogController(this.client, this.vault, nodesCtrl);
    this.catalogController = catalogCtrl;

    const pairingSess = new PairingSession(this.pairingService, this.transaction, nodesCtrl);
    this.pairingSession = pairingSess;

    catalogCtrl.onToast = (key: string): void => {
      this.showToast(key);
    };

    pairingSess.onFinished = (): void => {
      this.popPane();
    };
  }

  // ---- Lifecycle ---------------------------------------------------------------

  async boot(context: common.UIAbilityContext): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    this.context = context;
    AtomicFile.init(context.filesDir);
    this.settings = this.settingsStore.open(context);
    Strings.attach(context.resourceManager, this.settings.language);
    Strings.apply(context, this.settings.language);
    this.systemDark = WindowLayout.readSystemDark(context);
    this.dark = WindowLayout.effectiveDark(this.settings.appearance, this.systemDark);
    // The network the device is on is watched from here up: a change asks every
    // gateway again immediately, the way the other clients answer a network swap.
    this.environment.onNetworkChange = (): void => {
      this.onNetworkChanged();
    };
    this.environment.start();
    this.nodesController.reloadIdentities();
    const staged: StagedSetup | null = await this.transaction.reconcile();
    if (staged !== null) {
      this.pairingSession.beginApprovalPolling();
    }
    this.loaded = true;
    this.pendingRestoreNode = this.settingsStore.readLastNode();
    await this.refreshNodes();
  }

  foregroundChanged(active: boolean): void {
    if (active === this.foreground) {
      return;
    }
    this.foreground = active;
    this.pairingSession.varForeground = active;
    if (active) {
      this.environment.start();
      this.refreshNodes();
      this.startNodesRefresh();
      // A node page that was open when the app left keeps its 30s catalog tick:
      // the screen is still there, so it still asks.
      if (this.catalogNodeId !== '') {
        this.startCatalogRefresh();
      }
      this.pairingSession.retryStaged();
    } else {
      this.stopTimers();
      this.client.releaseAll();
    }
  }

  refreshSystemDark(): void {
    if (this.context === null) {
      return;
    }
    // The application's own colour choice rides in this config while one is
    // applied: reading it then would mistake the app's choice for the system's,
    // and "follow the system" would follow the last thing the operator picked.
    // Only when the app follows the system does the config say what the system does.
    if (this.settings.appearance !== Appearance.System) {
      return;
    }
    this.systemDark = WindowLayout.readSystemDark(this.context);
    this.dark = WindowLayout.effectiveDark(this.settings.appearance, this.systemDark);
  }

  setLanguage(language: Language): void {
    this.settings = this.settings.withLanguage(language);
    this.settingsStore.write(this.settings);
    if (this.context !== null) {
      Strings.apply(this.context, language);
    }
  }

  setAppearance(appearance: Appearance): void {
    this.settings = this.settings.withAppearance(appearance);
    this.settingsStore.write(this.settings);
    if (this.context !== null) {
      WindowLayout.applyColorMode(this.context, appearance);
    }
    this.dark = WindowLayout.effectiveDark(appearance, this.systemDark);
    if (appearance === Appearance.System && this.context !== null) {
      // Unsetting the application's own colour mode lands a beat later; the
      // system's real answer is read once it has.
      setTimeout((): void => {
        this.refreshSystemDark();
      }, 200);
    }
  }

  listenWindowSize(context: Context | undefined): void {
    WindowLayout.listenWindowSize(context, (wide: boolean, shortSideVp: number) => {
      this.wide = wide;
      // The whole visual scale rides on the short side, so a tablet reads like a
      // larger phone and not like a phone seen from across the room.
      TypeScale.applyScale(TypeScale.uiScale(shortSideVp));
      Metrics.applyScale(TypeScale.uiScale(shortSideVp));
    });
  }

  // ---- Nodes -------------------------------------------------------------------

  async refreshNodes(force: boolean = false): Promise<void> {
    await this.nodesController.refreshNodes(force);
    this.maybeRestoreNode();
  }

  /** Returns to the node page a cold start was asked to, once it is on the list. */
  private maybeRestoreNode(): void {
    if (this.pendingRestoreNode === '') {
      return;
    }
    const nodeId: string = this.pendingRestoreNode;
    if (this.nodeRow(nodeId) === null) {
      // The gateway has not answered for it yet — or it is gone. Either way it is
      // not on the list to be opened, and the next refresh tries again.
      return;
    }
    this.pendingRestoreNode = '';
    this.selectNode(nodeId);
  }

  nodeRow(nodeId: string): NodeRow | null {
    return this.nodesController.nodeRow(nodeId);
  }

  nodesForOrigin(origin: string): number {
    return this.nodesController.nodesForOrigin(origin);
  }

  nodeTitle(): string {
    const row: NodeRow | null = this.nodeRow(this.catalogNodeId);
    return row === null ? '' : row.node.name;
  }

  nodePath(): GatewayPath | null {
    const row: NodeRow | null = this.nodeRow(this.catalogNodeId);
    return (row === null || !row.isOnline) ? null : row.chosen;
  }

  /** What this node's state is called right now, for the header's subtitle. */
  nodeStatus(): NodeStatus {
    const row: NodeRow | null = this.nodeRow(this.catalogNodeId);
    return row === null ? NodeStatus.Unknown : row.status;
  }

  /** Whether the link in use right now is the local one, in the words this app shows. */
  nodeLinkIsLocal(): boolean {
    const path: GatewayPath | null = this.nodePath();
    return path !== null && path.link === LinkKind.Local;
  }

  // ---- Connections -------------------------------------------------------------

  /**
   * The report a person copies out of a connection that will not answer.
   *
   * It is built here rather than on the screen because most of it is not on the
   * screen: what the last few probes failed with, when this connection last
   * answered, and which road each machine of it was reachable by.
   */
  troubleReport(identity: Identity): string {
    const trouble: LinkTrouble | null = this.troubleFor(identity.origin);
    if (trouble === null) {
      return '';
    }
    const machines: string[] = [];
    for (const row of this.nodes) {
      const roads: string[] = [];
      for (const path of row.node.paths) {
        if (path.origin !== identity.origin) {
          continue;
        }
        const label: string = Strings.text(
          path.link === LinkKind.Local ? MessageKeys.NODE_LAN : MessageKeys.NODE_TUNNEL);
        const mark: string = path.reachable === true ? '✓' : '✗';
        const latency: string = path.reachable === true && path.latencyMs !== null ? ` ${path.latencyMs}ms` : '';
        roads.push(`${label} ${mark}${latency}`);
      }
      if (roads.length > 0) {
        machines.push(`${row.node.name} ${roads.join(' ')}`);
      }
    }
    return buildLinkReport(
      new LinkReportInput(
        Strings.text(MessageKeys.APP_NAME),
        `${this.version()} (${this.build()})`,
        `${this.protocolVersion()}`,
        this.systemLine(),
        identity.origin,
        identity.deviceName,
        this.environment.describe(),
        machines,
        trouble,
        this.nodesController.attemptsFor(identity.origin),
        (at: number): string => this.formatStamp(at)
      ),
      (key: string, arg: string | null): string => arg === null ? Strings.text(key) : Strings.text1(key, arg)
    );
  }

  /** Why this connection is not answering, or null while it is. */
  troubleFor(origin: string): LinkTrouble | null {
    const trouble: LinkTrouble | undefined = this.trouble.get(origin);
    return trouble === undefined ? null : trouble;
  }

  /**
   * What a reader needs to know about the device the report came from, in one
   * line: the system, its API level, and what the device calls itself.
   */
  private systemLine(): string {
    const parts: string[] = [];
    try {
      const os: string = deviceInfo.osFullName;
      const api: number = deviceInfo.sdkApiVersion;
      if (os.length > 0) {
        parts.push(api > 0 ? `${os} (API ${api})` : os);
      }
    } catch (error) {
      // A platform that will not answer leaves the line short rather than wrong.
    }
    try {
      const market: string = deviceInfo.marketName;
      const model: string = market.length > 0 ? market : deviceInfo.productModel;
      if (model.length > 0) {
        parts.push(model);
      }
    } catch (error) {
      // Same: the report is still worth copying without the model.
    }
    return parts.length > 0 ? parts.join(' · ') : 'unknown';
  }

  private formatStamp(at: number): string {
    const date: Date = new Date(at);
    return `${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ` +
      `${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())}`;
  }

  // ---- Catalog & Apps ----------------------------------------------------------

  async loadCatalog(nodeId: string): Promise<void> {
    await this.catalogController.loadCatalog(nodeId);
  }

  /**
   * A person asking again from a screen that says something is unreachable: the
   * node list is read again — the paths it carries are what a catalog is fetched
   * through — and the screen says it is trying before the answer arrives, so the
   * button is not a button that does nothing.
   */
  async retryCatalog(nodeId: string): Promise<void> {
    this.catalogController.catalog = new CatalogState(CatalogPhase.Loading, nodeId, [], null, '');
    await this.refreshNodes();
    await this.loadCatalog(nodeId);
  }

  async toggleApp(nodeId: string, app: AppInfo): Promise<void> {
    await this.catalogController.toggleApp(nodeId, app);
  }

  async beginWeb(nodeId: string, app: AppInfo): Promise<void> {
    await this.catalogController.beginWeb(nodeId, app);
  }

  closeWeb(): void {
    this.catalogController.closeWeb();
  }

  /** Marks the open web session failed: the screen shows it with a retry. */
  failWeb(key: string): void {
    this.catalogController.webFailed = key;
  }

  /**
   * What the web host remembers for one application, as `nodeId/appId` names it,
   * and where a change to those two choices is written.
   */
  webAppPrefs(appKey: string): WebAppPrefs {
    return this.settingsStore.readWebAppPrefs(appKey);
  }

  saveWebAppPrefs(appKey: string, prefs: WebAppPrefs): void {
    this.settingsStore.writeWebAppPrefs(appKey, prefs);
  }

  // ---- Pairing -----------------------------------------------------------------

  setDeviceName(name: string): void {
    this.deviceName = name;
  }

  beginPairing(): void {
    this.pairingSession.beginPairing(this.deviceName);
  }

  cancelPairing(): void {
    this.pairingSession.cancelPairing();
  }

  submitLink(raw: string): void {
    this.pairingSession.submitLink(raw);
  }

  editDeviceNameForPairing(name: string): void {
    this.pairingSession.editDeviceName(name);
  }

  editLink(): void {
    this.pairingSession.editLink();
  }

  clearPairingError(): void {
    this.pairingSession.clearError();
  }

  async confirmPairing(): Promise<void> {
    await this.pairingSession.confirmPairing();
  }

  async retryPairing(): Promise<void> {
    await this.pairingSession.retryPairing();
  }

  openFromLink(uri: string): void {
    this.beginPairing();
    this.submitLink(uri);
    if (this.pendingLink === '' && this.stack !== null) {
      this.pushPane('add');
      return;
    }
    this.pendingLink = uri;
  }

  consumePendingLink(): string {
    const link: string = this.pendingLink;
    this.pendingLink = '';
    return link;
  }

  // ---- Updates & Maintenance ---------------------------------------------------

  async checkUpdate(): Promise<void> {
    if (this.checkingUpdate) {
      return;
    }
    this.checkingUpdate = true;
    try {
      const text: string = await this.client.fetchRelease(RELEASE_URL, Cadence.requestTimeoutMs);
      const manifest: ReleaseManifest = decodeRelease(text);
      this.update = verdictFor(manifest, this.buildNumber, PROTOCOL_VERSION);
    } catch (error) {
      this.update = UpdateCheck.unreachable();
      this.showToast(MessageKeys.SETTINGS_UPDATES_FAILED);
    } finally {
      this.checkingUpdate = false;
    }
  }

  async forget(origin: string): Promise<void> {
    // The pairing still staged for this gateway is part of what is being
    // forgotten — its staged file and its approval polling go with the identity
    // (behavior README: forgetting leaves no half-pairing).
    this.pairingSession.forget(origin);
    await this.nodesController.forget(origin);
    this.catalogController.forgetApplicationHosts(origin);
    if (this.catalogController.catalogNodeId !== '') {
      this.catalogController.catalog = new CatalogState(CatalogPhase.Loading,
        this.catalogController.catalogNodeId, [], null, '');
    }
    await this.refreshNodes();
  }

  /**
   * Whether a pasted or scanned line is an invitation this client would act on:
   * what the input field answers as it is being typed.
   */
  linkIsValid(raw: string): boolean {
    if (raw.trim().length === 0) {
      return false;
    }
    try {
      parseSetupUri(raw);
      return true;
    } catch (error) {
      return false;
    }
  }

  /** Asking a pending pairing to ask again, from the banner or the waiting screen. */
  retryStaged(): Promise<void> {
    return this.pairingSession.retryStaged();
  }

  /** A network came or went: ask every gateway again, now, not on the next timer. */
  private onNetworkChanged(): void {
    if (!this.loaded) {
      return;
    }
    // Forced: a refresh already in flight must not swallow the network change —
    // the roads this phone just lost or gained are the very thing to re-decide.
    this.refreshNodes(true);
    if (this.catalogNodeId !== '') {
      this.loadCatalog(this.catalogNodeId);
    }
  }

  async removeIdentity(origin: string): Promise<void> {
    await this.forget(origin);
  }

  // ---- Navigation --------------------------------------------------------------

  attachStack(stack: NavPathStack): void {
    this.stack = stack;
    this.paneStack = [];
    this.paneFullscreen = false;
  }

  pushAddNode(): void {
    this.pushPane('add');
  }

  pushSettings(): void {
    this.pushPane('settings');
  }

  selectNode(nodeId: string): void {
    this.settingsStore.writeLastNode(nodeId);
    this.catalogController.catalogNodeId = nodeId;
    this.catalogController.catalog = new CatalogState(CatalogPhase.Loading, nodeId, [], null, '');
    this.loadCatalog(nodeId);
    this.startCatalogRefresh();
    this.pushPane('node');
  }

  backToList(): void {
    this.stopCatalogRefresh();
    this.settingsStore.writeLastNode('');
    this.popPane();
  }

  /** The way out of a sub-screen: one step back in the navigation stack. */
  goBack(): void {
    this.popPane();
  }

  openApp(nodeId: string, app: AppInfo): void {
    // One web screen at a time: a double tap that pushes twice would leave a
    // second screen under the first, and a back that needs two presses.
    if (this.openingApp) {
      return;
    }
    this.openingApp = true;
    this.selectedApp = app;
    this.pushPane('web');
  }

  /** The web screen has asked for the application and settled — the door is open again. */
  openAppSettled(): void {
    this.openingApp = false;
  }

  leaveWeb(): void {
    this.selectedApp = null;
    this.closeWeb();
    this.openAppSettled();
    this.popPane();
  }

  /** The system back key: a pushed screen pops one step; the list itself leaves the app. */
  onSystemBack(): boolean {
    if (this.paneStack.length === 0) {
      return false;
    }
    this.popPane();
    return true;
  }

  private pushPane(name: string): void {
    if (this.stack === null) {
      return;
    }
    this.stack.pushPathByName(name, null);
    this.paneStack.push(name);
    this.syncPane();
  }

  private popPane(): void {
    if (this.stack === null) {
      return;
    }
    this.stack.pop();
    this.paneStack.pop();
    this.syncPane();
  }

  private syncPane(): void {
    const top: string = this.paneStack.length > 0 ? this.paneStack[this.paneStack.length - 1] : '';
    this.paneFullscreen = top === 'web';
  }

  // ---- Timers & Toast ----------------------------------------------------------

  startNodesRefresh(): void {
    if (this.refreshTimer >= 0) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      this.refreshNodes();
    }, Cadence.nodeRefreshMs);
  }

  startCatalogRefresh(): void {
    this.catalogController.startCatalogRefresh(this.catalogNodeId);
  }

  stopCatalogRefresh(): void {
    this.catalogController.stopCatalogRefresh();
  }

  private stopTimers(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    this.catalogController.stopCatalogRefresh();
    this.pairingSession.stopApprovalPolling();
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  showToast(key: string): void {
    this.toastText = '';
    this.toast = key;
    this.armToastTimer();
  }

  /** A toast whose words are not a key's: a file's name, with the key's sentence around it. */
  showToastText(text: string): void {
    this.toast = '';
    this.toastText = text;
    this.armToastTimer();
  }

  /** The shortest toast there is: one word about a tap that has already happened. */
  showBriefToast(key: string): void {
    this.toastText = '';
    this.toast = key;
    this.armToastTimer(COPIED_MS);
  }

  private armToastTimer(duration: number = TOAST_MS): void {
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastText = '';
      this.toastTimer = -1;
    }, duration);
  }

  setVersions(versionName: string, buildNumber: number): void {
    this.versionName = versionName;
    this.buildNumber = buildNumber;
  }

  version(): string {
    return this.versionName;
  }

  build(): number {
    return this.buildNumber;
  }

  protocolVersion(): number {
    return PROTOCOL_VERSION;
  }

  abilityContext(): common.UIAbilityContext | null {
    return this.context;
  }

  isKnownApplicationHost(gatewayOrigin: string, host: string): boolean {
    return this.catalogController.isKnownApplicationHost(gatewayOrigin, host);
  }
}

export const model: AppModel = new AppModel();
