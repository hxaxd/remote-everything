// Which way to reach a node: pure path selection according to ui-contract §4.
//
// What this decides:
//   * a reachable path whose origin is a private address beats one that is not,
//     because it is the one that does not leave the local network;
//   * among equals, the one that answered fastest;
//   * and the choice is remembered per network environment, so a list that is
//     refreshed twice on the same Wi-Fi does not silently move traffic to a slower
//     route.

import { GatewayPath, Node } from '../model/Models';
export { OriginProbe, isPrivateHost, isPrivateOrigin, mergeNodes } from '../api/Merge';
export { hostnameOf } from '../api/Origins';

/** A node and the path a request for it should take. */
export class RoutedNode {
  readonly node: Node;
  readonly chosen: GatewayPath | null;

  constructor(node: Node, chosen: GatewayPath | null) {
    this.node = node;
    this.chosen = chosen;
  }
}

/** Pure path selector: picks preferred path and tracks network-scoped cache. */
export class PathSelector {
  private environment: string = '';
  private remembered: Map<string, string> = new Map<string, string>();

  constructor() {}

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

  /** Invalidate the choice for a single node (e.g. after a request failure). */
  invalidate(nodeId: string): void {
    this.remembered.delete(nodeId);
  }

  /** Reset all cached choices. */
  reset(): void {
    this.remembered.clear();
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
