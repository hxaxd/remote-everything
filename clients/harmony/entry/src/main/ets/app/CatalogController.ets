// Application catalog management, application toggling and Web session preparation.

import { AppInfo, AppState, GatewayPath, Identity, ServerPin, sameIdentity } from '../core/model/Models';
import { CatalogPhase, CatalogState, NodeRow, WebSession } from './State';
import { CatalogOutcome, CatalogOutcomeKind } from '../core/api/CatalogOutcome';
import { CatalogAnswer, ControlAnswer, ControlCode } from '../core/api/Dto';
import { ClientError, CredentialError, ErrorCode } from '../core/model/Errors';
import { ProtocolClient } from '../core/api/ProtocolClient';
import { IdentityVault } from '../core/identity/IdentityVault';
import { NodesController } from './NodesController';
import { PathSelector } from '../core/pathselect/PathSelector';
import { Cadence } from '../core/model/Cadence';
import { MessageKeys } from '../core/model/MessageKeys';
import { hostOf } from '../core/api/Origins';

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

  private readonly selector: PathSelector;
  private catalogTimer: number = -1;
  private readonly statusTimers: Map<string, number> = new Map<string, number>();
  private readonly busyApps: Set<string> = new Set<string>();
  private activeNodeId: string = '';
  private visit: number = 0;
  private request: number = 0;
  private webRequest: number = 0;

  private enter(nodeId: string): number {
    if (this.activeNodeId !== nodeId) {
      this.webRequest += 1;
      this.stopCatalogRefresh();
      this.activeNodeId = nodeId;
    }
    this.catalogNodeId = nodeId;
    return this.visit;
  }

  private current(nodeId: string, visit: number): boolean {
    return this.catalogNodeId === nodeId && this.activeNodeId === nodeId && this.visit === visit;
  }

  private identityCurrent(identity: Identity): boolean {
    const current: Identity | null = this.identityFor(identity.origin);
    return current !== null && sameIdentity(identity, current);
  }

  onToast?: (key: string) => void;

  constructor(client: ProtocolClient, vault: IdentityVault, nodesController: NodesController) {
    this.client = client;
    this.vault = vault;
    this.nodesController = nodesController;
    this.selector = nodesController.selectorForCatalog();
  }

  startCatalogRefresh(nodeId: string): void {
    this.enter(nodeId);
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
    this.visit += 1;
    this.request += 1;
    if (this.catalogTimer >= 0) {
      clearInterval(this.catalogTimer);
      this.catalogTimer = -1;
    }
    this.statusTimers.forEach((timer: number) => { clearTimeout(timer); });
    this.statusTimers.clear();
    this.busyApps.clear();
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

  /**
   * One node's applications, asked for down every road that answers.
   *
   * The chosen road goes first, and a road that stopped answering is a reason to
   * try the one behind it — a phone that still holds a tunnel must not be told its
   * machine is gone because the Wi-Fi it was on is gone. A refusal is different:
   * it is the gateway's answer, and another road would answer the same.
   */
  async loadCatalog(nodeId: string): Promise<void> {
    const visit: number = this.enter(nodeId);
    const request: number = ++this.request;
    const roads: GatewayPath[] = this.roads(nodeId);
    if (roads.length === 0) {
      this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], null, '');
      return;
    }
    let failure: Object | null = null;
    for (const path of roads) {
      const identity: Identity | null = this.identityFor(path.origin);
      if (identity === null) { continue; }
      try {
        await this.client.connect(path.origin, identity.serverPin);
        if (!this.current(nodeId, visit) || !this.identityCurrent(identity)) { return; }
        const answer: CatalogAnswer = await this.client.apps(path.origin, nodeId);
        if (!this.current(nodeId, visit) || request !== this.request || !this.identityCurrent(identity)) { return; }
        const outcome: CatalogOutcome = CatalogOutcome.forAnswer(answer);
        if (outcome.kind === CatalogOutcomeKind.Apps) {
          this.nodesController.markPath(nodeId, path.origin, true);
          const apps: AppInfo[] = outcome.apps.map((app: AppInfo) => this.busyApps.has(app.id)
            ? this.catalog.apps.find((old: AppInfo) => old.id === app.id) ?? app : app);
          this.catalog = new CatalogState(CatalogPhase.Ready, nodeId, apps, null, '');
        } else {
          this.nodesController.markPath(nodeId, path.origin, false);
          continue;
        }
        return;
      } catch (error) {
        if (!this.current(nodeId, visit) || request !== this.request || !this.identityCurrent(identity)) { return; }
        failure = error;
        if (error instanceof ClientError
          && CatalogOutcome.forRefusal(error).kind !== CatalogOutcomeKind.Offline) {
          break;
        }
        // This road is not answering: the next one gets the turn, and the choice
        // stops pointing here.
        this.nodesController.markPath(nodeId, path.origin, false);
      }
    }
    if (this.current(nodeId, visit) && request === this.request) {
      this.catalog = this.catalogFailure(nodeId, failure ?? ClientError.transport('every road failed'));
    }
  }

  /** The roads to this node, the chosen one first: what answers, best first. */
  private roads(nodeId: string): GatewayPath[] {
    const row: NodeRow | null = this.nodesController.nodeRow(nodeId);
    if (row === null) {
      return [];
    }
    const chosen: GatewayPath | null = this.selector.choose(row.node);
    const rest: GatewayPath[] = row.node.paths.filter((path: GatewayPath) =>
      path.reachable === true && (chosen === null || path.origin !== chosen.origin));
    return (chosen === null ? [] : [chosen]).concat(rest);
  }

  private catalogFailure(nodeId: string, error: Object): CatalogState {
    if (error instanceof ClientError) {
      if (error.code === null) {
        // No answer at all, or an answer this client could not read, is a node
        // that is not reachable — not a gateway that is in trouble. The other
        // clients read it the same way.
        return new CatalogState(CatalogPhase.Offline, nodeId, [], null, '');
      }
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
    const visit: number = this.enter(nodeId);
    if (this.busyApps.has(app.id) || app.code === AppState.Starting || app.code === AppState.Stopping) { return; }
    this.busyApps.add(app.id);
    const starting: boolean = app.code === AppState.Stopped;
    const targetCode: AppState = starting ? AppState.Starting : AppState.Stopping;
    const transient: AppInfo = new AppInfo(app.id, app.name, app.description, app.icon, app.accent,
      app.launchFragment, starting, !starting, targetCode);
    this.catalog = this.catalog.withApp(transient).withBusy(app.id);
    let commandSent: boolean = false;
    let selectedIdentity: Identity | null = null;
    try {
      let path: GatewayPath | null = null;
      for (const candidate of this.roads(nodeId)) {
        const candidateIdentity: Identity | null = this.identityFor(candidate.origin);
        if (candidateIdentity === null) { continue; }
        try {
          await this.client.connect(candidate.origin,candidateIdentity.serverPin);
          if (!this.current(nodeId,visit) || !this.identityCurrent(candidateIdentity)) { return; }
          const status: ControlAnswer = await this.client.status(candidate.origin, nodeId, app.id);
          if (!this.current(nodeId, visit) || !this.identityCurrent(candidateIdentity)) { return; }
          if (status.code === ControlCode.AppNotFound) { throw new ClientError(ErrorCode.AppNotFound,200,'application removed'); }
          if (status.code === ControlCode.ComputerOffline) {
            this.nodesController.markPath(nodeId, candidate.origin, false); continue;
          }
          path = candidate;
          selectedIdentity = candidateIdentity;
          break;
        } catch (error) {
          if (!this.current(nodeId, visit) || !this.identityCurrent(candidateIdentity)) { return; }
          if (error instanceof ClientError && error.code !== null && error.code !== ErrorCode.ComputerOffline) { throw error; }
          this.nodesController.markPath(nodeId, candidate.origin, false);
        }
      }
      if (path === null) { throw ClientError.transport('no control route'); }
      const identity: Identity | null = selectedIdentity;
      if (identity === null) { throw ClientError.transport('identity removed'); }
      commandSent = true;
      const answer: ControlAnswer = starting
        ? await this.client.start(path.origin, nodeId, app.id)
        : await this.client.stop(path.origin, nodeId, app.id);
      if (!this.current(nodeId, visit) || !this.identityCurrent(identity)) { return; }
      if (answer.code === ControlCode.AppNotFound) {
        this.onToast?.(MessageKeys.ERROR_APP_GONE);
        this.busyApps.delete(app.id);
        await this.loadCatalog(nodeId);
        return;
      }
      if (answer.code === ControlCode.ComputerOffline) {
        this.onToast?.(MessageKeys.forError(ErrorCode.ComputerOffline));
        this.busyApps.delete(app.id);
        this.catalog = new CatalogState(CatalogPhase.Offline, nodeId, [], ErrorCode.ComputerOffline, '');
        return;
      }
      if (answer.code === ControlCode.StateUpdateFailed) {
        // The state could not move: that is a stop that failed, and it is named
        // for what it is — the same word every client says here.
        this.onToast?.(MessageKeys.ERROR_STOP_FAILED);
      }
      this.pollUntilSettled(nodeId, app, visit);
    } catch (error) {
      if (!this.current(nodeId, visit)) { return; }
      if (selectedIdentity !== null && !this.identityCurrent(selectedIdentity)) { this.busyApps.delete(app.id); return; }
      if (!commandSent || error instanceof ClientError && error.code !== null && error.code !== ErrorCode.ComputerOffline) {
        this.busyApps.delete(app.id);
        this.onToast?.(MessageKeys.forFailure(error));
        await this.loadCatalog(nodeId); return;
      }
      // A command may have reached the node: reconcile with reads, never resend it.
      this.catalog = this.catalog.withBusy('');
      this.onToast?.(MessageKeys.ERROR_CONTROL_FAILED);
      this.pollUntilSettled(nodeId, app, visit);
    }
  }

  private pollUntilSettled(nodeId: string, app: AppInfo, visit: number): void {
    const deadline: number = Date.now() + Cadence.controlPollTimeoutMs;
    let intervalMs: number = Cadence.controlPollMs;

    const ask = async (): Promise<void> => {
      this.statusTimers.delete(app.id);
      if (!this.current(nodeId, visit)) { return; }
      if (Date.now() >= deadline) {
        this.onToast?.(MessageKeys.ERROR_CONTROL_FAILED);
        await this.finishControl(nodeId, app.id, visit);
        return;
      }
      for (const path of this.roads(nodeId)) {
        const identity: Identity | null = this.identityFor(path.origin);
        if (identity === null) { continue; }
        try {
          const answer: ControlAnswer = await this.client.status(path.origin, nodeId, app.id,
            Math.min(Cadence.requestTimeoutMs, Math.max(1, deadline - Date.now())));
          if (!this.current(nodeId, visit) || !this.identityCurrent(identity)) { return; }
          if (answer.code === ControlCode.ComputerOffline) { this.nodesController.markPath(nodeId, path.origin, false); continue; }
          if (answer.code === ControlCode.AppNotFound) {
            this.onToast?.(MessageKeys.ERROR_APP_GONE);
            await this.finishControl(nodeId, app.id, visit); return;
          }
          this.nodesController.markPath(nodeId, path.origin, true);
          const code: AppState | null = answer.code === ControlCode.Ready ? AppState.Ready :
            answer.code === ControlCode.Starting ? AppState.Starting : answer.code === ControlCode.Stopping ? AppState.Stopping :
            answer.code === ControlCode.Stopped ? AppState.Stopped : null;
          if (answer.app !== null) { this.catalog = this.catalog.withApp(answer.app); }
          else if (code !== null) {
            this.catalog = this.catalog.withApp(new AppInfo(app.id, app.name, app.description, app.icon, app.accent,
              app.launchFragment, answer.enabled, answer.running, code));
          }
          if (code === AppState.Ready || code === AppState.Stopped) {
            await this.finishControl(nodeId, app.id, visit); return;
          }
          break;
        } catch (error) {
          if (!this.current(nodeId, visit) || !this.identityCurrent(identity)) { return; }
          if (error instanceof ClientError && error.code === ErrorCode.Unauthorized) {
            this.busyApps.delete(app.id);
            this.catalog = this.catalogFailure(nodeId, error); return;
          }
          this.nodesController.markPath(nodeId, path.origin, false);
        }
      }
      intervalMs = Math.min(intervalMs * Cadence.controlPollFactor, Cadence.controlPollCeilingMs);
      if (this.current(nodeId, visit)) { this.statusTimers.set(app.id, setTimeout(ask, Math.min(intervalMs, Math.max(1, deadline - Date.now())))); }
    };

    this.statusTimers.set(app.id, setTimeout(ask, intervalMs));
  }

  private async finishControl(nodeId: string, appId: string, visit: number): Promise<void> {
    if (!this.current(nodeId, visit)) { return; }
    this.busyApps.delete(appId);
    this.statusTimers.delete(appId);
    this.catalog = this.catalog.withBusy('');
    await this.loadCatalog(nodeId);
  }

  async beginWeb(nodeId: string, app: AppInfo): Promise<void> {
    const request: number = ++this.webRequest;
    this.web = null;
    this.webFailed = '';
    if (app.code === AppState.Stopped || app.code === AppState.Stopping) {
      this.webFailed = MessageKeys.APP_OPEN_FAILED;
      return;
    }
    const deadline: number = Date.now() + Cadence.controlPollTimeoutMs;
    do {
      for (const path of this.roads(nodeId)) {
        const identity: Identity | null = this.identityFor(path.origin);
        if (identity === null) { continue; }
        try {
          await this.client.connect(path.origin, identity.serverPin);
          if (request !== this.webRequest || nodeId !== this.catalogNodeId || !this.identityCurrent(identity)) { return; }
          if (app.code === AppState.Starting) {
            const status: ControlAnswer = await this.client.status(path.origin, nodeId, app.id,
              Math.min(Cadence.requestTimeoutMs, Math.max(1, deadline - Date.now())));
            if (request !== this.webRequest || !this.identityCurrent(identity)) { return; }
            if (status.code !== ControlCode.Ready) { continue; }
          }
          const keyUri: string = await this.vault.webIdentity(path.origin);
          if (request !== this.webRequest || nodeId !== this.catalogNodeId || !this.identityCurrent(identity)) { return; }
          const target: string = await this.client.open(path.origin, nodeId, app.id);
          if (request !== this.webRequest || nodeId !== this.catalogNodeId || !this.identityCurrent(identity)) { return; }
          this.nodesController.markPath(nodeId, path.origin, true);
          this.rememberApplicationHost(path.origin, hostOf(target));
          this.web = new WebSession(path.origin, nodeId, app.id, app.name, app.launchFragment, identity.serverPin,
            path.isPrivate, keyUri, `${target}${app.launchFragment}`);
          return;
        } catch (error) {
          if (request !== this.webRequest || nodeId !== this.catalogNodeId || !this.identityCurrent(identity)) { return; }
          if (error instanceof ClientError && error.code !== null && error.code !== ErrorCode.ComputerOffline) {
            this.webFailed = MessageKeys.forFailure(error); return;
          }
          this.nodesController.markPath(nodeId, path.origin, false);
        }
      }
      if (app.code !== AppState.Starting) { break; }
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, Cadence.controlPollMs); });
    } while (request === this.webRequest && Date.now() < deadline);
    if (request === this.webRequest) { this.webFailed = MessageKeys.APP_OPEN_FAILED; }
  }

  closeWeb(): void {
    this.webRequest += 1;
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
