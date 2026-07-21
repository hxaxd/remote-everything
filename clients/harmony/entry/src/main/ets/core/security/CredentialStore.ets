import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { cert } from '@kit.DeviceCertificateKit';
import { fileIo } from '@kit.CoreFileKit';
import { asset } from '@kit.AssetStoreKit';

type CredentialState = 'pending' | 'active';

export interface ClientIdentity {
  certPath: string;
  keyPath: string;
  password: string;
  privateKeyPath: string;
  certificateChainPath: string;
}

/**
 * Keeps the PKCS#12 file in the application's private sandbox and its password
 * in Asset Store. Pending and active identities are deliberately separate so a
 * failed activation cannot destroy a previously committed identity.
 */
export class CredentialStore {
  private static readonly ALIAS_PREFIX = 'com.remoteeverything.credential';
  private static readonly MAXIMUM_P12_BYTES = 1024 * 1024;
  private static filesDir: string = '';
  private static cacheDir: string = '';

  static configure(context: common.UIAbilityContext): void {
    CredentialStore.filesDir = context.filesDir;
    CredentialStore.cacheDir = context.cacheDir;
  }

  static async credentialPassword(installationId: string): Promise<string> {
    CredentialStore.requireConfigured();
    const alias = CredentialStore.passwordAlias(installationId, 'pending');
    const existing = await CredentialStore.loadSecret(alias);
    if (existing !== null) {
      return existing;
    }

    const random = cryptoFramework.createRandom().generateRandomSync(24);
    const base64 = new util.Base64Helper().encodeToStringSync(random.data);
    const password = base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
    await CredentialStore.storeSecret(alias, password);
    return password;
  }

  static async stageCredential(
    installationId: string,
    encoded: string,
    password: string,
    expectedFingerprint: string
  ): Promise<void> {
    CredentialStore.requireConfigured();
    let p12Data: Uint8Array;
    try {
      p12Data = new util.Base64Helper().decodeSync(encoded);
    } catch {
      throw new Error('PKCS#12 数据无效');
    }
    if (p12Data.length === 0 || p12Data.length > CredentialStore.MAXIMUM_P12_BYTES) {
      throw new Error('PKCS#12 数据大小无效');
    }

    let parsed: cert.Pkcs12Data;
    try {
      parsed = await cert.parsePkcs12(p12Data, password);
    } catch {
      throw new Error('PKCS#12 密码错误或格式无效');
    }
    if (parsed.privateKey === undefined || parsed.cert === undefined) {
      throw new Error('PKCS#12 缺少设备证书或私钥');
    }

    const encodedCertificate = await parsed.cert.getEncoded();
    const fingerprint = await CredentialStore.sha256Hex(encodedCertificate.data);
    if (fingerprint !== expectedFingerprint.toLowerCase()) {
      throw new Error('设备证书指纹与配对响应不一致');
    }

    const pendingPath = CredentialStore.p12Path(installationId, 'pending');
    CredentialStore.writeBytes(pendingPath, p12Data);
    try {
      await CredentialStore.storeSecret(
        CredentialStore.passwordAlias(installationId, 'pending'),
        password
      );
    } catch {
      CredentialStore.deleteFile(pendingPath);
      throw new Error('凭据密码保存失败');
    }
    if (!(await CredentialStore.hasStagedCredential(installationId))) {
      throw new Error('待激活设备身份保存失败');
    }
  }

  static async promoteCredential(installationId: string): Promise<void> {
    CredentialStore.requireConfigured();
    const pendingPath = CredentialStore.p12Path(installationId, 'pending');
    const password = await CredentialStore.loadSecret(
      CredentialStore.passwordAlias(installationId, 'pending')
    );
    if (!CredentialStore.fileExists(pendingPath) || password === null) {
      throw new Error('没有完整的待激活设备身份');
    }

    const activePath = CredentialStore.p12Path(installationId, 'active');
    const replacementPath = `${activePath}.new`;
    CredentialStore.deleteFile(replacementPath);
    fileIo.copyFileSync(pendingPath, replacementPath);
    await CredentialStore.storeSecret(
      CredentialStore.passwordAlias(installationId, 'active'),
      password
    );
    CredentialStore.deleteFile(activePath);
    fileIo.renameSync(replacementPath, activePath);

    await CredentialStore.discardStagedCredential(installationId);
  }

