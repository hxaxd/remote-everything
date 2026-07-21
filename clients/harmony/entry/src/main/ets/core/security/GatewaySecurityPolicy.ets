import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ConnectionConfig } from '../models/ConnectionConfig';
import { HttpsUrl } from '../network/HttpsUrl';

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
    await md.update({ data: certData });
    const hash = await md.digest();
    return GatewaySecurityPolicy.formatFingerprint(hash.data);
  }

  /** Format digest bytes without depending on the device crypto provider. */
  static formatFingerprint(hash: Uint8Array): string {
    let hex = '';
    for (let i = 0; i < hash.length; i++) {
      hex += hash[i].toString(16).padStart(2, '0');
    }
    return hex;
  }

  /**
   * Verify that a URL is within the gateway's origin.
   */
  static isGatewayOrigin(value: string, config: ConnectionConfig): boolean {
    const parsed = HttpsUrl.parse(value);
    return parsed !== null && config.isGatewayEndpoint(parsed.host, parsed.port);
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
