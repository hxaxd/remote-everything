// Application catalog management, application toggling and Web session preparation.

import { AppInfo, AppState, GatewayPath, Identity, ServerPin } from '../core/model/Models';
import { CatalogPhase, CatalogState, NodeRow, WebSession } from './State';
import { CatalogOutcome, CatalogOutcomeKind } from '../core/api/CatalogOutcome';
import { CatalogAnswer, ControlAnswer, ControlCode } from '../core/api/Dto';
import { ClientError, ErrorCode } from '../core/model/Errors';
import { ProtocolClient } from '../core/api/ProtocolClient';
import { IdentityVault } from '../core/identity/IdentityVault';
import { NodesController } from './NodesController';
import { Cadence } from '../core/model/Cadence';
import { MessageKeys } from '../core/model/MessageKeys';
import { hostOf } from '../core/api/Origins';
import { CredentialError } from '../core/identity/CredentialError';

@ObservedV2
export class CatalogController {
  private readonly client: ProtocolClient;
  private readonly vault: IdentityVault;
  private readonly nodesController: NodesController;
  private readonly applicationHosts: Map<string, string[]> = new Map<string, string[]>();

  @Trace catalog: CatalogState = CatalogState.idle();
  @Trace catalogNodeId: string = '';
  @Trace web: WebSession | null = null;
  @Trace webFailed: string = '';

  private catalogTimer: number = -1;
  private statusTimer: number = -1;

  onToast?: (key: string) => void;

  constructor(client: ProtocolClient, vault: IdentityVault, nodesController: NodesController) {
    this.client = client;
    this.vault = vault;
    this.nodesController = nodesController;
  }

