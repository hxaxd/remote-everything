// Deciding whether a client certificate challenge should be answered.
//
// A device certificate is only ever presented to the gateway that issued it,
// and to application origins served under that gateway's origin or domain.
// An unexpected host never receives the certificate.

import { belongsToGateway } from '../api/ProtocolClient';
import { DEFAULT_TLS_PORT, hostOf, portOf } from '../api/Origins';

export const PORT_UNKNOWN = 0;
export const PORT_OMITTED = -1;

export class ClientAuthPolicy {
  /**
   * Whether the host is one this gateway serves: its own, the application origin it
   * answered with, or a host inside its domain.
   */
  static isKnownApplicationHost(gatewayOrigin: string, sessionUrl: string, host: string): boolean {
    if (host === hostOf(gatewayOrigin) || host === hostOf(sessionUrl)) {
      return true;
    }
    return belongsToGateway(gatewayOrigin, `https://${host}`);
  }

  /**
   * The port a challenge names, compared against the gateway or application session:
   * a port the platform omitted, one it reports as unknown, and the default one
   * are the same thing. On a LAN, applications run on their own distinct ports.
   */
  static portMatches(port: number, gatewayOrigin: string, sessionUrl: string): boolean {
    const gatewayPort: number = portOf(gatewayOrigin);
    const sessionPort: number = portOf(sessionUrl);
    if (gatewayPort === DEFAULT_TLS_PORT || sessionPort === DEFAULT_TLS_PORT) {
      return true;
    }
    if (port === PORT_UNKNOWN || port === PORT_OMITTED) {
      return true;
    }
    return port === gatewayPort || port === sessionPort;
  }

  /** Whether the client certificate should be presented for a given challenge. */
  static shouldPresent(gatewayOrigin: string, sessionUrl: string, host: string, port: number): boolean {
    return ClientAuthPolicy.isKnownApplicationHost(gatewayOrigin, sessionUrl, host) &&
      ClientAuthPolicy.portMatches(port, gatewayOrigin, sessionUrl);
  }
}
