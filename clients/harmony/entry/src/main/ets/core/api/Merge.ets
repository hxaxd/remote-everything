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
  let host: string = hostname.toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) { host = host.substring(1,host.length - 1); }
  if (host === 'localhost') { return true; }
  if (!host.includes(':')) { const octets: number[] | null = ipv4Octets(host); return octets !== null && privateOctets(octets); }
  if (host.includes('.')) {
    const at: number = host.lastIndexOf(':');
    const octets: number[] | null = ipv4Octets(host.substring(at + 1));
    if (octets === null) { return false; }
    host = host.substring(0,at + 1) + ((octets[0] << 8) + octets[1]).toString(16) + ':' + ((octets[2] << 8) + octets[3]).toString(16);
  }
  const halves: string[] = host.split('::');
  if (halves.length > 2) { return false; }
  const left: number[] | null = ipv6Groups(halves[0]);
  const right: number[] | null = halves.length === 2 ? ipv6Groups(halves[1]) : [];
  if (left === null || right === null) { return false; }
  const missing: number = 8 - left.length - right.length;
  if (halves.length === 1 && missing !== 0 || halves.length === 2 && missing <= 0) { return false; }
  const words: number[] = left.concat(new Array<number>(missing).fill(0),right);
  if (words.slice(0,5).every((word: number) => word === 0) && words[5] === 65535) {
    return privateOctets([words[6] >> 8, words[6] & 255, words[7] >> 8, words[7] & 255]);
  }
  return words.slice(0,7).every((word: number) => word === 0) && words[7] === 1 ||
    (words[0] & 0xfe00) === 0xfc00 || (words[0] & 0xffc0) === 0xfe80;
}

function ipv4Octets(value: string): number[] | null {
  const parts: string[] = value.split('.');
  if (parts.length !== 4 || !parts.every((part: string) => /^(0|[1-9][0-9]{0,2})$/.test(part))) { return null; }
  const octets: number[] = parts.map((part: string) => Number.parseInt(part,10));
  return octets.every((part: number) => part <= 255) ? octets : null;
}

function privateOctets(octets: number[]): boolean {
  return octets[0] === 10 || octets[0] === 127 || octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31 ||
    octets[0] === 192 && octets[1] === 168 || octets[0] === 169 && octets[1] === 254;
}

function ipv6Groups(part: string): number[] | null {
  if (part === '') { return []; }
  const groups: string[] = part.split(':');
  if (!groups.every((group: string) => /^[0-9a-f]{1,4}$/.test(group))) { return null; }
  return groups.map((group: string) => Number.parseInt(group,16));
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
  for (const identity of identities) {
    const probe: OriginProbe | undefined = probes.find((candidate: OriginProbe) => candidate.origin === identity.origin && candidate.reachable);
    if (probe !== undefined) {
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
      continue;
    }
  // A gateway that did not answer keeps its nodes in the list, marked as not
  // probed, so a list that was there a moment ago does not blink out of existence.
    for (const node of previous) {
      for (const path of node.paths) {
        if (path.origin !== identity.origin) {
          continue;
        }
        const stale: GatewayPath = new GatewayPath(path.origin, path.identityRef, null, null, path.isPrivate, null, path.link);
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
