import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { cert, certificateManager } from '@kit.DeviceCertificateKit';
import { fileIo } from '@kit.CoreFileKit';
import { asset } from '@kit.AssetStoreKit';

type CredentialState = 'pending' | 'active' | 'rollback';
type PromotionMarker = 'previous' | 'new' | 'installed' | 'committed';

export interface ClientIdentity {
  certPath: string;
  keyPath: string;
  password: string;
  privateKeyPath: string;
  certificateChainPath: string;
}

export class CredentialPromotion {
  readonly installationId: string;
  readonly hadPreviousCredential: boolean;

  constructor(installationId: string, hadPreviousCredential: boolean) {
    this.installationId = installationId;
    this.hadPreviousCredential = hadPreviousCredential;
  }
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
  private static webAuthUriByInstallation: Map<string, string> = new Map();

  static configure(context: common.UIAbilityContext): void {
    CredentialStore.filesDir = context.filesDir;
    CredentialStore.cacheDir = context.cacheDir;
  }

  /**
   * Installs the active PKCS#12 into the system certificate manager and returns
   * the authUri ArkWeb expects for ClientAuthenticationHandler.confirm(authUri).
   * PEM file paths alone are ambiguous on API 22+ and frequently yield -110.
   */
  static async webClientAuthUri(installationId: string): Promise<string> {
    CredentialStore.requireConfigured();
    if (CredentialStore.credentialPromotion(installationId) !== null) {
      throw new Error('设备身份提升事务尚未恢复');
    }
    const cached = CredentialStore.webAuthUriByInstallation.get(installationId);
    if (cached !== undefined && cached !== '') {
      return cached;
    }

    const stored = CredentialStore.readWebAuthUri(installationId);
    if (stored !== '') {
      try {
        await certificateManager.getPrivateCertificate(stored);
        CredentialStore.webAuthUriByInstallation.set(installationId, stored);
        return stored;
      } catch {
        CredentialStore.deleteFile(CredentialStore.webAuthUriPath(installationId));
      }
    }

    const alias = CredentialStore.webCertAlias(installationId);
    const existing = await CredentialStore.findPrivateCertificateUri(alias);
    if (existing !== '') {
      try {
        await certificateManager.getPrivateCertificate(existing);
        CredentialStore.persistWebAuthUri(installationId, existing);
        return existing;
      } catch {
        try {
          await certificateManager.uninstallPrivateCertificate(existing);
        } catch {
          // Continue to a fresh install.
        }
      }
    }

    const p12Path = CredentialStore.p12Path(installationId, 'active');
    const password = await CredentialStore.loadSecret(
      CredentialStore.passwordAlias(installationId, 'active')
    );
    if (!CredentialStore.fileExists(p12Path) || password === null) {
      throw new Error('设备身份未找到');
    }

    // Certificate Manager rejects many go-pkcs12 Modern blobs (401). Re-encode
    // with Harmony's cert kit and a short ASCII install password/alias that
    // stay inside HUKS parameter limits.
    const installPassword = CredentialStore.webInstallPassword(installationId);
    const keystore = await CredentialStore.harmonyCompatiblePkcs12(
      CredentialStore.readBytes(p12Path),
      password,
      installPassword
    );
    const keystoreCopy = new Uint8Array(keystore.length);
    keystoreCopy.set(keystore);

    let result: certificateManager.CMResult;
    try {
      result = await certificateManager.installPrivateCertificate(
        keystoreCopy,
        installPassword,
        alias,
        certificateManager.AuthStorageLevel.EL1
      );
    } catch (firstError) {
      // A leftover credential under the same alias can block install; remove and retry once.
      const leftover = await CredentialStore.findPrivateCertificateUri(alias);
      if (leftover === '') {
        throw new Error(CredentialStore.formatCertManagerError(
          '安装客户端证书失败',
          firstError
        ));
      }
      try {
        await certificateManager.uninstallPrivateCertificate(leftover);
        result = await certificateManager.installPrivateCertificate(
          keystoreCopy,
          installPassword,
          alias,
          certificateManager.AuthStorageLevel.EL1
        );
      } catch (retryError) {
        throw new Error(CredentialStore.formatCertManagerError(
          '安装客户端证书失败',
          retryError
        ));
      }
    }
    const uri = CredentialStore.uriFromInstallResult(result);
    if (uri === '') {
      throw new Error('系统证书管理器未返回客户端身份');
    }
    CredentialStore.persistWebAuthUri(installationId, uri);
    return uri;
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

  static async promoteCredential(installationId: string): Promise<CredentialPromotion> {
    CredentialStore.requireConfigured();
    if (CredentialStore.credentialPromotion(installationId) !== null) {
      throw new Error('设备身份存在尚未恢复的提升事务');
    }
    const pendingPath = CredentialStore.p12Path(installationId, 'pending');
    const password = await CredentialStore.loadSecret(
      CredentialStore.passwordAlias(installationId, 'pending')
    );
    if (!CredentialStore.fileExists(pendingPath) || password === null) {
      throw new Error('没有完整的待激活设备身份');
    }

    const activePath = CredentialStore.p12Path(installationId, 'active');
    const activePassword = await CredentialStore.loadSecret(
      CredentialStore.passwordAlias(installationId, 'active')
    );
    const activeFileExists = CredentialStore.fileExists(activePath);
    if (activeFileExists !== (activePassword !== null)) {
      throw new Error('已有设备身份不完整，拒绝覆盖');
    }

    const promotion = new CredentialPromotion(installationId, activeFileExists);
    await CredentialStore.prepareCredentialRollback(promotion, activePassword);
    CredentialStore.writePromotionMarker(
      installationId,
      promotion.hadPreviousCredential ? 'previous' : 'new'
    );

    try {
      await CredentialStore.installPendingCredential(installationId, password);
      CredentialStore.writePromotionMarker(installationId, 'installed');
      return promotion;
    } catch (error) {
      try {
        await CredentialStore.restoreCredentialPromotion(promotion);
        await CredentialStore.discardCredentialRollback(promotion.installationId);
        CredentialStore.deletePromotionMarkers(promotion.installationId);
      } catch {
        throw new Error('设备身份提升失败，且旧身份恢复失败');
      }
      throw error as Error;
    }
  }

  static async rollbackCredentialPromotion(promotion: CredentialPromotion): Promise<void> {
    CredentialStore.requireConfigured();
    await CredentialStore.restoreCredentialPromotion(promotion);
    await CredentialStore.discardCredentialRollback(promotion.installationId);
    CredentialStore.deletePromotionMarkers(promotion.installationId);
  }

  static async markCredentialPromotionCommitted(promotion: CredentialPromotion): Promise<void> {
    CredentialStore.requireConfigured();
    const stored = CredentialStore.credentialPromotion(promotion.installationId);
    if (stored === null || stored.hadPreviousCredential !== promotion.hadPreviousCredential ||
        !CredentialStore.hasPromotionMarker(promotion.installationId, 'installed')) {
      throw new Error('设备身份提升事务不完整');
    }
    CredentialStore.writePromotionMarker(promotion.installationId, 'committed');
  }

  static async reconcileCredentialPromotion(
    installationId: string,
    profileCommitted: boolean
  ): Promise<void> {
    CredentialStore.requireConfigured();
    const promotion = CredentialStore.credentialPromotion(installationId);
    if (promotion === null) {
      return;
    }

    const committed = profileCommitted ||
      CredentialStore.hasPromotionMarker(installationId, 'committed');
    if (!committed) {
      await CredentialStore.restoreCredentialPromotion(promotion);
      await CredentialStore.discardCredentialRollback(installationId);
      CredentialStore.deletePromotionMarkers(installationId);
      return;
    }

    // The profile commit is the cross-store source of truth. If the process
    // stopped between the active password and PKCS#12 replacement, replaying
    // from pending makes the pair coherent before the journal is cleared.
    const pendingPassword = await CredentialStore.loadSecret(
      CredentialStore.passwordAlias(installationId, 'pending')
    );
    if (pendingPassword !== null &&
        CredentialStore.fileExists(CredentialStore.p12Path(installationId, 'pending'))) {
      await CredentialStore.installPendingCredential(installationId, pendingPassword);
    } else if (await CredentialStore.hasCompleteCredential(installationId, 'active')) {
      // Cleanup may have removed pending just before the process stopped. Rebuild
      // it from the already committed active pair so bootstrap can retry the
      // activation flow and reload the profile after unlocking the journal.
      const activePassword = await CredentialStore.loadSecret(
        CredentialStore.passwordAlias(installationId, 'active')
      );
      if (activePassword === null) {
        throw new Error('已提交连接的设备身份无法恢复');
      }
      const pendingPath = CredentialStore.p12Path(installationId, 'pending');
      CredentialStore.deleteFile(pendingPath);
      fileIo.copyFileSync(
        CredentialStore.p12Path(installationId, 'active'),
        pendingPath
      );
      CredentialStore.syncFile(pendingPath);
      await CredentialStore.storeSecret(
        CredentialStore.passwordAlias(installationId, 'pending'),
        activePassword
      );
    } else {
      throw new Error('已提交连接的设备身份无法恢复');
    }
    await CredentialStore.discardCredentialRollback(installationId);
    CredentialStore.deletePromotionMarkers(installationId);
  }

  static async completeCredentialPromotion(promotion: CredentialPromotion): Promise<void> {
    CredentialStore.requireConfigured();
    if (!CredentialStore.hasPromotionMarker(promotion.installationId, 'committed')) {
      throw new Error('设备身份提升尚未与连接提交同步');
    }
    let cleanupError: Error | null = null;
    try {
      CredentialStore.deleteCredentialFilesStrict(promotion.installationId, 'pending');
      await CredentialStore.deleteSecretStrict(
        CredentialStore.passwordAlias(promotion.installationId, 'pending')
      );
    } catch (error) {
      cleanupError = error as Error;
    }
    try {
      await CredentialStore.discardCredentialRollback(promotion.installationId);
    } catch (error) {
      if (cleanupError === null) {
        cleanupError = error as Error;
      }
    }
    if (cleanupError === null) {
      CredentialStore.deletePromotionMarkers(promotion.installationId);
    }
    if (cleanupError !== null) {
      throw cleanupError;
    }
  }

  static async stagedClientIdentity(installationId: string): Promise<ClientIdentity> {
    return await CredentialStore.loadClientIdentity(installationId, 'pending');
  }

  static async activeClientIdentity(installationId: string): Promise<ClientIdentity> {
    if (CredentialStore.credentialPromotion(installationId) !== null) {
      throw new Error('设备身份提升事务尚未恢复');
    }
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
    CredentialStore.writeText(
      privateKeyPath,
      CredentialStore.pemPrivateKey(parsed.privateKey)
    );

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
    if (CredentialStore.credentialPromotion(installationId) !== null) {
      return false;
    }
    return await CredentialStore.hasCompleteCredential(installationId, 'active');
  }

  static async discardStagedCredential(installationId: string): Promise<void> {
    CredentialStore.requireConfigured();
    if (CredentialStore.credentialPromotion(installationId) !== null) {
      throw new Error('设备身份提升事务尚未恢复');
    }
    CredentialStore.deleteCredentialFilesStrict(installationId, 'pending');
    await CredentialStore.deleteSecretStrict(
      CredentialStore.passwordAlias(installationId, 'pending')
    );
  }

  static async deleteAll(installationId: string): Promise<void> {
    CredentialStore.requireConfigured();
    await CredentialStore.invalidateWebClientAuth(installationId);
    CredentialStore.deleteCredentialFilesStrict(installationId, 'pending');
    CredentialStore.deleteCredentialFilesStrict(installationId, 'active');
    CredentialStore.deleteCredentialFilesStrict(installationId, 'rollback');
    CredentialStore.deletePromotionMarkers(installationId);
    await CredentialStore.deleteSecretStrict(CredentialStore.passwordAlias(installationId, 'pending'));
    await CredentialStore.deleteSecretStrict(CredentialStore.passwordAlias(installationId, 'active'));
    await CredentialStore.deleteSecretStrict(CredentialStore.passwordAlias(installationId, 'rollback'));
  }

  private static async prepareCredentialRollback(
    promotion: CredentialPromotion,
    activePassword: string | null
  ): Promise<void> {
    await CredentialStore.discardCredentialRollback(promotion.installationId);
    if (!promotion.hadPreviousCredential || activePassword === null) {
      return;
    }

    const rollbackPath = CredentialStore.p12Path(promotion.installationId, 'rollback');
    try {
      fileIo.copyFileSync(
        CredentialStore.p12Path(promotion.installationId, 'active'),
        rollbackPath
      );
      CredentialStore.syncFile(rollbackPath);
      await CredentialStore.storeSecret(
        CredentialStore.passwordAlias(promotion.installationId, 'rollback'),
        activePassword
      );
    } catch (error) {
      CredentialStore.deleteFile(rollbackPath);
      await CredentialStore.deleteSecret(
        CredentialStore.passwordAlias(promotion.installationId, 'rollback')
      );
      throw error as Error;
    }
  }

  private static async restoreCredentialPromotion(
    promotion: CredentialPromotion
  ): Promise<void> {
    const activePath = CredentialStore.p12Path(promotion.installationId, 'active');
    if (!promotion.hadPreviousCredential) {
      CredentialStore.deleteCredentialFilesStrict(promotion.installationId, 'active');
      await CredentialStore.deleteSecretStrict(
        CredentialStore.passwordAlias(promotion.installationId, 'active')
      );
      return;
    }

    const rollbackPath = CredentialStore.p12Path(promotion.installationId, 'rollback');
    const rollbackPassword = await CredentialStore.loadSecret(
      CredentialStore.passwordAlias(promotion.installationId, 'rollback')
    );
    if (!CredentialStore.fileExists(rollbackPath) || rollbackPassword === null) {
      throw new Error('旧设备身份备份不完整');
    }

    const replacementPath = `${activePath}.restore`;
    CredentialStore.deleteFile(replacementPath);
    fileIo.copyFileSync(rollbackPath, replacementPath);
    CredentialStore.syncFile(replacementPath);
    try {
      await CredentialStore.invalidateWebClientAuth(promotion.installationId);
      await CredentialStore.storeSecret(
        CredentialStore.passwordAlias(promotion.installationId, 'active'),
        rollbackPassword
      );
      CredentialStore.deleteFile(activePath);
      fileIo.renameSync(replacementPath, activePath);
      CredentialStore.syncFile(activePath);
      CredentialStore.deleteWebCredentialFiles(promotion.installationId, 'active');
    } catch (error) {
      CredentialStore.deleteFile(replacementPath);
      throw error as Error;
    }
  }

  private static async discardCredentialRollback(installationId: string): Promise<void> {
    CredentialStore.deleteCredentialFilesStrict(installationId, 'rollback');
    await CredentialStore.deleteSecretStrict(
      CredentialStore.passwordAlias(installationId, 'rollback')
    );
  }

  private static async installPendingCredential(
    installationId: string,
    password: string
  ): Promise<void> {
    const pendingPath = CredentialStore.p12Path(installationId, 'pending');
    if (!CredentialStore.fileExists(pendingPath)) {
      throw new Error('待激活设备身份文件已丢失');
    }
    const activePath = CredentialStore.p12Path(installationId, 'active');
    const replacementPath = `${activePath}.new`;
    CredentialStore.deleteFile(replacementPath);
    fileIo.copyFileSync(pendingPath, replacementPath);
    CredentialStore.syncFile(replacementPath);
    try {
      await CredentialStore.invalidateWebClientAuth(installationId);
      await CredentialStore.storeSecret(
        CredentialStore.passwordAlias(installationId, 'active'),
        password
      );
      CredentialStore.deleteFile(activePath);
      fileIo.renameSync(replacementPath, activePath);
      CredentialStore.syncFile(activePath);
      CredentialStore.deleteWebCredentialFiles(installationId, 'active');
    } catch (error) {
      CredentialStore.deleteFile(replacementPath);
      throw error as Error;
    }
  }

  private static async hasCompleteCredential(
    installationId: string,
    state: CredentialState
  ): Promise<boolean> {
    return CredentialStore.fileExists(CredentialStore.p12Path(installationId, state)) &&
      await CredentialStore.loadSecret(
        CredentialStore.passwordAlias(installationId, state)
      ) !== null;
  }

  private static credentialPromotion(installationId: string): CredentialPromotion | null {
    const previous = CredentialStore.hasPromotionMarker(installationId, 'previous');
    const created = CredentialStore.hasPromotionMarker(installationId, 'new');
    if (previous && created) {
      throw new Error('设备身份提升日志损坏');
    }
    if (!previous && !created) {
      return null;
    }
    return new CredentialPromotion(installationId, previous);
  }

  private static promotionMarkerPath(
    installationId: string,
    marker: PromotionMarker
  ): string {
    return `${CredentialStore.filesDir}/credential-${installationId}-promotion-${marker}`;
  }

  private static hasPromotionMarker(installationId: string, marker: PromotionMarker): boolean {
    return CredentialStore.fileExists(
      CredentialStore.promotionMarkerPath(installationId, marker)
    );
  }

  private static writePromotionMarker(installationId: string, marker: PromotionMarker): void {
    CredentialStore.writeText(
      CredentialStore.promotionMarkerPath(installationId, marker),
      marker
    );
  }

  private static deletePromotionMarkers(installationId: string): void {
    CredentialStore.deleteFileStrict(
      CredentialStore.promotionMarkerPath(installationId, 'previous')
    );
    CredentialStore.deleteFileStrict(
      CredentialStore.promotionMarkerPath(installationId, 'new')
    );
    CredentialStore.deleteFileStrict(
      CredentialStore.promotionMarkerPath(installationId, 'installed')
    );
    CredentialStore.deleteFileStrict(
      CredentialStore.promotionMarkerPath(installationId, 'committed')
    );
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
    return `${CredentialStore.filesDir}/credential-${installationId}-${state}-key.pem`;
  }

  private static webCertificatePath(installationId: string, state: CredentialState): string {
    return `${CredentialStore.filesDir}/credential-${installationId}-${state}-chain.pem`;
  }

  private static deleteCredentialFiles(installationId: string, state: CredentialState): void {
    CredentialStore.deleteFile(CredentialStore.p12Path(installationId, state));
    CredentialStore.deleteWebCredentialFiles(installationId, state);
  }

  private static deleteCredentialFilesStrict(
    installationId: string,
    state: CredentialState
  ): void {
    CredentialStore.deleteFileStrict(CredentialStore.p12Path(installationId, state));
    CredentialStore.deleteWebCredentialFiles(installationId, state);
  }

  private static deleteWebCredentialFiles(installationId: string, state: CredentialState): void {
    CredentialStore.deleteFile(CredentialStore.webPrivateKeyPath(installationId, state));
    CredentialStore.deleteFile(CredentialStore.webCertificatePath(installationId, state));
  }

  private static webCertAlias(installationId: string): string {
    // Certificate Manager aliases are user-visible and tightly validated.
    return `re${installationId.substring(0, 8)}`;
  }

  private static webInstallPassword(installationId: string): string {
    // Keep well under HUKS password limits; unrelated to the NetworkKit P12 password.
    return `re${installationId.substring(0, 14)}`;
  }

  private static webAuthUriPath(installationId: string): string {
    return `${CredentialStore.filesDir}/credential-${installationId}-web-auth-uri`;
  }

  private static persistWebAuthUri(installationId: string, uri: string): void {
    CredentialStore.webAuthUriByInstallation.set(installationId, uri);
    CredentialStore.writeText(CredentialStore.webAuthUriPath(installationId), uri);
  }

  private static readWebAuthUri(installationId: string): string {
    const path = CredentialStore.webAuthUriPath(installationId);
    if (!CredentialStore.fileExists(path)) {
      return '';
    }
    try {
      const size = fileIo.statSync(path).size;
      if (size <= 0 || size > 4096) {
        return '';
      }
      const buffer = new ArrayBuffer(size);
      const file = fileIo.openSync(path);
      try {
        const bytesRead = fileIo.readSync(file.fd, buffer);
        return new util.TextDecoder('utf-8')
          .decodeToString(new Uint8Array(buffer.slice(0, bytesRead)))
          .trim();
      } finally {
        fileIo.closeSync(file);
      }
    } catch {
      return '';
    }
  }

  private static uriFromInstallResult(result: certificateManager.CMResult): string {
    if (result.uri !== undefined && result.uri !== '') {
      return result.uri;
    }
    if (result.credential !== undefined && result.credential.keyUri !== '') {
      return result.credential.keyUri;
    }
    return '';
  }

  private static async findPrivateCertificateUri(alias: string): Promise<string> {
    try {
      const listed = await certificateManager.getPrivateCertificates();
      const credentials = listed.credentialList ?? [];
      for (let index = 0; index < credentials.length; index++) {
        if (credentials[index].alias === alias && credentials[index].keyUri !== '') {
          return credentials[index].keyUri;
        }
      }
    } catch {
      // Missing private certificates is fine; install will create one.
    }
    return '';
  }

  private static async invalidateWebClientAuth(installationId: string): Promise<void> {
    const alias = CredentialStore.webCertAlias(installationId);
    let uri = CredentialStore.webAuthUriByInstallation.get(installationId) ?? '';
    if (uri === '') {
      uri = CredentialStore.readWebAuthUri(installationId);
    }
    if (uri === '') {
      uri = await CredentialStore.findPrivateCertificateUri(alias);
    }
    CredentialStore.webAuthUriByInstallation.delete(installationId);
    CredentialStore.deleteFile(CredentialStore.webAuthUriPath(installationId));
    if (uri === '') {
      return;
    }
    try {
      await certificateManager.uninstallPrivateCertificate(uri);
    } catch {
      // Idempotent: the credential may already have been removed by the user.
    }
  }

  private static async harmonyCompatiblePkcs12(
    original: Uint8Array,
    sourcePassword: string,
    installPassword: string
  ): Promise<Uint8Array> {
    let parsed: cert.Pkcs12Data;
    try {
      parsed = await cert.parsePkcs12(original, sourcePassword);
    } catch (error) {
      throw new Error(CredentialStore.formatCertManagerError('解析设备 PKCS#12 失败', error));
    }
    if (parsed.privateKey === undefined || parsed.cert === undefined) {
      throw new Error('设备 PKCS#12 缺少私钥或证书');
    }
    try {
      return await cert.createPkcs12(parsed, {
        password: installPassword,
        encryptCert: false,
        macSaltLen: 16,
        macIterations: 2048,
        macDigestAlgorithm: cert.Pkcs12MacDigestAlgorithm.SHA256
      });
    } catch (error) {
      throw new Error(CredentialStore.formatCertManagerError('重建 PKCS#12 失败', error));
    }
  }

  private static formatCertManagerError(prefix: string, error: Object): string {
    const business = error as BusinessError;
    const code = business.code;
    const message = business.message;
    if (typeof code === 'number' && typeof message === 'string' && message !== '') {
      return `${prefix}（${code}: ${message}）`;
    }
    if (error instanceof Error && error.message !== '') {
      return `${prefix}（${error.message}）`;
    }
    return prefix;
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
    return CredentialStore.pemBlock('CERTIFICATE', encoded.data);
  }

  private static pemPrivateKey(value: string | Uint8Array): string {
    if (typeof value === 'string') {
      const trimmed = value.trim();
      if (trimmed.indexOf('BEGIN') >= 0) {
        return trimmed.endsWith('\n') ? trimmed : `${trimmed}\n`;
      }
      // Unexpected non-PEM string: treat as base64 body.
      return CredentialStore.pemBlockFromBase64('PRIVATE KEY', trimmed);
    }
    return CredentialStore.pemBlock('PRIVATE KEY', value);
  }

  private static pemBlock(label: string, data: Uint8Array): string {
    const base64 = new util.Base64Helper().encodeToStringSync(data);
    return CredentialStore.pemBlockFromBase64(label, base64);
  }

  private static pemBlockFromBase64(label: string, base64: string): string {
    const lines: string[] = [];
    for (let index = 0; index < base64.length; index += 64) {
      lines.push(base64.substring(index, Math.min(index + 64, base64.length)));
    }
    return `-----BEGIN ${label}-----\n${lines.join('\n')}\n-----END ${label}-----\n`;
  }

  private static writeBytes(path: string, data: Uint8Array): void {
    const file = fileIo.openSync(path, 0o2 | 0o100 | 0o1000);
    try {
      const exact = data.byteOffset === 0 && data.byteLength === data.buffer.byteLength
        ? data.buffer as ArrayBuffer
        : data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
      fileIo.writeSync(file.fd, exact);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static writeText(path: string, value: string): void {
    const file = fileIo.openSync(path, 0o2 | 0o100 | 0o1000);
    try {
      fileIo.writeSync(file.fd, value);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static syncFile(path: string): void {
    const file = fileIo.openSync(path);
    try {
      fileIo.fsyncSync(file.fd);
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

  private static deleteFileStrict(path: string): void {
    if (!CredentialStore.fileExists(path)) {
      return;
    }
    fileIo.unlinkSync(path);
    if (CredentialStore.fileExists(path)) {
      throw new Error('设备身份事务日志清理失败');
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

  private static async deleteSecretStrict(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, CredentialStore.bytes(alias));
    try {
      await asset.remove(query);
    } catch {
      const remaining = await CredentialStore.querySecretStrict(alias);
      if (remaining) {
        throw new Error('设备身份密码清理失败');
      }
      return;
    }
    if (await CredentialStore.querySecretStrict(alias)) {
      throw new Error('设备身份密码清理失败');
    }
  }

  private static async querySecretStrict(alias: string): Promise<boolean> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, CredentialStore.bytes(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    try {
      const result = await asset.query(query);
      return result.length > 0;
    } catch {
      // Missing aliases are the success case for deleteSecretStrict's
      // post-remove check; Asset Store reports that as NotFound.
      return false;
    }
  }
}
