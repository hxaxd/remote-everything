// The single view model: every state change in this app goes through here.
//
// architecture.md §4 asks for one dispatcher and one source of truth, and this is it.
// The list of nodes is always the last merge of what the gateways answered; a catalog
// is always the last answer for one node; the pairing flow is a state machine this
// file drives and the screens only render. Nothing above this file sends a request,
// and nothing below it knows what a screen is.
//
// Request timing is `Cadence` — the table all three clients share, pinned by
// clients/behavior/fixtures/cadence.json — and nothing else, and every poller is
// stopped when the app leaves the foreground.

import { common } from '@kit.AbilityKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { display, window } from '@kit.ArkUI';
import { AppInfo, AppState, Appearance, GatewayPath, Identity, Language, Node, NodeStatus, ServerPin } from '../core/model/Models';
import { ClientError, ErrorCode, parseErrorCode } from '../core/api/Errors';
import { CatalogAnswer, ControlAnswer, ControlCode } from '../core/api/Dto';
import { credentialFailure, hostOf, ProtocolClient } from '../core/api/ProtocolClient';
import { decodeRelease, ReleaseManifest, RELEASE_URL, UpdateCheck, UpdateVerdict, verdictFor } from '../core/api/ReleaseChannel';
import { CredentialError } from '../core/identity/CredentialError';
import { CredentialMaterial, IdentityVault } from '../core/identity/IdentityVault';
import { NetworkEnvironment } from '../core/pathselect/NetworkEnvironment';
import { OriginProbe, PathSelector } from '../core/pathselect/PathSelector';
import { PairingMachine, PairingOutcome, PairingStage } from '../core/pairing/PairingMachine';
import { PairingTransaction, StagedPairing } from '../core/pairing/PairingTransaction';
import { IdentityStore } from '../core/store/IdentityStore';
import { NodeCacheStore } from '../core/store/NodeCacheStore';
import { Sandbox } from '../core/store/Sandbox';
import { Settings, SettingsStore } from '../core/store/SettingsStore';
import { SetupUri } from '../core/setup/SetupUri';
import { Cadence } from '../core/model/Cadence';
import { MessageKeys } from '../core/model/MessageKeys';
import { Strings } from './i18n/Strings';
import { PROTOCOL_VERSION } from './BuildInfo';

/** How long a toast stays up. A sentence on screen, not a cadence: it is not shared. */
const TOAST_MS = 2500;

/** The short side at which two columns fit (ui-contract §6). */
const WIDE_SHORT_SIDE_VP = 840;

export enum CatalogPhase {
  Loading = 'loading',
  Ready = 'ready',
  Offline = 'offline',
  Unauthorized = 'unauthorized',
  Failed = 'failed'
}

/** One row of S1: a node, the state of its paths, and where it can be reached. */
export class NodeRow {
  readonly node: Node;
  readonly status: NodeStatus;

  constructor(node: Node, status: NodeStatus) {
    this.node = node;
    this.status = status;
  }

  get isPending(): boolean {
    return this.status === NodeStatus.PendingApproval;
  }

  get isOnline(): boolean {
    return this.status === NodeStatus.OnlineLan || this.status === NodeStatus.OnlineTunnel;
  }

  /** The path a request for this node takes: routing leaves the chosen one first. */
  get chosen(): GatewayPath | null {
    return this.node.paths.length > 0 ? this.node.paths[0] : null;
  }
}

/** S3's whole-page state. `offline` is an answer here, not an error. */
export class CatalogState {
  readonly phase: CatalogPhase;
  readonly nodeId: string;
  readonly apps: AppInfo[];
  readonly errorCode: ErrorCode | null;
  readonly busyAppId: string;

  constructor(phase: CatalogPhase, nodeId: string, apps: AppInfo[], errorCode: ErrorCode | null, busyAppId: string) {
    this.phase = phase;
    this.nodeId = nodeId;
    this.apps = apps;
    this.errorCode = errorCode;
    this.busyAppId = busyAppId;
  }

  static idle(): CatalogState {
    return new CatalogState(CatalogPhase.Loading, '', [], null, '');
  }

  withApps(apps: AppInfo[]): CatalogState {
    return new CatalogState(CatalogPhase.Ready, this.nodeId, apps, null, '');
  }

