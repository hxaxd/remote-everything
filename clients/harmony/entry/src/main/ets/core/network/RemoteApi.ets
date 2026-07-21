import { ConnectionConfig } from '../models/ConnectionConfig';
import { RemoteApp, AppCode, CatalogSnapshot } from '../models/RemoteApp';
import { PairingCredential } from '../models/PairingCredential';

/**
 * Strict API decoder for gateway responses.
 * Mirrors Android's `RemoteApi` and iOS `RemoteAPI`.
 */
export class RemoteApi {
  private static readonly APP_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/;
  private static readonly FINGERPRINT_PATTERN = /^[a-f0-9]{64}$/;
  private static readonly ACCENT_PATTERN = /^#[0-9A-Fa-f]{6}$/;

  private static readonly CATALOG_KEYS = new Set(['ok', 'computer_connected', 'code', 'apps']);
  private static readonly APP_KEYS = new Set([
    'id', 'name', 'description', 'icon', 'accent',
    'launch_fragment', 'computer_connected', 'enabled', 'running', 'code'
  ]);
  private static readonly PAIRING_KEYS = new Set([
    'ok', 'device_name', 'certificate_fingerprint',
    'credential_format', 'credential_pkcs12', 'pending_expires_at'
  ]);
  private static readonly ACTION_KEYS = new Set([
    'ok', 'action', 'computer_connected', 'enabled', 'running', 'code'
  ]);

  static decodeCatalog(config: ConnectionConfig, payload: object): CatalogSnapshot {
    const json = payload as Record<string, Object>;
    const keys = new Set(Object.keys(json));

    if (!RemoteApi.setsEqual(keys, RemoteApi.CATALOG_KEYS)) {
      throw new Error('目录响应字段无效');
    }
    if (json['ok'] !== true) {
      throw new Error(json['code'] as string ?? 'unknown');
    }

    const connected = json['computer_connected'] === true;
    const code = json['code'] as string ?? '';
    const rawApps = json['apps'] as Array<Object>;

    if (!Array.isArray(rawApps)) {
      throw new Error('目录响应缺少 apps');
    }

    const ids = new Set<string>();
    const apps: RemoteApp[] = [];

    for (const appJson of rawApps) {
      const app = RemoteApi.decodeApp(config, appJson as Record<string, Object>);
      if (ids.has(app.id)) {
        throw new Error('应用目录 ID 重复');
      }
      ids.add(app.id);
      apps.push(app);
    }

    if (connected) {
      if (code !== 'ready') {
        throw new Error('目录连接状态无效');
      }
    } else {
      if (code !== 'computer_offline' || apps.length > 0) {
        throw new Error('目录连接状态无效');
      }
    }

    return new CatalogSnapshot(connected, code, apps);
  }

  private static decodeApp(config: ConnectionConfig, json: Record<string, Object>): RemoteApp {
    const keys = new Set(Object.keys(json));
    if (!RemoteApi.setsEqual(keys, RemoteApi.APP_KEYS)) {
      throw new Error('应用目录字段无效');
    }

    const id = json['id'] as string ?? '';
    const name = json['name'] as string ?? '';
    const description = json['description'] as string ?? '';
    const icon = json['icon'] as string ?? '';
    const accent = json['accent'] as string ?? '';
    const launchFragment = json['launch_fragment'] as string ?? '';
    const connected = json['computer_connected'] === true;
    const enabled = json['enabled'] === true;
    const running = json['running'] === true;
    const code = json['code'] as string ?? '';

    const expectedCode = enabled
      ? (running ? 'ready' : 'starting')
      : (running ? 'stopping' : 'stopped');

    if (!RemoteApi.APP_ID_PATTERN.test(id) ||
        !RemoteApi.validMetadata(name, 80, false) ||
        !RemoteApi.validMetadata(description, 240, true) ||
        !RemoteApi.validMetadata(icon, 4, true) ||
        !RemoteApi.ACCENT_PATTERN.test(accent) ||
        !(launchFragment.length === 0 || (launchFragment.startsWith('#') && RemoteApi.validMetadata(launchFragment, 2048, false))) ||
        !connected ||
        code !== expectedCode) {
      throw new Error('应用目录内容无效');
    }

    return new RemoteApp(
      id, name, description, icon, accent,
      config.appOpenUrl(id) + launchFragment,
      code as AppCode
    );
  }

