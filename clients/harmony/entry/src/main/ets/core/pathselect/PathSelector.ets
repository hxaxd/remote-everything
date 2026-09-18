// Which way to reach a node, and which nodes there are.
//
// A node list is never built here: it is what the gateways answered, merged by node
// id, and the merge is a whole replacement rather than an edit (ui-contract §2/S1,
// architecture §4). What this package decides is the quiet part — which of a node's
// paths a request should take:
//
//   * a reachable path whose origin is a private address beats one that is not,
//     because it is the one that does not leave the local network;
//   * among equals, the one that answered fastest;
//   * and the choice is remembered per network environment, so a list that is
//     refreshed twice on the same Wi-Fi does not silently move traffic to a slower
//     route.
//
// Probing is free: the same GET /__remote_everything/nodes that refreshes the list is
// what a probe is, with the two-second budget ui-contract §5 gives it.

import { GatewayPath, Identity, Node } from '../model/Models';
import { Cadence } from '../model/Cadence';
import { NodeSummary, NodesAnswer } from '../api/Dto';
import { ClientError } from '../api/Errors';
import { ProtocolClient } from '../api/ProtocolClient';

/** One gateway's answer to a probe, and how long it took to arrive. */
export class OriginProbe {
  readonly origin: string;
  readonly reachable: boolean;
  readonly latencyMs: number;
  readonly nodes: NodeSummary[];
  readonly failure: ClientError | null;

  constructor(origin: string, reachable: boolean, latencyMs: number, nodes: NodeSummary[],
    failure: ClientError | null) {
    this.origin = origin;
    this.reachable = reachable;
    this.latencyMs = latencyMs;
    this.nodes = nodes;
    this.failure = failure;
  }

  static answer(origin: string, latencyMs: number, answer: NodesAnswer): OriginProbe {
    return new OriginProbe(origin, true, latencyMs, answer.nodes, null);
  }

  static unreachable(origin: string, failure: ClientError): OriginProbe {
    return new OriginProbe(origin, false, 0, [], failure);
  }
}

/** A node and the path a request for it should take. */
export class RoutedNode {
  readonly node: Node;
  readonly chosen: GatewayPath | null;

  constructor(node: Node, chosen: GatewayPath | null) {
    this.node = node;
    this.chosen = chosen;
  }
}

/** Whether an address is one that only the local network can reach. */
export function isPrivateHost(hostname: string): boolean {
  const host: string = hostname.toLowerCase().replace('[', '').replace(']', '');
  if (host === 'localhost' || host === '::1' || host.startsWith('127.') || host === '::ffff:127.0.0.1') {
    return true;
  }
  const parts: string[] = host.split('.');
  if (parts.length === 4) {
    const first: number = Number.parseInt(parts[0], 10);
    const second: number = Number.parseInt(parts[1], 10);
    if (first === 10 || (first === 172 && second >= 16 && second <= 31) || (first === 192 && second === 168) ||
      (first === 169 && second === 254) || (first === 100 && second >= 64 && second <= 127)) {
      return true;
    }
    return false;
  }
  if (host.startsWith('fe80:') || host.startsWith('fc') || host.startsWith('fd')) {
    return true;
  }
  if (host.startsWith('::ffff:')) {
    return isPrivateHost(host.substring('::ffff:'.length));
  }
  return false;
}

export class PathSelector {
  private readonly client: ProtocolClient;
  private environment: string = '';
  private remembered: Map<string, string> = new Map<string, string>();

  constructor(client: ProtocolClient) {
    this.client = client;
  }

  /**
   * Probes every gateway at once. One origin that does not answer is not a failure of
   * the others: each answer stands on its own, and a node that was in the last answer
   * keeps its place in the list (see `merge`).
   */
  async probe(origins: string[]): Promise<OriginProbe[]> {
    const pending: Promise<OriginProbe>[] = [];
    for (const origin of origins) {
      pending.push(this.probeOne(origin));
    }
    return await Promise.all(pending);
  }

  private async probeOne(origin: string): Promise<OriginProbe> {
    const started: number = Date.now();
    try {
      const answer: NodesAnswer = await this.client.nodes(origin, Cadence.probeTimeoutMs);
      return OriginProbe.answer(origin, Date.now() - started, answer);
    } catch (error) {
      if (error instanceof ClientError) {
        return OriginProbe.unreachable(origin, error);
      }
      return OriginProbe.unreachable(origin, ClientError.transport('the probe failed'));
    }
  }

