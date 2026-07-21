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

  constructor(
    installationId: string,
    name: string,
    mode: ConnectionMode,
    gatewayOrigin: string,
    gatewayFingerprint: string,
    gatewayPublicKeyPin: string
  ) {
    this.installationId = installationId;
    this.name = name;
    this.mode = mode;
    this.gatewayOrigin = gatewayOrigin;
    this.gatewayFingerprint = gatewayFingerprint;
    this.gatewayPublicKeyPin = gatewayPublicKeyPin;
  }

  get gatewayHost(): string {
    try {
      return new URL(this.gatewayOrigin).hostname;
    } catch {
      return this.gatewayOrigin;
    }
  }

  get gatewayPort(): number {
    try {
      const url = new URL(this.gatewayOrigin);
      return url.port ? parseInt(url.port) : 443;
    } catch {
      return 443;
    }
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

  isGatewayEndpoint(host: string | null, port: number): boolean {
    return host?.toLowerCase() === this.gatewayHost.toLowerCase() && port === this.gatewayPort;
  }

  isGatewayUrl(value: string): boolean {
    try {
      const url = new URL(value);
      const port = url.port ? parseInt(url.port, 10) : 443;
      return url.protocol === 'https:' && url.username === '' && url.password === '' &&
        this.isGatewayEndpoint(url.hostname, port);
    } catch {
      return false;
    }
  }
}

export enum ConnectionMode {
  LAN = 'lan',
  PUBLIC = 'public'
}
