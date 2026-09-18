// The single view model facade: coordinates controllers and UI state.

import { common } from '@kit.AbilityKit';
import { AppInfo, AppState, Appearance, GatewayPath, Identity, Language, Node, NodeStatus, ServerPin } from '../core/model/Models';
import { ClientError, ErrorCode, parseErrorCode } from '../core/model/Errors';
import { decodeRelease, ReleaseManifest, RELEASE_URL, UpdateCheck, UpdateVerdict, verdictFor } from '../core/update/UpdateChecker';
import { IdentityVault } from '../core/identity/IdentityVault';
import { ProtocolClient } from '../core/api/ProtocolClient';
import { NetworkEnvironment } from '../core/pathselect/NetworkEnvironment';
import { PathSelector } from '../core/pathselect/PathSelector';
import { PairingMachine, PairingStage } from '../core/pairing/PairingMachine';
import { PairingTransaction, StagedPairing } from '../core/pairing/PairingTransaction';
import { IdentityStore } from '../core/store/IdentityStore';
import { NodeCacheStore } from '../core/store/NodeCacheStore';
import { Sandbox } from '../core/store/Sandbox';
import { Settings, SettingsStore } from '../core/store/SettingsStore';
import { Cadence } from '../core/model/Cadence';
import { MessageKeys } from '../core/model/MessageKeys';
import { Strings } from './i18n/Strings';
import { PROTOCOL_VERSION } from './BuildInfo';
import { CatalogPhase, CatalogState, NodeRow, PairingState, WebSession } from './State';
import { WindowLayout } from './WindowLayout';
import { NodesController } from './NodesController';
import { CatalogController } from './CatalogController';
import { PairingSession } from './PairingSession';

export { CatalogPhase, CatalogState, NodeRow, PairingState, WebSession } from './State';

const TOAST_MS = 2500;

@ObservedV2
export class AppModel {
  @Trace settings: Settings = Settings.defaults();
  @Trace dark: boolean = false;
  @Trace loaded: boolean = false;
  @Trace update: UpdateCheck | null = null;
  @Trace checkingUpdate: boolean = false;
  @Trace toast: string = '';
  @Trace wide: boolean = false;
  @Trace deviceName: string = '';
  @Trace selectedApp: AppInfo | null = null;
  @Trace pendingLink: string = '';

  @Trace nodesController: NodesController;
  @Trace catalogController: CatalogController;
  @Trace pairingSession: PairingSession;

  get identities(): Identity[] { return this.nodesController.identities; }
  get nodes(): NodeRow[] { return this.nodesController.nodes; }
  get needsPairing(): string[] { return this.nodesController.needsPairing; }
  get refreshing(): boolean { return this.nodesController.refreshing; }
  get probedOnce(): boolean { return this.nodesController.probedOnce; }
  get catalog(): CatalogState { return this.catalogController.catalog; }
  get catalogNodeId(): string { return this.catalogController.catalogNodeId; }
  get web(): WebSession | null { return this.catalogController.web; }
  get webFailed(): string { return this.catalogController.webFailed; }
  get pairing(): PairingState { return this.pairingSession.pairing; }
  get pairingBusy(): boolean { return this.pairingSession.pairingBusy; }

  private readonly vault: IdentityVault = new IdentityVault();
  private readonly identityStore: IdentityStore = new IdentityStore();
  private readonly cache: NodeCacheStore = new NodeCacheStore();
  private readonly settingsStore: SettingsStore = new SettingsStore();
  private readonly client: ProtocolClient;
  private readonly transaction: PairingTransaction;
  private readonly pairingMachine: PairingMachine;
  private readonly selector: PathSelector = new PathSelector();
  private readonly environment: NetworkEnvironment = new NetworkEnvironment();

  readonly nodesController: NodesController;
  readonly catalogController: CatalogController;
  readonly pairingSession: PairingSession;

  private context: common.UIAbilityContext | null = null;
  private foreground: boolean = false;
  private started: boolean = false;
  private refreshTimer: number = -1;
  private toastTimer: number = -1;
  private stack: NavPathStack | null = null;
  private buildNumber: number = 0;
  private versionName: string = '';
  private systemDark: boolean = false;