  startCatalogRefresh(nodeId: string): void {
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
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  chosenPath(nodeId: string): GatewayPath | null {
    const row: NodeRow | null = this.nodesController.nodeRow(nodeId);
    return row === null ? null : row.chosen;
  }

  identityFor(origin: string): Identity | null {
    for (const identity of this.nodesController.identitiesSnapshot()) {
      if (identity.origin === origin) {
        return identity;
      }
    }
    return null;
  }

  async loadCatalog(nodeId: string): Promise<void> {
    const path: GatewayPath | null = this.chosenPath(nodeId);
    if (path === null) {
      this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], null, '');
      return;
    }
    try {
      const answer: CatalogAnswer = await this.client.catalog(path.origin, nodeId, Cadence.requestTimeoutMs);
      const outcome: CatalogOutcome = CatalogOutcome.forAnswer(answer);
      if (outcome.kind === CatalogOutcomeKind.Apps) {
        this.catalog = new CatalogState(CatalogPhase.Ready, nodeId, outcome.apps, null, '');
      } else {
        this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], ErrorCode.ComputerOffline, '');
      }
    } catch (error) {
      this.catalog = this.catalogFailure(nodeId, error);
    }
  }

  private catalogFailure(nodeId: string, error: Object): CatalogState {
    if (error instanceof ClientError) {
      const outcome: CatalogOutcome = CatalogOutcome.forRefusal(error);
      if (outcome.kind === CatalogOutcomeKind.Unauthorized) {
        return new CatalogState(CatalogPhase.Unauthorized, nodeId, [], error.code, '');
      }
      if (outcome.kind === CatalogOutcomeKind.Offline) {
        return new CatalogState(CatalogPhase.Offline, nodeId, [], error.code, '');
      }
      return new CatalogState(CatalogPhase.Failed, nodeId, [], error.code, '');
    }
    if (error instanceof CredentialError) {
      return new CatalogState(CatalogPhase.Unauthorized, nodeId, [], ErrorCode.Unauthorized, '');
    }
    return new CatalogState(CatalogPhase.Offline, nodeId, [], null, '');
  }

  async toggleApp(nodeId: string, app: AppInfo): Promise<void> {
    const path: GatewayPath | null = this.chosenPath(nodeId);
    if (path === null) {
      this.onToast?.(MessageKeys.forError(ErrorCode.ComputerOffline));
      return;
    }
    const starting: boolean = app.code === AppState.Stopped;
    const targetCode: AppState = starting ? AppState.Starting : AppState.Stopping;
    const transient: AppInfo = new AppInfo(app.id, app.name, app.description, app.icon, app.accent,
      app.launchFragment, starting, !starting, targetCode);
    this.catalog = this.catalog.withApp(transient).withBusy(app.id);
    try {
      const answer: ControlAnswer = starting
        ? await this.client.start(path.origin, nodeId, app.id)
        : await this.client.stop(path.origin, nodeId, app.id);
      if (answer.code === ControlCode.NotFound) {
        this.onToast?.(MessageKeys.ERROR_APP_GONE);
        await this.loadCatalog(nodeId);
        return;
      }
      if (answer.code === ControlCode.Offline) {
        this.onToast?.(MessageKeys.forError(ErrorCode.ComputerOffline));
        this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], ErrorCode.ComputerOffline, '');
        return;
      }
      if (answer.errorCode !== null) {
        this.onToast?.(MessageKeys.ERROR_CONTROL_FAILED);
      }
      this.pollUntilSettled(nodeId, app, path, targetCode);
    } catch (error) {
      this.catalog = this.catalog.withBusy('');
      this.onToast?.(MessageKeys.ERROR_CONTROL_FAILED);
      await this.loadCatalog(nodeId);
    }
  }

  private pollUntilSettled(nodeId: string, app: AppInfo, path: GatewayPath, target: AppState): void {
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
    const deadline: number = Date.now() + Cadence.controlPollTimeoutMs;
    let intervalMs: number = Cadence.controlPollMs;

    const ask = async (): Promise<void> => {
      if (Date.now() > deadline) {
        this.statusTimer = -1;
        this.catalog = this.catalog.withBusy('');
        return;
      }
      try {
        const answer: ControlAnswer = await this.client.status(path.origin, nodeId, app.id);
        if (answer.code === ControlCode.Offline) {
          this.statusTimer = -1;
          this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], ErrorCode.ComputerOffline, '');
          return;
        }
        if (answer.code === ControlCode.NotFound) {
          this.statusTimer = -1;
          this.onToast?.(MessageKeys.ERROR_APP_GONE);
          await this.loadCatalog(nodeId);
          return;
        }
        if (answer.app !== null) {
          this.catalog = this.catalog.withApp(answer.app);
          if (answer.app.code === AppState.Ready || answer.app.code === AppState.Stopped) {
            this.statusTimer = -1;
            this.catalog = this.catalog.withBusy('');
            return;
          }
        }
      } catch (error) {
        // Retry until deadline
      }
      intervalMs = Math.min(intervalMs * Cadence.controlPollFactor, Cadence.controlPollCeilingMs);
      this.statusTimer = setTimeout(ask, intervalMs);
    };

    this.statusTimer = setTimeout(ask, intervalMs);
  }

  async startForOpen(nodeId: string, app: AppInfo): Promise<void> {
    const path: GatewayPath | null = this.chosenPath(nodeId);
    if (path === null || app.code === AppState.Ready) {
      return;
    }
    try {
      await this.client.start(path.origin, nodeId, app.id);
    } catch (error) {
      // WebView will handle
    }
  }

  async beginWeb(nodeId: string, app: AppInfo): Promise<void> {
    const row: NodeRow | null = this.nodesController.nodeRow(nodeId);
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
      if (error instanceof ClientError && error.code !== null) {
        this.webFailed = MessageKeys.forError(error.code);
      } else {
        this.webFailed = MessageKeys.APP_OPEN_FAILED;
      }
    }
  }

  closeWeb(): void {
    this.web = null;
    this.webFailed = '';
  }

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

  forgetApplicationHosts(gatewayOrigin: string): void {
    this.applicationHosts.delete(gatewayOrigin);
  }
}
