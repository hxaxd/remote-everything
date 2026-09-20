// Node list management, origin probing, merging and caching.

import { GatewayPath, Identity, Node, NodeStatus } from '../core/model/Models';
import { NodeRow } from './State';
import { SettingsStore } from '../core/store/SettingsStore';
import { NodeCacheStore } from '../core/store/NodeCacheStore';
import { IdentityVault } from '../core/identity/IdentityVault';
import { ProtocolClient } from '../core/api/ProtocolClient';
import { PathSelector } from '../core/pathselect/PathSelector';
import { NetworkEnvironment } from '../core/pathselect/NetworkEnvironment';
import { OriginProbe, mergeNodes } from '../core/api/Merge';
import { Cadence } from '../core/model/Cadence';
import { LINK_ATTEMPTS_KEPT, LinkAttempt, LinkFailure, LinkTrouble, classifyFailure } from '../core/diag/LinkReport';

/** How long a refresh stays visible at minimum, so its spinner is one a person saw. */
const MIN_REFRESH_MS: number = 600;

@ObservedV2
export class NodesController {
  private readonly vault: IdentityVault;
  private readonly store: SettingsStore;
  private readonly cache: NodeCacheStore;
  private readonly client: ProtocolClient;
  private readonly selector: PathSelector;
  private readonly environment: NetworkEnvironment;

  @Trace identities: Identity[] = [];
  @Trace nodes: NodeRow[] = [];
  @Trace refreshing: boolean = false;
  private refreshQueued: boolean = false;

  /**
   * Per gateway, why it is not answering now. A gateway that answers has no entry
   * here, which is what the screen keys the copy button off.
   */
  @Trace trouble: Map<string, LinkTrouble> = new Map<string, LinkTrouble>();

  /** Per gateway, when it last answered — what "last answer" means in a report. */
  private lastAnswerAt: Map<string, number> = new Map<string, number>();

  /** Per gateway, the last few failed probes, newest first. */
  private failedProbes: Map<string, LinkAttempt[]> = new Map<string, LinkAttempt[]>();

  constructor(
    vault: IdentityVault,
    store: SettingsStore,
    cache: NodeCacheStore,
    client: ProtocolClient,
    selector: PathSelector,
    environment: NetworkEnvironment
  ) {
    this.vault = vault;
    this.store = store;
    this.cache = cache;
    this.client = client;
    this.selector = selector;
    this.environment = environment;
  }

  reloadIdentities(): Identity[] {
    this.identities = this.store.readIdentities();
    return this.identities;
  }

  identitiesSnapshot(): Identity[] {
    return this.store.readIdentities();
  }

  /**
   * The whole list, rebuilt from what every gateway answers. A gateway that does not
   * answer does not empty the screen: its nodes stay, marked as not probed. A forced
   * refresh asked for while one is already in flight — the network just changed — is
   * queued and runs the moment the one in flight settles.
   */
  async refreshNodes(force: boolean = false): Promise<void> {
    if (this.refreshing) {
      if (force) {
        this.refreshQueued = true;
      }
      return;
    }
    this.refreshing = true;
    const startedAt: number = Date.now();
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
    } finally {
      const elapsed: number = Date.now() - startedAt;
      if (elapsed < MIN_REFRESH_MS) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, MIN_REFRESH_MS - elapsed);
        });
      }
      this.refreshing = false;
      if (this.refreshQueued) {
        this.refreshQueued = false;
        await this.refreshNodes();
      }
    }
  }

  private async probeOne(origin: string): Promise<OriginProbe> {
    const started: number = Date.now();
    try {
      const answer = await this.client.nodes(origin, Cadence.probeTimeoutMs);
      this.answered(origin);
      return OriginProbe.answer(origin, Date.now() - started, answer);
    } catch (error) {
      this.failed(origin, classifyFailure(error as Error, this.environment.offline()));
      return OriginProbe.unreachable(origin, error);
    }
  }

  /**
   * A gateway that answered is not in trouble. The moment is kept even though no
   * screen shows it, because "last answer" in a report is what tells a reader
   * whether a failure is new or has been going on.
   */
  private answered(origin: string): void {
    this.lastAnswerAt.set(origin, Date.now());
    this.failedProbes.delete(origin);
    this.clearTrouble(origin);
  }

  /**
   * A gateway that did not answer. The failure is kept, not just its count: the
   * kind is what a screen and a report say, and `since` is what makes a blip and a
   * state of affairs different things.
   */
  private failed(origin: string, failure: LinkFailure): void {
    const now: number = Date.now();
    const found: LinkAttempt[] | undefined = this.failedProbes.get(origin);
    const log: LinkAttempt[] = found !== undefined ? found : [];
    log.unshift(new LinkAttempt(now, failure.kind));
    while (log.length > LINK_ATTEMPTS_KEPT) {
      log.pop();
    }
    this.failedProbes.set(origin, log);
    const previous: LinkTrouble | undefined = this.trouble.get(origin);
    const lastGood: number | undefined = this.lastAnswerAt.get(origin);
    const next: Map<string, LinkTrouble> = this.copyTrouble();
    next.set(origin, new LinkTrouble(
      failure.kind,
      now,
      previous !== undefined ? previous.since : now,
      previous !== undefined ? previous.attempts + 1 : 1,
      failure.code,
      failure.httpStatus,
      failure.detail,
      lastGood !== undefined ? lastGood : null
    ));
    this.trouble = next;
  }

  /** The last few failed probes for one gateway, newest first. */
  attemptsFor(origin: string): LinkAttempt[] {
    const log: LinkAttempt[] | undefined = this.failedProbes.get(origin);
    return log === undefined ? [] : log.slice();
  }

  /** When this gateway last answered, as far as this run of the app remembers. */
  lastAnswerFor(origin: string): number | null {
    const at: number | undefined = this.lastAnswerAt.get(origin);
    return at === undefined ? null : at;
  }

  /** Forgetting a connection forgets what was remembered about its link. */
  drop(origin: string): void {
    this.lastAnswerAt.delete(origin);
    this.failedProbes.delete(origin);
    this.clearTrouble(origin);
  }

  private clearTrouble(origin: string): void {
    if (!this.trouble.has(origin)) {
      return;
    }
    const next: Map<string, LinkTrouble> = this.copyTrouble();
    next.delete(origin);
    this.trouble = next;
  }

  private copyTrouble(): Map<string, LinkTrouble> {
    const copy: Map<string, LinkTrouble> = new Map<string, LinkTrouble>();
    this.trouble.forEach((value: LinkTrouble, key: string) => {
      copy.set(key, value);
    });
    return copy;
  }

  statusOf(node: Node): NodeStatus {
    const reachable: GatewayPath[] = node.paths.filter((path: GatewayPath) => path.reachable === true);
    if (reachable.length > 0) {
      const chosen: GatewayPath = node.paths[0];
      return chosen.isPrivate ? NodeStatus.OnlineLan : NodeStatus.OnlineTunnel;
    }
    // Never "unknown": a node with no reachable path is offline, the same word
    // the other clients use from the first look.
    return NodeStatus.Offline;
  }

  /** The selector this controller decides routes with, for the catalog's own falls. */
  selectorForCatalog(): PathSelector {
    return this.selector;
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
    this.drop(origin);
    this.nodes = this.nodes.filter((row: NodeRow) =>
      !row.node.paths.some((path: GatewayPath) => path.origin === origin));
    const remaining: Identity[] = this.identitiesSnapshot().filter((identity: Identity) =>
      identity.origin !== origin);
    this.store.writeIdentities(remaining);
    this.reloadIdentities();
    await this.refreshNodes();
  }
}
