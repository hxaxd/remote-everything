import { ConnectionConfig, ConnectionMode } from '../models/ConnectionConfig';
import { SetupPayload } from '../models/SetupPayload';
import { HttpsUrl } from './HttpsUrl';

/**
 * Strict parser for `remote-everything://setup` URIs.
 * Mirrors Android's `AppConfig` and the iOS `SetupParser`.
 */
export class SetupParser {
  private static readonly INSTALLATION_ID_PATTERN = /^[a-f0-9]{64}$/;
  private static readonly FINGERPRINT_PATTERN = /^[a-f0-9]{64}$/;
  private static readonly INVITATION_PATTERN = /^[A-Za-z0-9_-]{43}$/;
  private static readonly PUBLIC_KEY_PIN_PATTERN = /^[A-Za-z0-9+/]{43}=$/;

  static parse(uriString: string): SetupPayload {
    const trimmed = uriString.trim();
    const setupMatch = /^remote-everything:\/\/setup\/?\?([^#]+)$/i.exec(trimmed);
    if (setupMatch === null) {
      throw new Error('初始化链接无效');
    }

    const values = new Map<string, string>();
    // Check for duplicate keys by scanning raw query
    const rawQuery = setupMatch[1];
    const seenKeys = new Set<string>();
    for (const item of rawQuery.split('&')) {
      if (!item) continue;
      const parts = item.split('=', 2);
      if (parts.length !== 2) {
        throw new Error('初始化链接参数无效');
      }
      const key = SetupParser.decodeQueryPart(parts[0]);
      if (seenKeys.has(key)) {
        throw new Error('初始化链接包含重复参数');
      }
      seenKeys.add(key);
      values.set(key, SetupParser.decodeQueryPart(parts[1]));
    }

    if (values.get('v') !== '2') {
      throw new Error('初始化链接版本不受支持');
    }

    const mode = values.get('mode') ?? '';
    const expectedKeys = mode === 'lan'
      ? new Set(['v', 'id', 'name', 'mode', 'origin', 'fingerprint', 'public_key_pin'])
      : new Set(['v', 'id', 'name', 'mode', 'origin', 'invitation']);

    if (seenKeys.size !== expectedKeys.size ||
        !Array.from(expectedKeys).every(k => seenKeys.has(k))) {
      throw new Error('初始化链接参数不完整');
    }

    const profile = SetupParser.create(
      values.get('id') ?? '',
      values.get('name') ?? '',
      mode,
      values.get('origin') ?? '',
      values.get('fingerprint') ?? '',
      values.get('public_key_pin') ?? ''
    );

    if (mode === 'public') {
      const invitation = values.get('invitation') ?? '';
      if (!SetupParser.INVITATION_PATTERN.test(invitation)) {
        throw new Error('公网邀请无效');
      }
      return new SetupPayload(profile, invitation);
    }

    return new SetupPayload(profile, '');
  }

  static create(
    installationId: string,
    name: string,
    mode: string,
    origin: string,
    fingerprint: string = '',
    publicKeyPin: string = ''
  ): ConnectionConfig {
    if (!SetupParser.INSTALLATION_ID_PATTERN.test(installationId)) {
      throw new Error('安装实例标识无效');
    }

    const normalized = name.trim();
    // Count Unicode code points
    let codePointCount = 0;
    let hasControlChars = false;
    for (const character of normalized) {
      codePointCount += 1;
      const codePoint = character.codePointAt(0) ?? 0;
      if (codePoint < 32 || codePoint === 127) {
        hasControlChars = true;
      }
    }

    if (normalized.length === 0 || codePointCount > 80 || hasControlChars) {
      throw new Error('安装实例名称无效');
    }

    if (mode !== 'lan' && mode !== 'public') {
      throw new Error('连接模式无效');
    }

    const parsed = HttpsUrl.parse(origin.trim(), true);
    if (parsed === null) {
      throw new Error('服务地址必须是 HTTPS 源站');
    }

    const normalizedOrigin = `https://${parsed.authority}`;

    let normalizedFingerprint = fingerprint
      .toLowerCase()
      .replace(/:/g, '')
      .replace(/\s/g, '');

    const configMode: ConnectionMode = mode === 'lan' ? ConnectionMode.LAN : ConnectionMode.PUBLIC;
    if (configMode === ConnectionMode.LAN) {
      if (!SetupParser.FINGERPRINT_PATTERN.test(normalizedFingerprint)) {
        throw new Error('局域网服务证书指纹无效');
      }
      if (!SetupParser.PUBLIC_KEY_PIN_PATTERN.test(publicKeyPin)) {
        throw new Error('局域网服务公钥摘要无效');
      }
    }

    return new ConnectionConfig(
      installationId, normalized, configMode,
      normalizedOrigin,
      configMode === ConnectionMode.LAN ? normalizedFingerprint : '',
      configMode === ConnectionMode.LAN ? publicKeyPin : ''
    );
  }

  private static decodeQueryPart(value: string): string {
    return decodeURIComponent(value.replace(/\+/g, ' '));
  }
}
