import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/**
 * Determines Web component data isolation and routing cookies.
 * Mirrors Android's `WebIsolationPolicy` and iOS equivalent.
 */
export class WebIsolationPolicy {
  /**
   * Generate a stable profile identifier for ArkWeb data isolation.
   * SHA-256(installationId + NUL + appId) → hex string.
   */
  static async profileIdentifier(installationId: string, appId: string): Promise<string> {
    const input = new util.TextEncoder().encodeInto(`${installationId}\0${appId}`);
    const digest = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: input });
    const output = digest.digestSync();
    let identifier = '';
    for (let index = 0; index < output.data.length; index++) {
      identifier += output.data[index].toString(16).padStart(2, '0');
    }
    return identifier;
  }

  /**
   * The routing cookie set before first navigation.
   */
  static routingCookie(appId: string): RoutingCookie {
    return {
      name: 'RemoteEverythingApp',
      value: appId,
      path: '/',
      secure: true
    };
  }
}

interface RoutingCookie {
  name: string;
  value: string;
  path: string;
  secure: boolean;
}
