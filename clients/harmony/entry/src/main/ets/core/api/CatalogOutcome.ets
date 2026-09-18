import { AppInfo } from '../model/Models';
import { CatalogAnswer } from './Dto';
import { ClientError, ErrorCode } from '../model/Errors';

export enum CatalogOutcomeKind {
  Apps = 'apps',
  Offline = 'offline',
  Unauthorized = 'unauthorized',
  GatewayTrouble = 'gateway_trouble'
}

export class CatalogOutcome {
  readonly kind: CatalogOutcomeKind;
  readonly apps: AppInfo[];

  constructor(kind: CatalogOutcomeKind, apps: AppInfo[] = []) {
    this.kind = kind;
    this.apps = apps;
  }

  static apps(apps: AppInfo[]): CatalogOutcome {
    return new CatalogOutcome(CatalogOutcomeKind.Apps, apps);
  }

  static offline(): CatalogOutcome {
    return new CatalogOutcome(CatalogOutcomeKind.Offline);
  }

  static unauthorized(): CatalogOutcome {
    return new CatalogOutcome(CatalogOutcomeKind.Unauthorized);
  }

  static gatewayTrouble(): CatalogOutcome {
    return new CatalogOutcome(CatalogOutcomeKind.GatewayTrouble);
  }

  static forAnswer(answer: CatalogAnswer): CatalogOutcome {
    if (!answer.computerConnected || answer.code === 'computer_offline') {
      return CatalogOutcome.offline();
    }
    return CatalogOutcome.apps(answer.apps);
  }

  static forRefusal(error: ClientError): CatalogOutcome {
    if (error.code === ErrorCode.Unauthorized || error.code === ErrorCode.NodeNotFound ||
      error.code === ErrorCode.NodeRequired) {
      return CatalogOutcome.unauthorized();
    }
    if (error.code === ErrorCode.ComputerOffline) {
      return CatalogOutcome.offline();
    }
    return CatalogOutcome.gatewayTrouble();
  }
}
