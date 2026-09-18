// Node list management, origin probing, merging and caching.

import { GatewayPath, Identity, Node, NodeStatus } from '../core/model/Models';
import { NodeRow } from './State';
import { IdentityStore } from '../core/store/IdentityStore';
import { NodeCacheStore } from '../core/store/NodeCacheStore';
import { IdentityVault, CredentialMaterial } from '../core/identity/IdentityVault';
import { ProtocolClient } from '../core/api/ProtocolClient';
import { PathSelector } from '../core/pathselect/PathSelector';
import { NetworkEnvironment } from '../core/pathselect/NetworkEnvironment';
import { OriginProbe, mergeNodes } from '../core/api/Merge';
import { PairingTransaction, StagedPairing } from '../core/pairing/PairingTransaction';

@ObservedV2
export class NodesController {
  private readonly vault: IdentityVault;
  private readonly identityStore: IdentityStore;
  private readonly cache: NodeCacheStore;
  private readonly client: ProtocolClient;
  private readonly selector: PathSelector;
  private readonly environment: NetworkEnvironment;
  private readonly transaction: PairingTransaction;

  @Trace identities: Identity[] = [];
  @Trace nodes: NodeRow[] = [];
  @Trace needsPairing: string[] = [];
  @Trace refreshing: boolean = false;
  @Trace probedOnce: boolean = false;

  constructor(
    vault: IdentityVault,
    identityStore: IdentityStore,
    cache: NodeCacheStore,
    client: ProtocolClient,
    selector: PathSelector,
    environment: NetworkEnvironment,
    transaction: PairingTransaction
  ) {
    this.vault = vault;
    this.identityStore = identityStore;
    this.cache = cache;
    this.client = client;
    this.selector = selector;
    this.environment = environment;
    this.transaction = transaction;
  }

  reloadIdentities(): Identity[] {
    this.identities = this.identityStore.read();
    return this.identities;
  }

  identitiesSnapshot(): Identity[] {
    return this.identityStore.read();
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
          const cached = this.cache.read(identity.origin, identity.credentialRef);
          if (cached !== null) {
            previous.push(...cached.nodes);
          }
        }
      }
      const origins: string[] = known.map((identity: Identity) => identity.origin);
      const probes: OriginProbe[] = await Promise.all(origins.map((o: string) => this.probeOne(o)));
      const merged: Node[] = mergeNodes(probes, known, previous).map((n: Node) => this.selector.route(n));
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
      if (probes.some((probe: OriginProbe) => !probe.reachable)) {
        await this.checkCredentials();
      }
      this.probedOnce = true;
    } finally {
      this.refreshing = false;
    }
  }

  private async probeOne(origin: string): Promise<OriginProbe> {
    const started: number = Date.now();
    try {
      const answer = await this.client.nodes(origin, 2000);
      return OriginProbe.answer(origin, Date.now() - started, answer);
    } catch (error) {
      return OriginProbe.unreachable(origin, error);
    }
  }

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

  statusOf(node: Node): NodeStatus {
    const staged: StagedPairing | null = this.transaction.read();
    if (staged !== null && staged.node === node.id) {
      return NodeStatus.PendingApproval;
    }
    const reachable: GatewayPath[] = node.paths.filter((path: GatewayPath) => path.reachable === true);
    if (reachable.length > 0) {
      const chosen: GatewayPath = node.paths[0];
      return chosen.isPrivate ? NodeStatus.OnlineLan : NodeStatus.OnlineTunnel;
    }
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

  async forget(origin: string): Promise<void> {
    await this.vault.forget(origin);
    this.cache.remove(origin);
    this.client.release(origin);
    this.nodes = this.nodes.filter((row: NodeRow) =>
      !row.node.paths.some((path: GatewayPath) => path.origin === origin));
    const remaining: Identity[] = this.identitiesSnapshot().filter((identity: Identity) =>
      identity.origin !== origin);
    this.identityStore.write(remaining);
    this.reloadIdentities();
    this.needsPairing = this.needsPairing.filter((entry: string) => entry !== origin);
    await this.refreshNodes();
  }
}
