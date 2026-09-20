import { sha256HexOfText } from '../model/Digest';

export class WebSessionScope {
  static profileName(gatewayOrigin: string, appKey: string): string {
    if (gatewayOrigin.length === 0 || appKey.length === 0 || gatewayOrigin.includes('\n') || appKey.includes('\n')) {
      throw new Error('invalid application session scope');
    }
    return `app-${sha256HexOfText(`remote-everything:web-session\n${gatewayOrigin}\n${appKey}`)}`;
  }
}
