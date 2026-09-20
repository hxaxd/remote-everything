// The shared state classes and value types for the application layer.

import { AppInfo, GatewayPath, LinkKind, Node, NodeStatus, ServerPin } from '../core/model/Models';
import { ErrorCode } from '../core/model/Errors';
import { palette } from './ui/Components';
import { SetupUri } from '../core/setup/SetupUri';

/** The stage machine of ui-contract §2/S2, exactly as the screen can show it. */
export enum PairingStage {
  Input = 'input',
  Confirm = 'confirm',
  Pairing = 'pairing',
  WaitingApproval = 'waitingApproval',
  Done = 'done'
}

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

  /** Whether the way in use right now is one of these two kinds. */
  isUsing(kind: LinkKind): boolean {
    const path: GatewayPath | null = this.chosen;
    return this.isOnline && path !== null && path.link === kind;
  }

  /** The colour one kind of link is drawn in: in use, or merely available. */
  linkTone(kind: LinkKind, dark: boolean): string {
    if (!this.isUsing(kind)) {
      return palette(dark).textTertiary;
    }
    return kind === LinkKind.Local ? palette(dark).ok : palette(dark).warn;
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

/** S2's screen state, mirroring the stage machine of ui-contract §2/S2.
 * `nodeName` rides along for the states that name a node while it works or waits —
 * the home screen's pending banner and the pairing screen's two busy stages —
 * because by then the setup may already be gone. */
export class PairingState {
  readonly stage: PairingStage;
  readonly setup: SetupUri | null;
  readonly deviceName: string;
  readonly errorKey: string | null;
  readonly nodeName: string;

  constructor(stage: PairingStage, setup: SetupUri | null, deviceName: string, errorKey: string | null,
    nodeName: string = '') {
    this.stage = stage;
    this.setup = setup;
    this.deviceName = deviceName;
    this.errorKey = errorKey;
    this.nodeName = nodeName;
  }

  static idle(): PairingState {
    return new PairingState(PairingStage.Input, null, '', null);
  }

  withStage(stage: PairingStage, errorKey: string | null): PairingState {
    return new PairingState(stage, this.setup, this.deviceName, errorKey, this.nodeName);
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
