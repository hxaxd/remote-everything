import { HttpsUrl } from '../network/HttpsUrl';

/**
 * A saved connection profile. Mirrors Android's `ConnectionConfig`.
 */
export class ConnectionConfig {
  readonly installationId: string;
  readonly name: string;
  readonly mode: ConnectionMode;
  readonly gatewayOrigin: string;
  readonly gatewayFingerprint: string;
  readonly gatewayPublicKeyPin: string;
  readonly accessToken: string;

  constructor(
    installationId: string,
    name: string,
    mode: ConnectionMode,
    gatewayOrigin: string,
    gatewayFingerprint: string,
    gatewayPublicKeyPin: string,
    accessToken: string = ''
  ) {
    this.installationId = installationId;
    this.name = name;
    this.mode = mode;
    this.gatewayOrigin = gatewayOrigin;
    this.gatewayFingerprint = gatewayFingerprint;
    this.gatewayPublicKeyPin = gatewayPublicKeyPin;
    this.accessToken = accessToken;
  }

  get gatewayHost(): string {
    return HttpsUrl.parse(this.gatewayOrigin, true)?.host ?? this.gatewayOrigin;
  }

  get gatewayPort(): number {
    return HttpsUrl.parse(this.gatewayOrigin, true)?.port ?? 443;
  }

  get pairUrl(): string { return `${this.gatewayOrigin}/__remote_everything_pair`; }
  get activateUrl(): string { return `${this.gatewayOrigin}/__remote_everything_activate`; }
  get appsUrl(): string { return `${this.gatewayOrigin}/__remote_everything/apps`; }

  appActionUrl(id: string, action: string): string {
    return `${this.appsUrl}/${id}/${action}`;
  }

  appOpenUrl(id: string): string {
    return `${this.gatewayOrigin}/__remote_everything/open/${id}`;
  }

  authorizationHeaders(): Record<string, string> {
    if (this.mode === ConnectionMode.LAN && this.accessToken.length > 0) {
      return { 'Authorization': `Bearer ${this.accessToken}` };
    }
    return {};
  }

  isGatewayEndpoint(host: string | null, port: number): boolean {
    return host?.toLowerCase() === this.gatewayHost.toLowerCase() && port === this.gatewayPort;
  }

  isGatewayUrl(value: string): boolean {
    const parsed = HttpsUrl.parse(value);
    return parsed !== null && this.isGatewayEndpoint(parsed.host, parsed.port);
  }
}

export enum ConnectionMode {
  LAN = 'lan',
  PUBLIC = 'public'
}