  constructor() {
    this.client = new ProtocolClient(this.vault);
    this.transaction = new PairingTransaction(this.vault);
    this.pairingMachine = new PairingMachine(this.client, this.vault, this.transaction, this.identityStore);

    const nodesCtrl = new NodesController(
      this.vault,
      this.identityStore,
      this.cache,
      this.client,
      this.selector,
      this.environment,
      this.transaction
    );
    this.nodesController = nodesCtrl;

    const catalogCtrl = new CatalogController(this.client, this.vault, nodesCtrl);
    this.catalogController = catalogCtrl;

    const pairingSess = new PairingSession(this.pairingMachine, this.transaction, nodesCtrl);
    this.pairingSession = pairingSess;

    catalogCtrl.onToast = (key: string): void => {
      this.showToast(key);
    };

    pairingSess.onFinished = (): void => {
      if (this.stack !== null) {
        this.stack.pop();
      }
    };
  }

  // ---- Lifecycle ---------------------------------------------------------------

  async boot(context: common.UIAbilityContext): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    this.context = context;
    Sandbox.init(context.filesDir);
    this.settings = this.settingsStore.open(context);
    Strings.attach(context.resourceManager, this.settings.language);
    Strings.apply(context, this.settings.language);
    this.systemDark = WindowLayout.readSystemDark(context);
    this.dark = WindowLayout.effectiveDark(this.settings.appearance, this.systemDark);
    this.environment.start();
    this.nodesController.reloadIdentities();
    const staged: StagedPairing | null = await this.transaction.reconcile();
    if (staged !== null) {
      this.pairingSession.beginApprovalPolling();
    }
    this.catalog = CatalogState.idle();
    this.loaded = true;
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
  }

  listenWindowSize(context: Context | undefined): void {
    WindowLayout.listenWindowSize(context, (wide: boolean) => {
      this.wide = wide;
    });
  }

  // ---- Nodes -------------------------------------------------------------------

  async refreshNodes(): Promise<void> {
    await this.nodesController.refreshNodes();
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

  // ---- Catalog & Apps ----------------------------------------------------------

  async loadCatalog(nodeId: string): Promise<void> {
    await this.catalogController.loadCatalog(nodeId);
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
      this.stack.pushPathByName('add', null);
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
    await this.nodesController.forget(origin);
    this.catalogController.forgetApplicationHosts(origin);
    if (this.catalogNodeId !== '') {
      this.catalog = new CatalogState(CatalogPhase.Loading, this.catalogNodeId, [], null, '');
    }
    await this.refreshNodes();
  }

  async removeIdentity(origin: string): Promise<void> {
    await this.forget(origin);
  }

  // ---- Navigation --------------------------------------------------------------

  attachStack(stack: NavPathStack): void {
    this.stack = stack;
  }

  pushAddNode(): void {
    if (this.stack !== null) {
      this.stack.pushPathByName('add', null);
    }
  }

  pushSettings(): void {
    if (this.stack !== null) {
      this.stack.pushPathByName('settings', null);
    }
  }

  selectNode(nodeId: string): void {
    this.catalogNodeId = nodeId;
    this.catalog = new CatalogState(CatalogPhase.Loading, nodeId, [], null, '');
    this.catalogController.catalogNodeId = nodeId;
    this.loadCatalog(nodeId);
    this.startCatalogRefresh();
    if (this.stack !== null) {
      this.stack.pushPathByName('node', null);
    }
  }

  backToList(): void {
    this.stopCatalogRefresh();
    if (this.stack !== null) {
      this.stack.pop();
    }
  }

  openApp(nodeId: string, app: AppInfo): void {
    if (app.code === AppState.Stopped) {
      this.catalogController.startForOpen(nodeId, app);
    }
    this.selectedApp = app;
    if (this.stack !== null) {
      this.stack.pushPathByName('web', null);
    }
  }

  leaveWeb(): void {
    this.selectedApp = null;
    this.closeWeb();
    if (this.stack !== null) {
      this.stack.pop();
    }
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
    this.toast = key;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastTimer = -1;
    }, TOAST_MS);
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