  withBusy(appId: string): CatalogState {
    return new CatalogState(this.phase, this.nodeId, this.apps, this.errorCode, appId);
  }

  withApp(updated: AppInfo): CatalogState {
    const next: AppInfo[] = this.apps.map((app: AppInfo) => app.id === updated.id ? updated : app);
    return new CatalogState(this.phase, this.nodeId, next, this.errorCode, '');
  }

  app(appId: string): AppInfo | null {
    for (const app of this.apps) {
      if (app.id === appId) {
        return app;
      }
    }
    return null;
  }
}

/** S2's screen state, mirroring the stage machine of ui-contract §2/S2. */
export class PairingState {
  readonly stage: PairingStage;
  readonly setup: SetupUri | null;
  readonly deviceName: string;
  readonly errorKey: string | null;

  constructor(stage: PairingStage, setup: SetupUri | null, deviceName: string, errorKey: string | null) {
    this.stage = stage;
    this.setup = setup;
    this.deviceName = deviceName;
    this.errorKey = errorKey;
  }

  static idle(): PairingState {
    return new PairingState(PairingStage.Input, null, '', null);
  }

  withStage(stage: PairingStage, errorKey: string | null): PairingState {
    return new PairingState(stage, this.setup, this.deviceName, errorKey);
  }
}

/** What S4 loads: the application's own origin, and the identity that signs for it. */
export class WebSession {
  readonly gatewayOrigin: string;
  readonly nodeId: string;
  readonly appId: string;
  readonly appName: string;
  readonly launchFragment: string;
  readonly serverPin: ServerPin | null;
  readonly isPrivate: boolean;
  readonly keyUri: string;
  readonly url: string;

  constructor(gatewayOrigin: string, nodeId: string, appId: string, appName: string, launchFragment: string,
    serverPin: ServerPin | null, isPrivate: boolean, keyUri: string, url: string) {
    this.gatewayOrigin = gatewayOrigin;
    this.nodeId = nodeId;
    this.appId = appId;
    this.appName = appName;
    this.launchFragment = launchFragment;
    this.serverPin = serverPin;
    this.isPrivate = isPrivate;
    this.keyUri = keyUri;
    this.url = url;
  }
}

@ObservedV2
export class AppModel {
  @Trace identities: Identity[] = [];
  @Trace nodes: NodeRow[] = [];
  @Trace settings: Settings = Settings.defaults();
  @Trace dark: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace loaded: boolean = false;
  @Trace probedOnce: boolean = false;
  @Trace catalog: CatalogState = CatalogState.idle();
  @Trace catalogNodeId: string = '';
  @Trace pairing: PairingState = PairingState.idle();
  @Trace pairingBusy: boolean = false;
  @Trace needsPairing: string[] = [];
  @Trace update: UpdateCheck | null = null;
  @Trace checkingUpdate: boolean = false;
  @Trace toast: string = '';
  @Trace web: WebSession | null = null;
  @Trace webFailed: string = '';
  @Trace wide: boolean = false;
  @Trace deviceName: string = '';
  @Trace selectedApp: AppInfo | null = null;

  private readonly vault: IdentityVault = new IdentityVault();
  private readonly identityStore: IdentityStore = new IdentityStore();
  private readonly cache: NodeCacheStore = new NodeCacheStore();
  private readonly settingsStore: SettingsStore = new SettingsStore();
  private readonly transaction: PairingTransaction;
  private readonly pairingMachine: PairingMachine;
  private readonly selector: PathSelector;
  private readonly client: ProtocolClient;
  private readonly environment: NetworkEnvironment = new NetworkEnvironment();
  private context: common.UIAbilityContext | null = null;
  private foreground: boolean = false;
  private started: boolean = false;
  private refreshTimer: number = -1;
  private catalogTimer: number = -1;
  private approvalTimer: number = -1;
  private statusTimer: number = -1;
  private toastTimer: number = -1;
  private approvalStartedAt: number = 0;

  constructor() {
    this.client = new ProtocolClient(this.vault);
    this.transaction = new PairingTransaction(this.vault);
    this.pairingMachine = new PairingMachine(this.client, this.vault, this.transaction, this.identityStore);
    this.selector = new PathSelector(this.client);
  }

  // ---- Lifecycle ---------------------------------------------------------------

