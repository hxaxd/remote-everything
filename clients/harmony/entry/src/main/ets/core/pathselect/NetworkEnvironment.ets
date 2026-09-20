// Which network this device is on.
//
// The path selectors' choices are kept per environment: the same network keeps the
// routes it settled on, and a change of network re-decides (ui-contract §4). A Wi-Fi
// name would be the natural key, but reading one needs the location permission, which
// this client does not ask for and will not — an app that only ever talks to the
// gateways you added has no business knowing where you are. So the environment is the
// network the platform says is in use, plus a counter that turns over whenever the
// platform reports that connectivity changed: "any change of network invalidates",
// which is the rule ui-contract §4 gives for exactly this case.

import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class NetworkEnvironment {
  private current: number = -1;
  private generation: number = 0;
  private listener: connection.NetConnection | null = null;

  /** Told whenever the platform reports the network changed. */
  onNetworkChange?: () => void;

  /** Starts watching: every report of a change turns the generation over. */
  start(): void {
    if (this.listener !== null) {
      return;
    }
    try {
      const listener: connection.NetConnection = connection.createNetConnection();
      const changed = (): void => {
        this.generation += 1;
        if (this.onNetworkChange !== undefined) {
          this.onNetworkChange();
        }
      };
      listener.on('netAvailable', changed);
      listener.on('netLost', changed);
      listener.on('netCapabilitiesChange', changed);
      listener.register((error: BusinessError) => {
        if (error !== undefined) {
          this.generation += 1;
        }
      });
      this.listener = listener;
    } catch (error) {
      // Without the events the key still follows the current network, which is the
      // part that matters.
      this.listener = null;
    }
  }

  /**
   * A key that stays the same while the network does. It changes when the default
   * network changes and when the platform says connectivity did.
   */
  key(): string {
    const netId: number = this.defaultNetworkId();
    if (netId !== this.current) {
      this.current = netId;
      this.generation += 1;
    }
    return `${netId}.${this.generation}`;
  }

  /** Nothing to send on at all: every connection fails the same way, and this says why. */
  offline(): boolean {
    try {
      return !connection.hasDefaultNetSync();
    } catch (error) {
      // A platform that will not answer the question is not one to claim offline on.
      return false;
    }
  }

  /**
   * The network as a report should print it. Tokens rather than prose, because a
   * reader who has the device in hand reads `wifi · internet ✓ · vpn ✗` faster
   * than a sentence — and the marks do not need translating.
   */
  describe(): string {
    if (this.defaultNetworkId() <= 0) {
      return 'offline';
    }
    let capabilities: connection.NetCapabilities | null = null;
    try {
      capabilities = connection.getNetCapabilitiesSync(connection.getDefaultNetSync());
    } catch (error) {
      capabilities = null;
    }
    if (capabilities === null) {
      return 'unknown';
    }
    return `${bearerName(capabilities.bearerTypes)} · internet ${capabilityMark(capabilities.networkCap,
      connection.NetCap.NET_CAPABILITY_VALIDATED)} · vpn ${bearerMark(capabilities.bearerTypes,
      connection.NetBearType.BEARER_VPN)}`;
  }

  private defaultNetworkId(): number {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      return handle.netId;
    } catch (error) {
      return -1;
    }
  }
}

/** The transport this network uses, in one word. */
function bearerName(bearers: connection.NetBearType[]): string {
  if (bearers.includes(connection.NetBearType.BEARER_WIFI)) {
    return 'wifi';
  }
  if (bearers.includes(connection.NetBearType.BEARER_CELLULAR)) {
    return 'cellular';
  }
  if (bearers.includes(connection.NetBearType.BEARER_ETHERNET)) {
    return 'ethernet';
  }
  if (bearers.includes(connection.NetBearType.BEARER_VPN)) {
    return 'vpn';
  }
  return 'other';
}

/** Whether the network carries this, as a mark that needs no translating. */
function capabilityMark(values: connection.NetCap[] | undefined, value: connection.NetCap): string {
  if (values === undefined) {
    return '✗';
  }
  return values.includes(value) ? '✓' : '✗';
}

/** Whether the network is carried over this bearer, as a mark that needs no translating. */
function bearerMark(values: connection.NetBearType[] | undefined, value: connection.NetBearType): string {
  if (values === undefined) {
    return '✗';
  }
  return values.includes(value) ? '✓' : '✗';
}
