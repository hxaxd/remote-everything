import { webview } from '@kit.ArkWeb';
import { JsonReader } from '../json/Strict';

/** Only the current application host receives a restored cookie. */
export class WebCookieRecords {
  static belongsToHost(cookie: webview.WebHttpCookie, host: string): boolean {
    const domain: string = cookie.domain.toLowerCase().replace(/^\./, '');
    return domain.length > 0 && (host === domain || host.endsWith(`.${domain}`));
  }

  static header(cookie: webview.WebHttpCookie, now: number): string | null {
    if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(cookie.name) || cookie.name.length > 256 ||
      /[\x00-\x20;\x7f]/.test(cookie.value) || cookie.value.length > 4096 ||
      !cookie.path.startsWith('/') || /[\r\n;]/.test(cookie.path) || cookie.path.length > 2048) {
      throw new Error('invalid saved application cookie');
    }
    let value: string = `${cookie.name}=${cookie.value}; Path=${cookie.path}`;
    if (!cookie.isSessionCookie) {
      const expiry: number = Date.parse(cookie.expiresDate);
      if (!Number.isFinite(expiry)) {
        throw new Error('invalid saved cookie expiry');
      }
      if (expiry <= now) {
        return null;
      }
      value += `; Expires=${new Date(expiry).toUTCString()}`;
    }
    if (cookie.isSecure) { value += '; Secure'; }
    if (cookie.isHttpOnly) { value += '; HttpOnly'; }
    if (cookie.samesitePolicy === webview.WebHttpCookieSameSitePolicy.NONE) {
      value += '; SameSite=None';
    } else if (cookie.samesitePolicy === webview.WebHttpCookieSameSitePolicy.LAX) {
      value += '; SameSite=Lax';
    } else if (cookie.samesitePolicy === webview.WebHttpCookieSameSitePolicy.STRICT) {
      value += '; SameSite=Strict';
    } else {
      throw new Error('invalid saved cookie policy');
    }
    return value;
  }

  static decode(text: string): webview.WebHttpCookie[] {
    if (text.length > 65536) { throw new Error('application cookies exceed storage limit'); }
    const root: JsonReader = JsonReader.parse(text, 'application cookies');
    root.rejectUnknown(['cookies']);
    const rows: Object[] = root.array('cookies');
    if (rows.length > 256) { throw new Error('too many application cookies'); }
    return rows.map((value: Object): webview.WebHttpCookie => {
      const row: JsonReader = JsonReader.of(value, 'cookie');
      row.rejectUnknown(['samesitePolicy', 'expiresDate', 'name', 'isSessionCookie', 'value', 'path', 'isHttpOnly',
        'isSecure', 'domain']);
      const cookie: webview.WebHttpCookie = {
        samesitePolicy: row.number('samesitePolicy'), expiresDate: row.string('expiresDate'),
        name: row.string('name'), isSessionCookie: row.bool('isSessionCookie'), value: row.string('value'),
        path: row.string('path'), isHttpOnly: row.bool('isHttpOnly'), isSecure: row.bool('isSecure'),
        domain: row.string('domain')
      };
      WebCookieRecords.header(cookie, Date.now());
      return cookie;
    });
  }

  static encode(cookies: webview.WebHttpCookie[]): string {
    const result: string = JSON.stringify({ cookies: cookies });
    WebCookieRecords.decode(result);
    return result;
  }
}