  static async stagedClientIdentity(installationId: string): Promise<ClientIdentity> {
    return await CredentialStore.loadClientIdentity(installationId, 'pending');
  }

  static async activeClientIdentity(installationId: string): Promise<ClientIdentity> {
    return await CredentialStore.loadClientIdentity(installationId, 'active');
  }

  static async loadClientIdentity(
    installationId: string,
    state: CredentialState
  ): Promise<ClientIdentity> {
    CredentialStore.requireConfigured();
    const p12Path = CredentialStore.p12Path(installationId, state);
    const password = await CredentialStore.loadSecret(
      CredentialStore.passwordAlias(installationId, state)
    );
    if (!CredentialStore.fileExists(p12Path) || password === null) {
      throw new Error('设备身份未找到');
    }

    let parsed: cert.Pkcs12Data;
    try {
      parsed = await cert.parsePkcs12(CredentialStore.readBytes(p12Path), password);
    } catch {
      throw new Error('设备身份解析失败');
    }
    if (parsed.privateKey === undefined || parsed.cert === undefined) {
      throw new Error('设备身份不完整');
    }

    const privateKeyPath = CredentialStore.webPrivateKeyPath(installationId, state);
    const certificateChainPath = CredentialStore.webCertificatePath(installationId, state);
    const privateKey = typeof parsed.privateKey === 'string'
      ? parsed.privateKey
      : new util.TextDecoder('utf-8').decodeToString(parsed.privateKey);
    CredentialStore.writeText(privateKeyPath, privateKey);

    let certificateChain = await CredentialStore.pemCertificate(parsed.cert);
    const otherCertificates = parsed.otherCerts ?? [];
    for (const otherCertificate of otherCertificates) {
      certificateChain += await CredentialStore.pemCertificate(otherCertificate);
    }
    CredentialStore.writeText(certificateChainPath, certificateChain);

    return {
      certPath: p12Path,
      keyPath: '',
      password: password,
      privateKeyPath: privateKeyPath,
      certificateChainPath: certificateChainPath
    };
  }

  static async hasStagedCredential(installationId: string): Promise<boolean> {
    CredentialStore.requireConfigured();
    return CredentialStore.fileExists(CredentialStore.p12Path(installationId, 'pending')) &&
      await CredentialStore.loadSecret(
        CredentialStore.passwordAlias(installationId, 'pending')
      ) !== null;
  }

  static async hasCredential(installationId: string): Promise<boolean> {
    CredentialStore.requireConfigured();
    return CredentialStore.fileExists(CredentialStore.p12Path(installationId, 'active')) &&
      await CredentialStore.loadSecret(
        CredentialStore.passwordAlias(installationId, 'active')
      ) !== null;
  }

  static async discardStagedCredential(installationId: string): Promise<void> {
    CredentialStore.requireConfigured();
    CredentialStore.deleteCredentialFiles(installationId, 'pending');
    await CredentialStore.deleteSecret(CredentialStore.passwordAlias(installationId, 'pending'));
  }

  static async deleteAll(installationId: string): Promise<void> {
    CredentialStore.requireConfigured();
    CredentialStore.deleteCredentialFiles(installationId, 'pending');
    CredentialStore.deleteCredentialFiles(installationId, 'active');
    await CredentialStore.deleteSecret(CredentialStore.passwordAlias(installationId, 'pending'));
    await CredentialStore.deleteSecret(CredentialStore.passwordAlias(installationId, 'active'));
  }