  /** Called once, from the ability, with everything the core needs to exist. */
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
    this.systemDark = this.readSystemDark(context);
    this.dark = this.effectiveDark();
    this.environment.start();
    this.reloadIdentities();
    const staged: StagedPairing | null = await this.transaction.reconcile();
    if (staged !== null) {
      this.beginApprovalPolling();
    }
    this.catalog = CatalogState.idle();
    this.loaded = true;
    await this.refreshNodes();
  }

  /** The ability's lifecycle: polls run only while the app is in front. */
  foregroundChanged(active: boolean): void {
    if (active === this.foreground) {
      return;
    }
    this.foreground = active;
    if (active) {
      this.environment.start();
      this.refreshNodes();
      this.startNodesRefresh();
      this.retryStaged();
    } else {
      this.stopTimers();
      // A session holds the key material RCP was handed for as long as it lives;
      // leaving the foreground is the moment to let go of it.
      this.client.releaseAll();
    }
  }

  private readSystemDark(context: common.UIAbilityContext): boolean {
    try {
      return context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (error) {
      return false;
    }
  }

  private systemDark: boolean = false;

  /** Re-reads the system's mode; called when the configuration changes. */
  refreshSystemDark(): void {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return;
    }
    this.systemDark = this.readSystemDark(context);
    this.dark = this.effectiveDark();
  }

  private effectiveDark(): boolean {
    if (this.settings.appearance === Appearance.Dark) {
      return true;
    }
    if (this.settings.appearance === Appearance.Light) {
      return false;
    }
    return this.systemDark;
  }

  private applyColorMode(): void {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return;
    }
    try {
      const mode: ConfigurationConstant.ColorMode = this.settings.appearance === Appearance.Dark
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : this.settings.appearance === Appearance.Light
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      context.getApplicationContext().setColorMode(mode);
    } catch (error) {
      // The palette still follows whatever the system is doing.
    }
    this.dark = this.effectiveDark();
  }

  // ---- Settings ----------------------------------------------------------------

  setLanguage(language: Language): void {
    this.settings = this.settings.withLanguage(language);
    this.settingsStore.write(this.settings);
    const context: common.UIAbilityContext | null = this.context;
    if (context !== null) {
      Strings.apply(context, language);
    }
  }

  setAppearance(appearance: Appearance): void {
    this.settings = this.settings.withAppearance(appearance);
    this.settingsStore.write(this.settings);
    this.applyColorMode();
  }

  setWide(wide: boolean): void {
    this.wide = wide;
  }

  /**
   * Watches the window: a short side of 840 vp or more is a screen with room for two
   * columns, and a foldable unfolding is a size change rather than a new screen
   * (ui-contract §6).
   */
  listenWindowSize(context: Context | undefined): void {
    if (context === undefined) {
      return;
    }
    const measure = (size: window.Size): void => {
      try {
        // Window rectangles are in pixels; the layout is in vp, and the display
        // knows how many pixels one vp is.
        const density: number = display.getDefaultDisplaySync().densityPixels;
        if (density <= 0) {
          return;
        }
        const shortSide: number = Math.min(size.width, size.height) / density;
        this.setWide(shortSide >= WIDE_SHORT_SIDE_VP);
      } catch (error) {
        // A size that cannot be converted leaves the layout as it is.
      }
    };
    let pending: Promise<window.Window>;
    try {
      pending = window.getLastWindow(context);
    } catch (error) {
      return;
    }
    pending.then((host: window.Window) => {
      try {
        host.on('windowSizeChange', measure);
      } catch (error) {
        // Not being told about resizes leaves the layout as it is; the initial
        // measurement below still decides once.
      }
      try {
        const rect: window.Rect = host.getWindowProperties().windowRect;
        measure({ width: rect.width, height: rect.height });
      } catch (error) {
        // A window that cannot be measured keeps the single-column layout.
      }
    }).catch(() => {
      // No window to watch, no wide layout.
    });
  }

  setDeviceName(name: string): void {
    this.deviceName = name;
  }

  // ---- Nodes -------------------------------------------------------------------

  private reloadIdentities(): void {
    this.identities = this.identityStore.read();
  }

  /**
   * The whole list, rebuilt from what every gateway answers. A gateway that does not
   * answer does not empty the screen: its nodes stay, marked as not probed.
   */
  async refreshNodes(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.selector.setEnvironment(this.environment.key());
    try {
      const known: Identity[] = this.identitiesSnapshot();
      // Probing is a request like any other, so every gateway this device holds a
      // credential for gets its session first. One that cannot be opened is not
      // probed: its nodes stay in the list, marked as not reached.
      for (const identity of known) {
        try {
          await this.client.connect(identity.origin, identity.serverPin);
        } catch (error) {
          this.client.release(identity.origin);
        }
      }
      const previous: Node[] = this.nodes.map((row: NodeRow) => row.node);
      if (previous.length === 0) {
        for (const identity of known) {
          const cached = this.cache.read(identity.origin);
          if (cached !== null) {
            previous.push(...cached.nodes);
          }
        }
      }
      const probes: OriginProbe[] = await this.selector.probe(known.map((identity: Identity) => identity.origin));
      const merged: Node[] = this.selector.merge(probes, known, previous);
      this.selector.remember(merged);
      this.nodes = merged.map((node: Node) => new NodeRow(node, this.statusOf(node)));
      for (const probe of probes) {
        if (!probe.reachable) {
          continue;
        }
        const mine: Node[] = merged.filter((node: Node) => node.paths.some((path: GatewayPath) =>
          path.origin === probe.origin && path.reachable === true));
        this.cache.write(probe.origin, mine, Date.now());
      }
      // A gateway that answered 401 to a probe is one this device is no longer
      // admitted to: the identity is not deleted (a gateway having a bad minute must
      // not cost a pairing — pitfalls §3.3), but the credential's state is re-read.
      if (probes.some((probe: OriginProbe) => !probe.reachable)) {
        await this.checkCredentials();
      }
      this.probedOnce = true;
    } finally {
      this.refreshing = false;
    }
  }

  /** Whether each gateway's credential can still be read; S5 and S1 both say so. */
  private async checkCredentials(): Promise<void> {
    const missing: string[] = [];
    for (const identity of this.identitiesSnapshot()) {
      try {
        const material: CredentialMaterial = await this.vault.material(identity.origin);
        material.wipe();
      } catch (error) {
        missing.push(identity.origin);
      }
    }
    this.needsPairing = missing;
  }

  private identitiesSnapshot(): Identity[] {
    return this.identityStore.read();
  }

  /** The node row state machine of ui-contract §2/S1. */
  private statusOf(node: Node): NodeStatus {
    const staged: StagedPairing | null = this.transaction.read();
    if (staged !== null && staged.node === node.id) {
      return NodeStatus.PendingApproval;
    }
    const reachable: GatewayPath[] = node.paths.filter((path: GatewayPath) => path.reachable === true);
    if (reachable.length > 0) {
      const chosen: GatewayPath = node.paths[0];
      return chosen.isPrivate ? NodeStatus.OnlineLan : NodeStatus.OnlineTunnel;
    }
    // `unknown` is the initial transient and nothing else: once a round of probing has
    // finished, a node no path answers for is offline (ui-contract §2/S1).
    return this.probedOnce ? NodeStatus.Offline : NodeStatus.Unknown;
  }

  nodeRow(nodeId: string): NodeRow | null {
    for (const row of this.nodes) {
      if (row.node.id === nodeId) {
        return row;
      }
    }
    return null;
  }

  nodesForOrigin(origin: string): number {
    let count: number = 0;
    for (const row of this.nodes) {
      if (row.node.paths.some((path: GatewayPath) => path.origin === origin)) {
        count += 1;
      }
    }
    return count;
  }

  // ---- One node's applications -------------------------------------------------

  async loadCatalog(nodeId: string): Promise<void> {
    const row: NodeRow | null = this.nodeRow(nodeId);
    this.catalogNodeId = nodeId;
    if (row === null) {
      this.catalog = new CatalogState(CatalogPhase.Unauthorized, nodeId, [], ErrorCode.Unauthorized, '');
      return;
    }
    const path: GatewayPath | null = row.chosen;
    if (path === null) {
      this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], ErrorCode.ComputerOffline, '');
      return;
    }
    if (this.catalog.nodeId !== nodeId) {
      this.catalog = new CatalogState(CatalogPhase.Loading, nodeId, [], null, '');
    }
    const identity: Identity | null = this.identityFor(path.origin);
    try {
      await this.client.connect(path.origin, identity === null ? null : identity.serverPin);
      const answer: CatalogAnswer = await this.client.apps(path.origin, nodeId);
      if (answer.computerConnected) {
        this.catalog = new CatalogState(CatalogPhase.Ready, nodeId, answer.apps, null, '');
      } else {
        this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], ErrorCode.ComputerOffline, '');
      }
    } catch (error) {
      this.catalog = this.catalogFailure(nodeId, error);
    }
  }

  private catalogFailure(nodeId: string, error: Object): CatalogState {
    if (error instanceof ClientError) {
      if (error.code === ErrorCode.Unauthorized || error.code === ErrorCode.NodeNotFound ||
        error.code === ErrorCode.NodeRequired) {
        return new CatalogState(CatalogPhase.Unauthorized, nodeId, [], error.code, '');
      }
      if (error.code === ErrorCode.Network) {
        return new CatalogState(CatalogPhase.Offline, nodeId, [], error.code, '');
      }
      return new CatalogState(CatalogPhase.Failed, nodeId, [], error.code, '');
    }
    if (error instanceof CredentialError) {
      return new CatalogState(CatalogPhase.Unauthorized, nodeId, [], ErrorCode.Unauthorized, '');
    }
    return new CatalogState(CatalogPhase.Offline, nodeId, [], ErrorCode.Network, '');
  }

  /** Start or stop, then poll until the node settles (ui-contract §5). */
  async toggleApp(nodeId: string, app: AppInfo): Promise<void> {
    const path: GatewayPath | null = this.chosenPath(nodeId);
    if (path === null) {
      this.showToast(MessageKeys.forError(ErrorCode.ComputerOffline));
      return;
    }
    this.catalog = this.catalog.withBusy(app.id);
    try {
      const answer: ControlAnswer = app.enabled
        ? await this.client.stop(path.origin, nodeId, app.id)
        : await this.client.start(path.origin, nodeId, app.id);
      if (!answer.ok && answer.code === ControlCode.ComputerOffline) {
        this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], ErrorCode.ComputerOffline, '');
        return;
      }
      if (!answer.ok) {
        this.catalog = this.catalog.withBusy('');
        this.showToast(this.controlErrorKey(answer));
        return;
      }
      const updated: AppInfo = answer.app !== null ? answer.app
        : new AppInfo(app.id, app.name, app.description, app.icon, app.accent, app.launchFragment,
          answer.enabled, answer.running, answer.state);
      this.catalog = this.catalog.withApp(updated);
      if (answer.code === ControlCode.Starting || answer.code === ControlCode.Stopping) {
        this.pollStatus(path.origin, nodeId, app.id);
      }
    } catch (error) {
      this.catalog = this.catalog.withBusy('');
      this.showToast(this.errorKey(error));
    }
  }

  private controlErrorKey(answer: ControlAnswer): string {
    if (answer.errorCode !== null) {
      const code: ErrorCode | null = parseErrorCode(answer.errorCode);
      if (code !== null) {
        return MessageKeys.forError(code);
      }
    }
    if (answer.code === ControlCode.ComputerOffline) {
      return MessageKeys.forError(ErrorCode.ComputerOffline);
    }
    if (answer.code === ControlCode.AppNotFound) {
      return MessageKeys.forError(ErrorCode.AppNotFound);
    }
    return MessageKeys.forError(ErrorCode.StateUpdateFailed);
  }

  /**
   * [Cadence.controlPollMs] at first, times [Cadence.controlPollFactor] each round and
   * never more than [Cadence.controlPollCeilingMs], given up on after
   * [Cadence.controlPollTimeoutMs].
   */
  private pollStatus(origin: string, nodeId: string, appId: string): void {
    const startedAt: number = Date.now();
    let delay: number = Cadence.controlPollMs;
    const step = async (): Promise<void> => {
      if (!this.foreground || this.catalogNodeId !== nodeId) {
        return;
      }
      if (Date.now() - startedAt > Cadence.controlPollTimeoutMs) {
        this.catalog = this.catalog.withBusy('');
        return;
      }
      try {
        const answer: ControlAnswer = await this.client.status(origin, nodeId, appId);
        if (answer.app !== null) {
          this.catalog = this.catalog.withApp(answer.app);
        }
        if (answer.settled) {
          this.catalog = this.catalog.withBusy('');
          return;
        }
      } catch (error) {
        this.catalog = this.catalog.withBusy('');
        this.showToast(this.errorKey(error));
        return;
      }
      delay = Math.min(Math.round(delay * Cadence.controlPollFactor), Cadence.controlPollCeilingMs);
      this.statusTimer = setTimeout(step, delay);
    };
    this.statusTimer = setTimeout(step, delay);
  }

  /** Tapping a stopped row starts it; the page opens either way. */
  async startForOpen(nodeId: string, app: AppInfo): Promise<void> {
    const path: GatewayPath | null = this.chosenPath(nodeId);
    if (path === null || app.code === AppState.Ready) {
      return;
    }
    try {
      await this.client.start(path.origin, nodeId, app.id);
    } catch (error) {
      // The page itself will say what happened.
    }
  }

  chosenPath(nodeId: string): GatewayPath | null {
    const row: NodeRow | null = this.nodeRow(nodeId);
    return row === null ? null : row.chosen;
  }

  // ---- Opening an application --------------------------------------------------

  /**
   * Asks the gateway where one application is and makes sure the certificate manager
   * holds the identity that will sign for it — both before the WebView is shown,
   * because a challenge answered late is a challenge that times out (pitfalls §1.3).
   */
  async beginWeb(nodeId: string, app: AppInfo): Promise<void> {
    const row: NodeRow | null = this.nodeRow(nodeId);
    const path: GatewayPath | null = row === null ? null : row.chosen;
    this.web = null;
    this.webFailed = '';
    if (path === null) {
      this.webFailed = MessageKeys.forError(row === null ? ErrorCode.NodeNotFound : ErrorCode.ComputerOffline);
      return;
    }
    const identity: Identity | null = this.identityFor(path.origin);
    const pin: ServerPin | null = identity === null ? null : identity.serverPin;
    try {
      await this.client.connect(path.origin, pin);
      const keyUri: string = await this.vault.webIdentity(path.origin);
      const target: string = await this.client.open(path.origin, nodeId, app.id);
      this.rememberApplicationHost(path.origin, hostOf(target));
      this.web = new WebSession(path.origin, nodeId, app.id, app.name, app.launchFragment, pin, path.isPrivate,
        keyUri, `${target}${app.launchFragment}`);
    } catch (error) {
      this.webFailed = this.errorKey(error);
    }
  }

  closeWeb(): void {
    this.web = null;
    this.webFailed = '';
  }

  // ---- Pairing -----------------------------------------------------------------

  beginPairing(): void {
    this.pairing = new PairingState(PairingStage.Input, null, this.deviceName, null);
  }

  /** A scanned or pasted link: parsed here, shown back before anything is sent. */
  submitLink(raw: string): void {
    const outcome: PairingOutcome = this.pairingMachine.parseLink(raw);
    if (outcome.stage === PairingStage.Confirm && outcome.setup !== null) {
      this.pairing = new PairingState(PairingStage.Confirm, outcome.setup, this.pairing.deviceName, null);
      return;
    }
    this.pairing = new PairingState(PairingStage.Input, null, this.pairing.deviceName, outcome.errorKey);
  }

  editDeviceNameForPairing(name: string): void {
    this.pairing = new PairingState(this.pairing.stage, this.pairing.setup, name, this.pairing.errorKey);
  }

  editLink(): void {
    this.pairing = new PairingState(PairingStage.Input, null, this.pairing.deviceName, null);
  }

  /** Confirms and redeems: the password is generated inside the machine, never here. */
  async confirmPairing(): Promise<void> {
    const setup: SetupUri | null = this.pairing.setup;
    if (setup === null || this.pairingBusy) {
      return;
    }
    this.pairingBusy = true;
    try {
      const outcome: PairingOutcome = await this.pairingMachine.pair(setup, this.pairing.deviceName);
      await this.applyPairingOutcome(outcome);
    } finally {
      this.pairingBusy = false;
    }
  }

  private async applyPairingOutcome(outcome: PairingOutcome): Promise<void> {
    this.reloadIdentities();
    if (outcome.stage === PairingStage.Done) {
      this.pairing = PairingState.idle();
      await this.refreshNodes();
      return;
    }
    if (outcome.stage === PairingStage.WaitingApproval) {
      this.pairing = new PairingState(PairingStage.WaitingApproval, null, this.pairing.deviceName, outcome.errorKey);
      this.beginApprovalPolling();
      await this.refreshNodes();
      return;
    }
    this.pairing = new PairingState(PairingStage.Failed, null, this.pairing.deviceName, outcome.errorKey);
  }

  /**
   * Waiting for an operator: asked again every [Cadence.approvalPollMs], and not after
   * [Cadence.approvalPollTimeoutMs].
   */
  private beginApprovalPolling(): void {
    this.stopApprovalPolling();
    this.approvalStartedAt = Date.now();
    const step = async (): Promise<void> => {
      if (!this.foreground) {
        return;
      }
      if (Date.now() - this.approvalStartedAt > Cadence.approvalPollTimeoutMs) {
        // The row keeps saying it is waiting, which is still true.
        return;
      }
      const staged: StagedPairing | null = this.transaction.read();
      if (staged === null) {
        return;
      }
      const identity: Identity | null = this.identityFor(staged.origin);
      const outcome: PairingOutcome = await this.pairingMachine.resume(staged,
        identity === null ? null : identity.serverPin);
      if (outcome.stage === PairingStage.Done) {
        this.reloadIdentities();
        this.pairing = PairingState.idle();
        await this.refreshNodes();
        return;
      }
      if (outcome.stage === PairingStage.WaitingApproval) {
        this.approvalTimer = setTimeout(step, Cadence.approvalPollMs);
      }
    };
    this.approvalTimer = setTimeout(step, Cadence.approvalPollMs);
  }

  private stopApprovalPolling(): void {
    if (this.approvalTimer >= 0) {
      clearTimeout(this.approvalTimer);
      this.approvalTimer = -1;
    }
  }

  /** A staged pairing that survived a restart is carried on when the app comes back. */
  private async retryStaged(): Promise<void> {
    const staged: StagedPairing | null = this.transaction.read();
    if (staged === null) {
      return;
    }
    const identity: Identity | null = this.identityFor(staged.origin);
    const outcome: PairingOutcome = await this.pairingMachine.resume(staged, identity === null ? null : identity.serverPin);
    if (outcome.stage === PairingStage.Done) {
      this.reloadIdentities();
      await this.refreshNodes();
    } else if (outcome.stage === PairingStage.WaitingApproval) {
      this.beginApprovalPolling();
    }
    this.refreshNodes();
  }

  // ---- Where a certificate may be presented -------------------------------------
  //
  // The WebView must be able to present this device's certificate, and it must present
  // it nowhere else. One gateway is reached at more than one host: its own, and the
  // origin of each application it serves (an application's own origin is what makes
  // its storage private to it). Every one of those is remembered as it is learned —
  // each is a `Location` an authenticated answer carried — so the decision never has to
  // guess what a gateway's domain looks like.

  private readonly applicationHosts: Map<string, string[]> = new Map<string, string[]>();

  rememberApplicationHost(gatewayOrigin: string, host: string): void {
    if (host === '') {
      return;
    }
    const known: string[] = this.applicationHosts.get(gatewayOrigin) ?? [];
    if (!known.includes(host)) {
      known.push(host);
      this.applicationHosts.set(gatewayOrigin, known);
    }
  }

  isKnownApplicationHost(gatewayOrigin: string, host: string): boolean {
    const known: string[] = this.applicationHosts.get(gatewayOrigin) ?? [];
    return known.includes(host);
  }

  /** A gateway's hosts are forgotten with it: nothing about it is kept. */
  private forgetApplicationHosts(gatewayOrigin: string): void {
    this.applicationHosts.delete(gatewayOrigin);
  }

  // ---- Forgetting a gateway ----------------------------------------------------

  /**
   * Forgetting is thorough: the certificate manager's entry, the sealing key, the
   * sealed archive, the cached list, the session, and the web data stored under that
   * gateway's origins. Anything left behind is a bug (architecture.md §3.4).
   */
  async forget(origin: string): Promise<void> {
    await this.vault.forget(origin);
    this.forgetApplicationHosts(origin);
    this.cache.remove(origin);
    this.client.release(origin);
    this.nodes = this.nodes.filter((row: NodeRow) =>
      !row.node.paths.some((path: GatewayPath) => path.origin === origin));
    const remaining: Identity[] = this.identitiesSnapshot().filter((identity: Identity) =>
      identity.origin !== origin);
    this.identityStore.write(remaining);
    this.reloadIdentities();
    this.needsPairing = this.needsPairing.filter((entry: string) => entry !== origin);
    if (this.catalogNodeId !== '') {
      this.catalog = new CatalogState(CatalogPhase.Loading, this.catalogNodeId, [], null, '');
    }
    await this.refreshNodes();
  }

  // ---- Updates -----------------------------------------------------------------

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

  /** What this build is, read from the bundle at startup rather than written twice. */
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

  private buildNumber: number = 0;
  private versionName: string = '';

  /** An invitation link that arrived from outside, waiting for a screen to show it. */
  @Trace pendingLink: string = '';

  /**
   * A link opened this app. If the navigation shell is up it goes straight to the
   * confirmation step; if the app was just started by the link, the link waits for the
   * first screen to appear.
   */
  openFromLink(uri: string): void {
    this.beginPairing();
    this.submitLink(uri);
    if (this.pendingLink === '' && this.stack !== null) {
      this.stack.pushPathByName('add', null);
      return;
    }
    this.pendingLink = uri;
  }

  /** The link the first screen still has to show, if a launch brought one. */
  consumePendingLink(): string {
    const link: string = this.pendingLink;
    this.pendingLink = '';
    return link;
  }

  // ---- Navigation --------------------------------------------------------------
  //
  // The screens own nothing: they read this model and ask it for what should happen
  // next. The one piece of the screen stack the model needs is the stack itself, so a
  // finished pairing or a revoked node can put the user back where the answer makes
  // sense without a screen deciding it.

  private stack: NavPathStack | null = null;

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

  /** Opening a node also starts its catalog refresh; leaving stops it. */
  selectNode(nodeId: string): void {
    this.catalogNodeId = nodeId;
    this.catalog = new CatalogState(CatalogPhase.Loading, nodeId, [], null, '');
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

  /** Tapping an application: a stopped one is started on the way (ui-contract §2/S3). */
  openApp(nodeId: string, app: AppInfo): void {
    if (app.code === AppState.Stopped) {
      this.startForOpen(nodeId, app);
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

  /** The path the node whose page is open is reached by, if it is reached at all. */
  nodePath(): GatewayPath | null {
    const row: NodeRow | null = this.nodeRow(this.catalogNodeId);
    if (row === null || !row.isOnline) {
      return null;
    }
    return row.chosen;
  }

  /** The name the node's own page is titled with; the gateway decides it, not us. */
  nodeTitle(): string {
    const row: NodeRow | null = this.nodeRow(this.catalogNodeId);
    if (row === null) {
      return '';
    }
    return row.node.name;
  }

  protocolVersion(): number {
    return PROTOCOL_VERSION;
  }

  abilityContext(): common.UIAbilityContext | null {
    return this.context;
  }

  async removeIdentity(origin: string): Promise<void> {
    await this.forget(origin);
  }

  // ---- Timers ------------------------------------------------------------------

  startNodesRefresh(): void {
    if (this.refreshTimer >= 0) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      this.refreshNodes();
    }, Cadence.nodeRefreshMs);
  }

  startCatalogRefresh(): void {
    if (this.catalogTimer >= 0) {
      return;
    }
    this.catalogTimer = setInterval(() => {
      if (this.catalogNodeId !== '') {
        this.loadCatalog(this.catalogNodeId);
      }
    }, Cadence.catalogRefreshMs);
  }

  stopCatalogRefresh(): void {
    if (this.catalogTimer >= 0) {
      clearInterval(this.catalogTimer);
      this.catalogTimer = -1;
    }
  }

  private stopTimers(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    this.stopCatalogRefresh();
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
    this.stopApprovalPolling();
  }

  showToast(key: string): void {
    this.toast = key;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
    }, TOAST_MS);
  }

  // ---- Small helpers -----------------------------------------------------------

  identityFor(origin: string): Identity | null {
    for (const identity of this.identities) {
      if (identity.origin === origin) {
        return identity;
      }
    }
    return null;
  }

  private errorKey(error: Object): string {
    if (error instanceof ClientError) {
      return MessageKeys.forError(error.code);
    }
    if (error instanceof CredentialError) {
      return MessageKeys.forError(credentialFailure(error).code);
    }
    return MessageKeys.forError(ErrorCode.Network);
  }
}

/** One instance for the app; the screens read it rather than owning state. */
export const model: AppModel = new AppModel();
