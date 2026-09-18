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

import connection from '@ohos.net.connection';
import { BusinessError } from '@kit.BasicServicesKit';

export class NetworkEnvironment {
  private current: number = -1;
  private generation: number = 0;
  private listener: connection.NetConnection | null = null;

  /** Starts watching: every report of a change turns the generation over. */
  start(): void {
    if (this.listener !== null) {
      return;
    }
    try {
      const listener: connection.NetConnection = connection.createNetConnection();
      const changed = (): void => {
        this.generation += 1;
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

  stop(): void {
    const listener: connection.NetConnection | null = this.listener;
    if (listener === null) {
      return;
    }
    this.listener = null;
    try {
      listener.unregister((): void => {
      });
    } catch (error) {
      // Nothing registered, nothing to unregister.
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

  private defaultNetworkId(): number {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      return handle.netId;
    } catch (error) {
      return -1;
    }
  }
}
