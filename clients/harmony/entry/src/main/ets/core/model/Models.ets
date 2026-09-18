// The data structures every layer shares, with the field names all three clients use. This package depends on nothing: it is the vocabulary the rest of
// core and the app layer speak, so that a type used by two of them is defined once
// and not twice.

export enum AppState {
  Ready = 'ready',
  Starting = 'starting',
  Stopping = 'stopping',
  Stopped = 'stopped'
}

/** The node row state machine of ui-contract §2/S1. `Unknown` is the initial transient. */
export enum NodeStatus {
  Unknown = 'unknown',
  OnlineLan = 'onlineLan',
  OnlineTunnel = 'onlineTunnel',
  Offline = 'offline',
  PendingApproval = 'pendingApproval'
}

export enum Appearance {
  System = 'system',
  Light = 'light',
  Dark = 'dark'
}

export enum Language {
  System = 'system',
  Chinese = 'zh',
  English = 'en'
}

/** The two halves of a self-signed gateway's identity, remembered from its invitation. */
export class ServerPin {
  readonly certFingerprint: string;
  readonly publicKeyPin: string;

  constructor(certFingerprint: string, publicKeyPin: string) {
    this.certFingerprint = certFingerprint;
    this.publicKeyPin = publicKeyPin;
  }
}

/**
 * One pairing result for one gateway origin: the device certificate plus what this
 * client remembers about that gateway. The certificate itself never appears here —
 * `credentialRef` names it in platform secure storage.
 *
 * There is no installation id: the wire never carries one (the gateway's own
 * installation id appears only in its operator's CLI output), so a client that recorded
 * one would be recording its own invention. Three clients agree on this field list.
 */
export class Identity {
  readonly origin: string;
  readonly deviceName: string;
  readonly certFingerprint: string;
  readonly credentialRef: string;
  readonly serverPin: ServerPin | null;
  readonly createdAt: number;

  constructor(origin: string, deviceName: string, certFingerprint: string, credentialRef: string,
    serverPin: ServerPin | null, createdAt: number) {
    this.origin = origin;
    this.deviceName = deviceName;
    this.certFingerprint = certFingerprint;
    this.credentialRef = credentialRef;
    this.serverPin = serverPin;
    this.createdAt = createdAt;
  }

  /** The same identity with a credential reference that was renewed. */
  withCredential(credentialRef: string, certFingerprint: string): Identity {
    return new Identity(this.origin, this.deviceName, certFingerprint, credentialRef, this.serverPin,
      this.createdAt);
  }
}

/** One way to reach one node: an origin this device holds a credential for. */
export class GatewayPath {
  readonly origin: string;
  readonly identityRef: string;
  readonly reachable: boolean | null;
  readonly latencyMs: number | null;
  readonly isPrivate: boolean;
  readonly lastCheckedAt: number | null;

  constructor(origin: string, identityRef: string, reachable: boolean | null, latencyMs: number | null,
    isPrivate: boolean, lastCheckedAt: number | null) {
    this.origin = origin;
    this.identityRef = identityRef;
    this.reachable = reachable;
    this.latencyMs = latencyMs;
    this.isPrivate = isPrivate;
    this.lastCheckedAt = lastCheckedAt;
  }

  withProbe(reachable: boolean, latencyMs: number, at: number): GatewayPath {
    return new GatewayPath(this.origin, this.identityRef, reachable, latencyMs, this.isPrivate, at);
  }
}

/** The merged view of one machine: the same node id seen through one or more gateways. */
export class Node {
  readonly id: string;
  readonly name: string;
  readonly paths: GatewayPath[];

  constructor(id: string, name: string, paths: GatewayPath[]) {
    this.id = id;
    this.name = name;
    this.paths = paths;
  }
}

/** One application of one node, as GET /__remote_everything/apps describes it. */
export class AppInfo {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly icon: string;
  readonly accent: string;
  readonly launchFragment: string;
  readonly enabled: boolean;
  readonly running: boolean;
  readonly code: AppState;

  constructor(id: string, name: string, description: string, icon: string, accent: string, launchFragment: string,
    enabled: boolean, running: boolean, code: AppState) {
    this.id = id;
    this.name = name;
    this.description = description;
    this.icon = icon;
    this.accent = accent;
    this.launchFragment = launchFragment;
    this.enabled = enabled;
    this.running = running;
    this.code = code;
  }
}

/** What one origin's GET /__remote_everything/nodes answered, kept for a cold start. */
export class CachedNodes {
  readonly origin: string;
  readonly nodes: Node[];
  readonly fetchedAt: number;

  constructor(origin: string, nodes: Node[], fetchedAt: number) {
    this.origin = origin;
    this.nodes = nodes;
    this.fetchedAt = fetchedAt;
  }
}
