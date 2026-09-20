import { describe, expect, it } from '@ohos/hypium';
import { webview } from '@kit.ArkWeb';
import { WebCookieRecords } from '../../../../main/ets/core/store/WebCookieRecords';
import { WebSessions } from '../../../../main/ets/app/web/WebSessions';
import { WebSessionScope } from '../../../../main/ets/core/store/WebSessionScope';
import { AtomicFile } from '../../../../main/ets/core/store/AtomicFile';

function cookie(): webview.WebHttpCookie {
  return {
    name: 'session', value: 'secret-a', domain: '.gateway.example', path: '/',
    isSessionCookie: true, expiresDate: '', isSecure: true, isHttpOnly: true,
    samesitePolicy: webview.WebHttpCookieSameSitePolicy.LAX
  };
}

export default function webSessionsTests() {
  describe('WebSessions', () => {
    it('restores_only_the_current_host_with_security_attributes', 0, () => {
      const value: webview.WebHttpCookie = cookie();
      const header: string = WebCookieRecords.header(value, Date.now()) as string;
      expect(header).assertEqual('session=secret-a; Path=/; Secure; HttpOnly; SameSite=Lax');
      expect(WebCookieRecords.belongsToHost(value, 'a.gateway.example')).assertTrue();
      expect(WebCookieRecords.belongsToHost(value, 'notgateway.example')).assertFalse();
      expect(WebCookieRecords.belongsToHost(value, 'gateway.example.attacker.test')).assertFalse();
      expect(WebCookieRecords.decode(WebCookieRecords.encode([value]))[0].value).assertEqual('secret-a');
    });

    it('expired_cookies_are_not_restored_and_injection_is_rejected', 0, () => {
      const value: webview.WebHttpCookie = cookie();
      value.isSessionCookie = false;
      value.expiresDate = 'Wed, 01 Jan 2020 00:00:00 GMT';
      expect(WebCookieRecords.header(value, Date.now())).assertNull();
      value.value = 'value; Domain=other.example';
      let refused: boolean = false;
      try { WebCookieRecords.header(value, Date.now()); } catch (error) { refused = true; }
      expect(refused).assertTrue();
    });

    it('serial_switch_saves_cookies_and_waits_for_old_context_teardown', 0, async () => {
      const gateway: string = `https://session-test-${Date.now()}.example`;
      const url: string = 'https://127.0.0.1:8443/';
      const scope: string = await WebSessions.enter(gateway, 'node/app-a', url);
      await webview.WebCookieManager.configCookie(url, 'session=private-a; Path=/; Secure; HttpOnly', true, true);
      let detach: () => void = () => {};
      let signalDestroy: () => void = () => {};
      const destroying: Promise<void> = new Promise<void>((resolve) => { signalDestroy = resolve; });
      const detached: Promise<void> = new Promise<void>((resolve) => { detach = resolve; });
      const leaving: Promise<void> = WebSessions.leave(scope, url, async () => {}, async () => {
        signalDestroy();
        await detached;
      });
      await destroying;
      let opened: boolean = false;
      const opening: Promise<string> = WebSessions.enter(gateway, 'node/app-b', url).then((key: string): string => {
        opened = true;
        return key;
      });
      await Promise.resolve();
      expect(opened).assertFalse();
      detach();
      await leaving;
      const second: string = await opening;
      expect(webview.WebCookieManager.existCookie(true)).assertFalse();
      await WebSessions.leave(second, url, async () => {}, async () => {});
      const restored: string = await WebSessions.enter(gateway, 'node/app-a', url);
      const cookies: webview.WebHttpCookie[] = await webview.WebCookieManager.fetchAllCookies(true);
      expect(cookies.find((item: webview.WebHttpCookie): boolean => item.name === 'session')?.value).assertEqual('private-a');
      await WebSessions.leave(restored, url, async () => {}, async () => {});
      AtomicFile.removeWithTemporary(`web-sessions/${scope}.sealed`);
      AtomicFile.removeWithTemporary(`web-sessions/${WebSessionScope.profileName(gateway, 'node/app-b')}.sealed`);
    });
  });
}
