import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ConnectionConfig } from '../models/ConnectionConfig';

/**
 * Certificate pinning, fingerprint calculation, and host validation.
 * Mirrors Android's `GatewaySecurityPolicy` and iOS equivalent.
 */
export class GatewaySecurityPolicy {

  /**
   * Compute SHA-256 fingerprint of a certificate's DER data, as lowercase hex.
   * Mirrors Android's `fingerprint()`.
   */
  static async fingerprint(certData: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    const hash = await md.digest({ data: certData });
    let hex = '';
    for (let i = 0; i < hash.data.length; i++) {
      hex += hash.data[i].toString(16).padStart(2, '0');
    }
    return hex;
  }

  /**
   * Verify that a URL is within the gateway's origin.
   */
  static isGatewayOrigin(url: string, config: ConnectionConfig): boolean {
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== 'https:') {
        return false;
      }
      const port = parsed.port ? parseInt(parsed.port) : 443;
      return config.isGatewayEndpoint(parsed.hostname, port);
    } catch {
      return false;
    }
  }

  /**
   * Determine whether to offer a client certificate for a given challenge.
   * Only for public mode, only when identity is available, only for the gateway host/port.
   */
  static allowsClientCertificate(
    config: ConnectionConfig,
    identityPresent: boolean,
    host: string | null,
    port: number
  ): boolean {
    return config.mode === 'public' && identityPresent &&
      config.isGatewayEndpoint(host, port);
  }
}
