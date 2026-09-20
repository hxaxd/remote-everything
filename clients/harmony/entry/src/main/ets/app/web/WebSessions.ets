import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { AtomicFile } from '../../core/store/AtomicFile';
import { HuksVault, SealedCredential } from '../../core/identity/HuksVault';
import { utf8, wipe } from '../../core/model/Digest';
import { WebCookieRecords } from '../../core/store/WebCookieRecords';
import { WebSessionScope } from '../../core/store/WebSessionScope';
import { hostOf } from '../../core/api/Origins';
import { WebDownloads } from './WebDownloads';

const SEAL_ALIAS: string = 'remote-everything-web-cookies';

/** A single private browser context is leased to one application until teardown completes. */
export class WebSessions {
  private static active: string = '';
  private static poisoned: boolean = false;
  private static transition: Promise<void> = Promise.resolve();
  private static initialised: boolean = false;

  static async enter(gatewayOrigin: string, appKey: string, url: string): Promise<string> {
    const scope: string = WebSessionScope.profileName(gatewayOrigin, appKey);
    const previous: Promise<void> = WebSessions.transition;
    const operation: Promise<void> = previous.then(async () => {
      if (WebSessions.poisoned || WebSessions.active !== '') { throw new Error('application session unavailable'); }
      WebSessions.active = scope;
      try {
        webview.WebviewController.setWebDestroyMode(webview.WebDestroyMode.FAST_MODE);
        if (!WebSessions.initialised) {
          await webview.WebCookieManager.clearAllCookies();
          WebSessions.initialised = true;
        }
        webview.WebCookieManager.clearAllCookiesSync(true);
        if (webview.WebCookieManager.existCookie(true)) { throw new Error('private cookies could not be cleared'); }
        const file: string = `web-sessions/${scope}.sealed`;
        if (AtomicFile.exists(file)) {
          const sealed: Uint8Array | null = AtomicFile.readBytes(file);
          if (sealed === null) { throw new Error('saved application session is unreadable'); }
          const opened: SealedCredential = await new HuksVault().unseal(SEAL_ALIAS, utf8(scope), sealed);
          try {
            const cookies: webview.WebHttpCookie[] = WebCookieRecords.decode(new util.TextDecoder().decodeToString(opened.archive));
            for (const cookie of cookies) {
              if (!WebCookieRecords.belongsToHost(cookie, hostOf(url))) { continue; }
              const header: string | null = WebCookieRecords.header(cookie, Date.now());
              if (header !== null) {
                await webview.WebCookieManager.configCookie(url, header, true, true);
              }
            }
          } finally { opened.wipe(); }
        }
        WebDownloads.allowSession();
      } catch (error) {
        WebSessions.poisoned = true;
        webview.WebCookieManager.clearAllCookiesSync(true);
        throw new Error('application session restore failed');
      }
    });
    WebSessions.transition = operation.catch(() => {});
    await operation;
    return scope;
  }

  static async leave(scope: string, url: string, freeze: () => Promise<void>, destroy: () => Promise<void>): Promise<void> {
    const previous: Promise<void> = WebSessions.transition;
    const operation: Promise<void> = previous.then(async () => {
      if (scope !== WebSessions.active || scope === '') { return; }
      try {
        WebDownloads.stopSession();
        await freeze();
        const cookies: webview.WebHttpCookie[] = (await webview.WebCookieManager.fetchAllCookies(true))
          .filter((cookie: webview.WebHttpCookie): boolean => WebCookieRecords.belongsToHost(cookie, hostOf(url)));
        const data: Uint8Array = utf8(WebCookieRecords.encode(cookies));
        try {
          const sealed: Uint8Array = await new HuksVault().seal(SEAL_ALIAS, utf8(scope), '', data);
          AtomicFile.ensureDirectory('web-sessions');
          AtomicFile.writeBytesAtomic(`web-sessions/${scope}.sealed`, sealed);
        } finally { wipe(data); }
      } catch (error) {
        WebSessions.poisoned = true;
        throw new Error('application session snapshot failed');
      } finally {
        try {
          await destroy();
          webview.WebCookieManager.clearAllCookiesSync(true);
          if (webview.WebCookieManager.existCookie(true)) { throw new Error('private cookies survived teardown'); }
          WebSessions.active = '';
        } catch (error) {
          WebSessions.poisoned = true;
          throw new Error('application session teardown failed');
        }
      }
    });
    WebSessions.transition = operation.catch(() => {});
    await operation;
  }
}
