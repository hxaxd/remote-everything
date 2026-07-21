/**
 * An application registered on the node. Mirrors Android's `RemoteApp`.
 */
export class RemoteApp {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly icon: string;
  readonly accent: string;
  readonly openUrl: string;
  readonly code: AppCode;

  constructor(
    id: string, name: string, description: string,
    icon: string, accent: string, openUrl: string, code: AppCode
  ) {
    this.id = id;
    this.name = name;
    this.description = description;
    this.icon = icon;
    this.accent = accent;
    this.openUrl = openUrl;
    this.code = code;
  }
}

export enum AppCode {
  READY = 'ready',
  STARTING = 'starting',
  STOPPING = 'stopping',
  STOPPED = 'stopped'
}

/**
 * A catalog snapshot returned by the gateway. Mirrors Android's `CatalogSnapshot`.
 */
export class CatalogSnapshot {
  readonly computerConnected: boolean;
  readonly code: string;
  readonly apps: RemoteApp[];

  constructor(computerConnected: boolean, code: string, apps: RemoteApp[]) {
    this.computerConnected = computerConnected;
    this.code = code;
    this.apps = apps;
  }
}