  private static requireConfigured(): void {
    if (CredentialStore.filesDir === '' || CredentialStore.cacheDir === '') {
      throw new Error('凭据存储尚未初始化');
    }
  }

  private static aliasFor(installationId: string, state: CredentialState): string {
    return `${CredentialStore.ALIAS_PREFIX}.${installationId}.${state}`;
  }

  private static passwordAlias(installationId: string, state: CredentialState): string {
    return `${CredentialStore.aliasFor(installationId, state)}.password`;
  }

  private static p12Path(installationId: string, state: CredentialState): string {
    return `${CredentialStore.filesDir}/credential-${installationId}-${state}.p12`;
  }

  private static webPrivateKeyPath(installationId: string, state: CredentialState): string {
    return `${CredentialStore.cacheDir}/credential-${installationId}-${state}-key.pem`;
  }

  private static webCertificatePath(installationId: string, state: CredentialState): string {
    return `${CredentialStore.cacheDir}/credential-${installationId}-${state}-chain.pem`;
  }

  private static deleteCredentialFiles(installationId: string, state: CredentialState): void {
    CredentialStore.deleteFile(CredentialStore.p12Path(installationId, state));
    CredentialStore.deleteFile(CredentialStore.webPrivateKeyPath(installationId, state));
    CredentialStore.deleteFile(CredentialStore.webCertificatePath(installationId, state));
  }

  private static async sha256Hex(data: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: data });
    const digest = await md.digest();
    let value = '';
    for (let index = 0; index < digest.data.length; index++) {
      value += digest.data[index].toString(16).padStart(2, '0');
    }
    return value;
  }

  private static async pemCertificate(certificate: cert.X509Cert): Promise<string> {
    const encoded = await certificate.getEncoded();
    const base64 = new util.Base64Helper().encodeToStringSync(encoded.data);
    const lines: string[] = [];
    for (let index = 0; index < base64.length; index += 64) {
      lines.push(base64.substring(index, Math.min(index + 64, base64.length)));
    }
    return `-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n`;
  }

  private static writeBytes(path: string, data: Uint8Array): void {
    const file = fileIo.openSync(path, 0o2 | 0o100 | 0o1000);
    try {
      const exact = data.byteOffset === 0 && data.byteLength === data.buffer.byteLength
        ? data.buffer as ArrayBuffer
        : data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
      fileIo.writeSync(file.fd, exact);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static writeText(path: string, value: string): void {
    const file = fileIo.openSync(path, 0o2 | 0o100 | 0o1000);
    try {
      fileIo.writeSync(file.fd, value);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static readBytes(path: string): Uint8Array {
    const size = fileIo.statSync(path).size;
    if (size <= 0 || size > CredentialStore.MAXIMUM_P12_BYTES) {
      throw new Error('设备身份文件大小无效');
    }
    const buffer = new ArrayBuffer(size);
    const file = fileIo.openSync(path);
    try {
      const bytesRead = fileIo.readSync(file.fd, buffer);
      return new Uint8Array(buffer.slice(0, bytesRead));
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static fileExists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch {
      return false;
    }
  }

  private static deleteFile(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch {
      // Idempotent cleanup.
    }
  }

  private static bytes(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }

  private static async storeSecret(alias: string, value: string): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, CredentialStore.bytes(alias));
    attributes.set(asset.Tag.SECRET, CredentialStore.bytes(value));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  private static async loadSecret(alias: string): Promise<string | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, CredentialStore.bytes(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result = await asset.query(query);
      if (result.length !== 1) {
        return null;
      }
      const secret = result[0].get(asset.Tag.SECRET) as Uint8Array | undefined;
      if (secret === undefined) {
        return null;
      }
      return new util.TextDecoder('utf-8').decodeToString(secret);
    } catch {
      return null;
    }
  }

  private static async deleteSecret(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, CredentialStore.bytes(alias));
    try {
      await asset.remove(query);
    } catch {
      // Idempotent cleanup.
    }
  }
}
