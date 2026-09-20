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
    // A choice made in this network environment is kept while it still works and
    // while it is still the best class there is: remembering is what stops a poll
    // from flapping between two tunnels, but it is not a reason to keep going out
    // to the internet after the phone has walked into the same room as the gateway.
    const rememberedOrigin: string | undefined = this.remembered.get(node.id);
    if (rememberedOrigin !== undefined && rememberedOrigin !== best.origin) {
      for (const path of node.paths) {
        if (path.origin === rememberedOrigin && path.reachable === true) {
          if (path.isPrivate === best.isPrivate) {
            return path;
          }
          break;
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
    // A tie keeps the road that came first in the list, the way the other
    // clients read the same paths — an origin's name is not a route.
    return false;
  }

  /** Forgets which road one node was on: it stopped answering, or the network moved. */
  forget(nodeId: string): void {
    this.remembered.delete(nodeId);
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
}