  static decodePairingCredential(payload: object): PairingCredential {
    const json = payload as Record<string, Object>;
    const keys = new Set(Object.keys(json));

    if (!RemoteApi.setsEqual(keys, RemoteApi.PAIRING_KEYS) || json['ok'] !== true) {
      throw new Error('配对响应字段无效');
    }

    const deviceName = (json['device_name'] as string ?? '').trim();
    if (deviceName.length === 0) {
      throw new Error('配对设备名无效');
    }

    const certFingerprint = json['certificate_fingerprint'] as string ?? '';
    if (!RemoteApi.FINGERPRINT_PATTERN.test(certFingerprint)) {
      throw new Error('配对证书指纹无效');
    }

    const format = json['credential_format'] as string ?? '';
    if (format !== 'pkcs12') {
      throw new Error('配对凭据格式无效');
    }

    const expiresAt = json['pending_expires_at'] as string ?? '';
    // Validate ISO 8601
    if (isNaN(Date.parse(expiresAt))) {
      throw new Error('配对期限无效');
    }

    const encoded = json['credential_pkcs12'] as string ?? '';
    if (encoded.length === 0) {
      throw new Error('配对凭据为空');
    }

    return new PairingCredential(encoded, certFingerprint, expiresAt);
  }

  static decodeAction(
    config: ConnectionConfig,
    expectedAction: string,
    payload: object
  ): boolean {
    const json = payload as Record<string, Object>;
    const keys = new Set(Object.keys(json));

    const validKeySets = [
      RemoteApi.ACTION_KEYS,
      new Set([...RemoteApi.ACTION_KEYS, 'app']),
      new Set([...RemoteApi.ACTION_KEYS, 'app', 'error_code'])
    ];
    const hasValidKeys = validKeySets.some(s => RemoteApi.setsEqual(keys, s));
    if (!hasValidKeys) {
      throw new Error('控制响应字段无效');
    }

    const ok = json['ok'] === true;
    const action = json['action'] as string ?? '';
    const connected = json['computer_connected'] === true;
    const enabled = json['enabled'] === true;
    const running = json['running'] === true;
    const code = json['code'] as string ?? '';

    if (action !== expectedAction) {
      throw new Error('控制动作无效');
    }

    if (!connected) {
      if (ok || enabled || running || code !== 'computer_offline' || json['app'] !== undefined) {
        throw new Error('离线控制响应无效');
      }
      return false;
    }

    const appJson = json['app'] as Record<string, Object> | undefined;
    if (appJson === undefined) {
      if (ok || enabled || running || !['app_not_found', 'state_update_failed'].includes(code)) {
        throw new Error('失败控制响应无效');
      }
      return false;
    }

    const app = RemoteApi.decodeApp(config, appJson);
    const appEnabled = appJson['enabled'] === true;
    const appRunning = appJson['running'] === true;
    const appCode = appJson['code'] as string ?? '';

    if (enabled !== appEnabled || running !== appRunning || code !== appCode) {
      throw new Error('控制状态不一致');
    }

    if (json['error_code'] !== undefined) {
      if (ok || json['error_code'] !== 'stop_command_failed') {
        throw new Error('控制错误无效');
      }
    } else {
      if (!ok) {
        throw new Error('控制结果无效');
      }
    }

    return ok;
  }

  private static validMetadata(value: string, max: number, allowEmpty: boolean): boolean {
    if (value.trim() !== value) return false;
    if (!allowEmpty && value.length === 0) return false;
    const codePointCount = [...value].length;
    if (codePointCount > max) return false;
    return ![...value].some(c => {
      const cp = c.codePointAt(0) ?? 0;
      return cp < 32 || cp === 127;
    });
  }

  private static setsEqual(a: Set<string>, b: Set<string>): boolean {
    return a.size === b.size && Array.from(a).every(x => b.has(x));
  }
}
