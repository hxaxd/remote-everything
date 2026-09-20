import { GatewayPath, Identity, LinkKind, Node } from '../model/Models';
import { NodeSummary, NodesAnswer } from './Dto';
import { ClientError } from '../model/Errors';
import { hostnameOf } from './Origins';

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
      (first === 169 && second === 254) || first === 127) {
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

export function isPrivateOrigin(origin: string): boolean {
  return isPrivateHost(hostnameOf(origin));
}

/**
 * Merges what the gateways answered into one list, keyed by node id.
 * Nodes are never added or removed here: a node appears because an answer carried it.
 */
export function mergeNodes(probes: OriginProbe[], identities: Identity[], previous: Node[]): Node[] {
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
        isPrivateHost(hostnameOf(probe.origin)), null,
        // A gateway that declared how it reaches the node is believed; one that said
        // nothing leaves the client to judge by the address it dials. Either way a
        // path that leaves the local network reads as a tunnel, because that is what
        // it costs the person using it.
        summary.link === 'tunnel' || !isPrivateHost(hostnameOf(probe.origin))
          ? LinkKind.Tunnel : LinkKind.Local);
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
    merged.push(new Node(id, name, paths));
  }
  return merged;
}