  /**
   * Merges what the gateways answered into one list, keyed by node id, and remembers
   * which path each node should take. Nodes are never added or removed here: a node
   * appears because an answer carried it.
   */
  merge(probes: OriginProbe[], identities: Identity[], previous: Node[]): Node[] {
    const identityByOrigin: Map<string, Identity> = new Map<string, Identity>();
    for (const identity of identities) {
      identityByOrigin.set(identity.origin, identity);
    }
    const order: string[] = [];
    const pathsByNode: Map<string, GatewayPath[]> = new Map<string, GatewayPath[]>();
    const namesByNode: Map<string, string> = new Map<string, string>();
    for (const probe of probes) {
      if (!probe.reachable) {
        continue;
      }
      const identity: Identity | undefined = identityByOrigin.get(probe.origin);
      if (identity === undefined) {
        continue;
      }
      for (const summary of probe.nodes) {
        const path: GatewayPath = new GatewayPath(probe.origin, identity.credentialRef, true, probe.latencyMs,
          isPrivateHost(hostnameOf(probe.origin)), Date.now());
        const existing: GatewayPath[] | undefined = pathsByNode.get(summary.id);
        if (existing === undefined) {
          pathsByNode.set(summary.id, [path]);
          namesByNode.set(summary.id, summary.name);
          order.push(summary.id);
        } else {
          existing.push(path);
        }
      }
    }
    // A gateway that did not answer keeps its nodes in the list, marked as not
    // probed, so a list that was there a moment ago does not blink out of existence.
    for (const identity of identities) {
      const answered: boolean = probes.some((probe: OriginProbe) => probe.origin === identity.origin && probe.reachable);
      if (answered) {
        continue;
      }
      for (const node of previous) {
        for (const path of node.paths) {
          if (path.origin !== identity.origin) {
            continue;
          }
          const stale: GatewayPath = new GatewayPath(path.origin, path.identityRef, null, null, path.isPrivate, null);
          const existing: GatewayPath[] | undefined = pathsByNode.get(node.id);
          if (existing === undefined) {
            pathsByNode.set(node.id, [stale]);
            namesByNode.set(node.id, node.name);
            order.push(node.id);
          } else if (!existing.some((known: GatewayPath) => known.origin === path.origin)) {
            existing.push(stale);
          }
        }
      }
    }
    const merged: Node[] = [];
    for (const id of order) {
      const paths: GatewayPath[] = pathsByNode.get(id) ?? [];
      const name: string = namesByNode.get(id) ?? id;
      merged.push(this.route(new Node(id, name, paths)));
    }
    return merged;
  }

  /** The path a request for one node should take. */
  route(node: Node): Node {
    const chosen: GatewayPath | null = this.choose(node);
    return new Node(node.id, node.name, node.paths.length === 0 || chosen === null
      ? node.paths
      : [chosen].concat(node.paths.filter((path: GatewayPath) => path.origin !== chosen.origin)));
  }

  /** The chosen path: private and reachable first, then the fastest of those. */
  choose(node: Node): GatewayPath | null {
    let best: GatewayPath | null = null;
    for (const path of node.paths) {
      if (path.reachable !== true) {
        continue;
      }
      if (best === null || this.better(path, best)) {
        best = path;
      }
    }
    if (best === null) {
      return null;
    }
    // A choice made in this network environment is kept while it still works.
    const rememberedOrigin: string | undefined = this.remembered.get(node.id);
    if (rememberedOrigin !== undefined && rememberedOrigin !== best.origin) {
      for (const path of node.paths) {
        if (path.origin === rememberedOrigin && path.reachable === true) {
          return path;
        }
      }
    }
    return best;
  }

  private better(candidate: GatewayPath, current: GatewayPath): boolean {
    if (candidate.isPrivate !== current.isPrivate) {
      return candidate.isPrivate;
    }
    const candidateLatency: number = candidate.latencyMs ?? Number.MAX_SAFE_INTEGER;
    const currentLatency: number = current.latencyMs ?? Number.MAX_SAFE_INTEGER;
    if (candidateLatency !== currentLatency) {
      return candidateLatency < currentLatency;
    }
    return candidate.origin < current.origin;
  }

  /** Records the choices this environment settled on. */
  remember(routed: Node[]): void {
    for (const node of routed) {
      if (node.paths.length > 0) {
        this.remembered.set(node.id, node.paths[0].origin);
      }
    }
  }

  /**
   * Tells the selector which network it is on. A different environment forgets every
   * choice, which is what "cached per network environment" means: the same Wi-Fi keeps
   * its routes, and a change of network re-decides.
   */
  setEnvironment(key: string): void {
    if (key === this.environment) {
      return;
    }
    this.environment = key;
    this.remembered = new Map<string, string>();
  }

  environmentKey(): string {
    return this.environment;
  }
}

/** The host of an origin, port aside. */
export function hostnameOf(origin: string): string {
  const scheme: number = origin.indexOf('://');
  const authority: string = scheme < 0 ? origin : origin.substring(scheme + 3);
  const slash: number = authority.indexOf('/');
  const host: string = slash < 0 ? authority : authority.substring(0, slash);
  if (host.startsWith('[')) {
    const close: number = host.indexOf(']');
    return close < 0 ? host : host.substring(1, close);
  }
  const colon: number = host.lastIndexOf(':');
  return colon < 0 ? host : host.substring(0, colon);
}
