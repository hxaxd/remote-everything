import { ConnectionConfig, ConnectionMode } from '../../core/models/ConnectionConfig';
import { SetupPayload } from '../../core/models/SetupPayload';
import { CatalogSnapshot } from '../../core/models/RemoteApp';
import { PairingCredential } from '../../core/models/PairingCredential';
import { RemoteApi as RemoteApiDecoder } from '../../core/network/RemoteApi';
import {
  ClientIdentity, CredentialPromotion, CredentialStore
} from '../../core/security/CredentialStore';
import { GatewaySecurityPolicy } from '../../core/security/GatewaySecurityPolicy';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

// MARK: - Protocols

export interface SetupProfileStore {
  stagedProfile(): ConnectionConfig | null;
  stageProfile(value: ConnectionConfig): Promise<void>;
  commitStagedProfile(): Promise<ConnectionConfig>;
  isProfileCommitted(value: ConnectionConfig): Promise<boolean>;
  discardStagedProfile(): Promise<void>;
}

export interface SetupIdentityStore {
  credentialPassword(installationId: string): Promise<string>;
  stageCredential(
    installationId: string, encoded: string, password: string, expectedFingerprint: string
  ): Promise<void>;
  stagedClientIdentity(installationId: string): Promise<ClientIdentity>;
  promoteCredential(installationId: string): Promise<CredentialPromotion>;
  markCredentialPromotionCommitted(promotion: CredentialPromotion): Promise<void>;
  reconcileCredentialPromotion(
    installationId: string, profileCommitted: boolean
  ): Promise<void>;
  rollbackCredentialPromotion(promotion: CredentialPromotion): Promise<void>;
  completeCredentialPromotion(promotion: CredentialPromotion): Promise<void>;
  hasStagedCredential(installationId: string): Promise<boolean>;
  discardStagedCredential(installationId: string): Promise<void>;
}

export interface SetupTransport {
  verifyCatalog(config: ConnectionConfig): Promise<void>;
  request(
    config: ConnectionConfig,
    url: string,
    method: string,
    identity: ClientIdentity | null,
    headers: Record<string, string>,
    body: string | null
  ): Promise<HTTPResult>;
}

export interface HTTPResult {
  status: number;
  body: string;
}

// MARK: - State & Action

export enum SetupStateKind {
  PAIRING = 'pairing',
  ACTIVATING = 'activating',
  AWAITING_APPROVAL = 'awaiting_approval',
  READY = 'ready',
  FAILED = 'failed'
}

export enum SetupAction {
  RETRY_PAIRING = 'retry_pairing',
  RETRY_ACTIVATION = 'retry_activation',
  RESTART_SETUP = 'restart_setup'
}

export class SetupState {
  readonly kind: SetupStateKind;
  readonly config: ConnectionConfig;
  readonly message: string;
  readonly action: SetupAction;
  readonly pendingExpiresAt: string | null;

  constructor(
    kind: SetupStateKind,
    config: ConnectionConfig,
    message: string = '',
    action: SetupAction = SetupAction.RESTART_SETUP,
    pendingExpiresAt: string | null = null
  ) {
    this.kind = kind;
    this.config = config;
    this.message = message;
    this.action = action;
    this.pendingExpiresAt = pendingExpiresAt;
  }

  static pairing(config: ConnectionConfig): SetupState {
    return new SetupState(SetupStateKind.PAIRING, config);
  }

  static activating(config: ConnectionConfig, expiresAt: string | null = null): SetupState {
    return new SetupState(SetupStateKind.ACTIVATING, config, '', SetupAction.RESTART_SETUP, expiresAt);
  }

  static awaitingApproval(config: ConnectionConfig, expiresAt: string | null = null): SetupState {
    return new SetupState(SetupStateKind.AWAITING_APPROVAL, config, '', SetupAction.RESTART_SETUP, expiresAt);
  }

  static ready(config: ConnectionConfig): SetupState {
    return new SetupState(SetupStateKind.READY, config);
  }

  static failed(config: ConnectionConfig, message: string, action: SetupAction): SetupState {
    return new SetupState(SetupStateKind.FAILED, config, message, action);
  }
}

// MARK: - Production Transport

export class ProductionSetupTransport implements SetupTransport {
  async verifyCatalog(config: ConnectionConfig): Promise<void> {
    const response = await this.request(config, config.appsUrl, 'GET', null, {}, null);
    if (response.status !== 200) {
      throw new Error(`目录服务返回 ${response.status}`);
    }
    RemoteApiDecoder.decodeCatalog(config, JSON.parse(response.body) as object);
  }

  async request(
    config: ConnectionConfig,
    url: string,
    method: string,
    identity: ClientIdentity | null,
    headers: Record<string, string>,
    body: string | null
  ): Promise<HTTPResult> {
    if (!config.isGatewayUrl(url)) {
      throw new Error('拒绝向连接范围外发送请求');
    }
    return new Promise<HTTPResult>((resolve, reject) => {
      const httpRequest = http.createHttp();

      const requestHeaders: Record<string, string> = { 'Accept': 'application/json' };
      Object.keys(headers).forEach((name: string) => {
        requestHeaders[name] = headers[name];
      });

      if (body !== null) {
        requestHeaders['Content-Type'] = 'application/json; charset=utf-8';
      }

      const requestOptions: http.HttpRequestOptions = {
        method: method as http.RequestMethod,
        header: requestHeaders,
        connectTimeout: 8000,
        readTimeout: 12000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      };

      if (body !== null) {
        requestOptions.extraData = body;
      }

      // mTLS client certificate for public mode
      if (identity !== null && config.mode === ConnectionMode.PUBLIC) {
        requestOptions.clientCert = {
          certPath: identity.certPath,
          certType: http.CertType.P12,
          keyPath: identity.keyPath,
          keyPassword: identity.password
        };
      }

      // LAN certificate pinning
      if (config.mode === ConnectionMode.LAN) {
        requestOptions.certificatePinning = {
          publicKeyHash: config.gatewayPublicKeyPin,
          hashAlgorithm: 'SHA-256',
        };
      }

      httpRequest.request(url, requestOptions, (err, response) => {
        if (err) {
          reject(new Error(`请求失败: ${JSON.stringify(err)}`));
          httpRequest.destroy();
          return;
        }

        const status = response.responseCode;
        const result = response.result;
        httpRequest.destroy();

        let bodyStr = '';
        if (typeof result === 'string') {
          bodyStr = result;
        } else if (result instanceof ArrayBuffer) {
          const decoder = new util.TextDecoder('utf-8');
          bodyStr = decoder.decodeToString(new Uint8Array(result));
        }

        resolve({ status: status, body: bodyStr });
      });
    });
  }
}

export class ProductionIdentityStore implements SetupIdentityStore {
  async credentialPassword(installationId: string): Promise<string> {
    return await CredentialStore.credentialPassword(installationId);
  }

  async stageCredential(
    installationId: string,
    encoded: string,
    password: string,
    expectedFingerprint: string
  ): Promise<void> {
    await CredentialStore.stageCredential(
      installationId,
      encoded,
      password,
      expectedFingerprint
    );
  }

  async stagedClientIdentity(installationId: string): Promise<ClientIdentity> {
    return await CredentialStore.stagedClientIdentity(installationId);
  }

  async promoteCredential(installationId: string): Promise<CredentialPromotion> {
    return await CredentialStore.promoteCredential(installationId);
  }

  async markCredentialPromotionCommitted(promotion: CredentialPromotion): Promise<void> {
    await CredentialStore.markCredentialPromotionCommitted(promotion);
  }

  async reconcileCredentialPromotion(
    installationId: string,
    profileCommitted: boolean
  ): Promise<void> {
    await CredentialStore.reconcileCredentialPromotion(installationId, profileCommitted);
  }

  async rollbackCredentialPromotion(promotion: CredentialPromotion): Promise<void> {
    await CredentialStore.rollbackCredentialPromotion(promotion);
  }

  async completeCredentialPromotion(promotion: CredentialPromotion): Promise<void> {
    await CredentialStore.completeCredentialPromotion(promotion);
  }

  async hasStagedCredential(installationId: string): Promise<boolean> {
    return await CredentialStore.hasStagedCredential(installationId);
  }

  async discardStagedCredential(installationId: string): Promise<void> {
    await CredentialStore.discardStagedCredential(installationId);
  }
}

// MARK: - Helpers

function codePointPrefix(value: string, maximum: number): string {
  let prefix = '';
  let count = 0;
  for (const character of value) {
    if (count >= maximum) {
      break;
    }
    prefix += character;
    count += 1;
  }
  return prefix;
}

function failureDetail(error: Error, fallback: string): string {
  return error.message || fallback;
}

class OperationCompletion {
  readonly promise: Promise<void>;
  private resolver: (() => void) | null = null;

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => {
      this.resolver = resolve;
    });
  }

  finish(): void {
    if (this.resolver !== null) {
      this.resolver();
      this.resolver = null;
    }
  }
}

// MARK: - Transaction

export class SetupTransaction {
  private settings: SetupProfileStore;
  private identity: SetupIdentityStore;
  private deviceName: string;
  private transport: SetupTransport;
  private operationGeneration: number = 0;
  private newestStartedOperation: number = 0;
  private activeOperations: Map<number, OperationCompletion> = new Map();

  constructor(
    settings: SetupProfileStore,
    identity: SetupIdentityStore,
    deviceName: string,
    transport: SetupTransport = new ProductionSetupTransport()
  ) {
    this.settings = settings;
    this.identity = identity;
    this.deviceName = deviceName;
    this.transport = transport;
  }

  /**
   * Recover a partially-completed public setup.
   */
  async recover(): Promise<ConnectionConfig | null> {
    const staged = this.settings.stagedProfile();
    if (staged === null) {
      return null;
    }

    const profileCommitted = await this.settings.isProfileCommitted(staged);
    await this.identity.reconcileCredentialPromotion(
      staged.installationId,
      profileCommitted
    );

    if (staged.mode === ConnectionMode.PUBLIC &&
        await this.identity.hasStagedCredential(staged.installationId)) {
      return staged;
    }

    await this.identity.discardStagedCredential(staged.installationId);
    await this.settings.discardStagedProfile();
    return null;
  }

  /**
   * Begin setup from a parsed URI.
   */
  async begin(setup: SetupPayload): Promise<SetupState> {
    const operation = this.startOperation();
    try {
      await this.waitForOlderOperations(operation);
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(setup.profile, operation);
      }
      await this.discardPendingArtifacts();
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(setup.profile, operation);
      }

      if (setup.profile.mode === ConnectionMode.LAN) {
        return await this.connectLAN(setup.profile, operation);
      } else {
        return await this.pair(setup, operation);
      }
    } finally {
      this.finishOperation(operation);
    }
  }

  async retryPairing(setup: SetupPayload): Promise<SetupState> {
    const operation = this.startOperation();
    try {
      await this.waitForOlderOperations(operation);
      return await this.pair(setup, operation);
    } finally {
      this.finishOperation(operation);
    }
  }

  async retryActivation(config: ConnectionConfig): Promise<SetupState> {
    const operation = this.startOperation();
    try {
      await this.waitForOlderOperations(operation);
      return await this.activate(config, null, operation);
    } finally {
      this.finishOperation(operation);
    }
  }

  async discardPending(): Promise<void> {
    this.operationGeneration += 1;
    const invalidatedGeneration = this.operationGeneration;
    const completions: Promise<void>[] = [];
    this.activeOperations.forEach((completion: OperationCompletion, generation: number): void => {
      if (generation < invalidatedGeneration) {
        completions.push(completion.promise);
      }
    });
    // Cancellation is not complete until every invalidated operation has left
    // its finally block. A caller may therefore start the same installation ID
    // immediately after this promise resolves without a stale cleanup racing it.
    await Promise.all(completions);
    if (this.newestStartedOperation <= invalidatedGeneration) {
      await this.discardPendingArtifacts();
    }
  }

  async cancel(): Promise<void> {
    // Invalidate in-flight work synchronously, before cleanup yields. Every setup
    // step checks this generation after awaiting external work.
    await this.discardPending();
  }

  private startOperation(): number {
    this.operationGeneration += 1;
    this.newestStartedOperation = this.operationGeneration;
    this.activeOperations.set(this.operationGeneration, new OperationCompletion());
    return this.operationGeneration;
  }

  private finishOperation(operation: number): void {
    const completion = this.activeOperations.get(operation);
    if (completion !== undefined) {
      completion.finish();
      this.activeOperations.delete(operation);
    }
  }

  private async waitForOlderOperations(operation: number): Promise<void> {
    const completions: Promise<void>[] = [];
    this.activeOperations.forEach((completion: OperationCompletion, generation: number): void => {
      if (generation < operation) {
        completions.push(completion.promise);
      }
    });
    await Promise.all(completions);
  }

  private async discardPendingArtifacts(): Promise<void> {
    const staged = this.settings.stagedProfile();
    if (staged === null) {
      return;
    }
    await this.discardArtifacts(staged);
  }

  private async discardArtifacts(config: ConnectionConfig): Promise<void> {
    let cleanupError: Error | null = null;
    try {
      const committed = await this.settings.isProfileCommitted(config);
      await this.identity.reconcileCredentialPromotion(config.installationId, committed);
      await this.identity.discardStagedCredential(config.installationId);
    } catch (error) {
      cleanupError = error as Error;
    }

    // The staged profile is the recovery anchor for a persistent credential
    // journal. Never remove it when identity reconciliation or cleanup failed.
    if (cleanupError === null) {
      try {
        const staged = this.settings.stagedProfile();
        if (staged !== null && staged.installationId === config.installationId) {
          await this.settings.discardStagedProfile();
        }
      } catch (error) {
        cleanupError = error as Error;
      }
    }

    if (cleanupError !== null) {
      throw cleanupError;
    }
  }

  private isOperationCurrent(operation: number): boolean {
    return operation === this.operationGeneration;
  }

  private async cancelledState(config: ConnectionConfig, operation: number): Promise<SetupState> {
    // Cancellation may have raced an operation that created its staged data
    // after cancel() performed its first cleanup. Clean by the operation's own
    // installation ID before allowing the stale task to return.
    if (this.newestStartedOperation <= operation) {
      await this.discardArtifacts(config);
    }
    return SetupState.failed(config, '初始化已取消', SetupAction.RESTART_SETUP);
  }

  // MARK: - Private Steps

  private async connectLAN(config: ConnectionConfig, operation: number): Promise<SetupState> {
    try {
      await this.transport.verifyCatalog(config);
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }

      await this.settings.stageProfile(config);
      // This synchronous check is the final cancellation gate. The current path
      // does not await between the check and entering durable finalization.
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }
      const committed = await this.finalizeLAN(config);
      return SetupState.ready(committed);
    } catch (err) {
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }
      await this.discardArtifacts(config);
      return SetupState.failed(
        config,
        failureDetail(err as Error, '局域网连接验证失败'),
        SetupAction.RESTART_SETUP
      );
    }
  }

  private async pair(setup: SetupPayload, operation: number): Promise<SetupState> {
    const config = setup.profile;
    try {
      await this.settings.stageProfile(config);
    } catch (err) {
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }
      return SetupState.failed(
        config,
        failureDetail(err as Error, '无法暂存连接'),
        SetupAction.RESTART_SETUP
      );
    }

    if (!this.isOperationCurrent(operation)) {
      return await this.cancelledState(config, operation);
    }

    // Generate credential password
    let password: string;
    try {
      password = await this.identity.credentialPassword(config.installationId);
    } catch (err) {
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }
      await this.discardArtifacts(config);
      return SetupState.failed(
        config,
        failureDetail(err as Error, '无法创建设备身份'),
        SetupAction.RESTART_SETUP
      );
    }
    if (!this.isOperationCurrent(operation)) {
      return await this.cancelledState(config, operation);
    }

    // Build pair request body
    const body = JSON.stringify({
      'device_name': codePointPrefix(this.deviceName, 80),
      'credential_password': password
    });

    // POST pair
    let response: HTTPResult;
    try {
      response = await this.transport.request(
        config,
        config.pairUrl,
        'POST',
        null,
        { 'Authorization': `Invitation ${setup.invitation}` },
        body
      );
    } catch (err) {
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }
      return SetupState.failed(
        config,
        failureDetail(err as Error, '无法连接配对服务'),
        SetupAction.RETRY_PAIRING
      );
    }
    if (!this.isOperationCurrent(operation)) {
      return await this.cancelledState(config, operation);
    }

    if (response.status === 401) {
      await this.discardArtifacts(config);
      return SetupState.failed(
        config, '邀请不可用、已过期或已被使用', SetupAction.RESTART_SETUP
      );
    }

    if (response.status !== 200) {
      return SetupState.failed(
        config, `配对服务返回 ${response.status}`, SetupAction.RETRY_PAIRING
      );
    }

    // Decode pairing credential
    let credentialJson: object;
    try {
      credentialJson = JSON.parse(response.body);
    } catch {
      return SetupState.failed(config, '配对响应不是有效 JSON', SetupAction.RETRY_PAIRING);
    }

    let credential: PairingCredential;
    try {
      credential = RemoteApiDecoder.decodePairingCredential(credentialJson);
    } catch (err) {
      return SetupState.failed(
        config,
        failureDetail(err as Error, '配对响应无效'),
        SetupAction.RETRY_PAIRING
      );
    }

    // Stage the credential
    try {
      await this.identity.stageCredential(
        config.installationId,
        credential.encoded,
        password,
        credential.fingerprint
      );
    } catch (err) {
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }
      await this.discardArtifacts(config);
      return SetupState.failed(
        config,
        failureDetail(err as Error, '设备身份保存失败'),
        SetupAction.RESTART_SETUP
      );
    }
    if (!this.isOperationCurrent(operation)) {
      return await this.cancelledState(config, operation);
    }

    return await this.activate(config, credential.pendingExpiresAt, operation);
  }

  private async finalizeLAN(config: ConnectionConfig): Promise<ConnectionConfig> {
    let committed: ConnectionConfig;
    try {
      committed = await this.settings.commitStagedProfile();
    } catch (error) {
      // A storage error after the append-only generation was renamed is a
      // committed result, not a reason to report failure and delete staging.
      if (!(await this.settings.isProfileCommitted(config))) {
        throw error as Error;
      }
      committed = config;
    }
    try { await this.settings.discardStagedProfile(); } catch {}
    return committed;
  }

  private async activate(
    config: ConnectionConfig,
    pendingExpiresAt: string | null,
    operation: number
  ): Promise<SetupState> {
    // Load staged client identity
    let clientIdentity: ClientIdentity;
    try {
      clientIdentity = await this.identity.stagedClientIdentity(config.installationId);
    } catch {
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }
      await this.discardArtifacts(config);
      return SetupState.failed(
        config, '待激活设备身份已丢失', SetupAction.RESTART_SETUP
      );
    }
    if (!this.isOperationCurrent(operation)) {
      return await this.cancelledState(config, operation);
    }

    // POST activate
    let response: HTTPResult;
    try {
      response = await this.transport.request(
        config,
        config.activateUrl,
        'POST',
        clientIdentity,
        {},
        null
      );
    } catch (err) {
      if (!this.isOperationCurrent(operation)) {
        return await this.cancelledState(config, operation);
      }
      return SetupState.failed(
        config,
        failureDetail(err as Error, '无法连接激活服务'),
        SetupAction.RETRY_ACTIVATION
      );
    }
    if (!this.isOperationCurrent(operation)) {
      return await this.cancelledState(config, operation);
    }

    if (response.status === 401) {
      await this.discardArtifacts(config);
      return SetupState.failed(
        config, '待激活设备身份已被服务器拒绝', SetupAction.RESTART_SETUP
      );
    }

    if (response.status === 202) {
      let parsed: Record<string, Object> | null = null;
      try {
        parsed = JSON.parse(response.body) as Record<string, Object>;
      } catch {
        // ignore parse error
      }
      const code = parsed?.['code'] as string | undefined;
      if (code === 'approval_pending') {
        return SetupState.awaitingApproval(config, pendingExpiresAt);
      }
      return SetupState.failed(
        config, '审批响应无效', SetupAction.RETRY_ACTIVATION
      );
    }

    if (response.status === 503) {
      return SetupState.failed(
        config, '节点暂时不可用，设备身份已保留', SetupAction.RETRY_ACTIVATION
      );
    }

    if (response.status !== 200) {
      return SetupState.failed(
        config, `激活服务返回 ${response.status}`, SetupAction.RETRY_ACTIVATION
      );
    }

    // Decode catalog from activation response
    let catalog: CatalogSnapshot;
    try {
      const json = JSON.parse(response.body) as object;
      catalog = RemoteApiDecoder.decodeCatalog(config, json);
    } catch (err) {
      return SetupState.failed(
        config,
        failureDetail(err as Error, '激活响应无效'),
        SetupAction.RETRY_ACTIVATION
      );
    }

    if (!catalog.computerConnected) {
      return SetupState.failed(
        config, '节点暂时不可用，设备身份已保留', SetupAction.RETRY_ACTIVATION
      );
    }

    // Commit. This synchronous check is deliberately the final cancellation
    // gate: the current path does not await before durable finalization begins.
    if (!this.isOperationCurrent(operation)) {
      return await this.cancelledState(config, operation);
    }

    // The last cancellation gate is deliberately before this
    // critical section: once finalization starts, cancel() waits for it instead
    // of deleting the pending identity out from under promotion.
    let committed: ConnectionConfig;
    try {
      committed = await this.finalizePublic(config);
    } catch (err) {
      return SetupState.failed(
        config,
        failureDetail(err as Error, '连接保存失败'),
        SetupAction.RETRY_ACTIVATION
      );
    }

    return SetupState.ready(committed);
  }

  private async finalizePublic(config: ConnectionConfig): Promise<ConnectionConfig> {
    const alreadyCommitted = await this.settings.isProfileCommitted(config);
    await this.identity.reconcileCredentialPromotion(
      config.installationId,
      alreadyCommitted
    );
    const promotion = await this.identity.promoteCredential(config.installationId);
    let committed: ConnectionConfig;
    try {
      committed = await this.settings.commitStagedProfile();
    } catch (error) {
      // A process interruption can occur after the durable profile generation
      // becomes visible but before the storage call returns. Resolve that
      // ambiguity from durable state before deciding which credential wins.
      const profileCommitted = await this.settings.isProfileCommitted(config);
      if (profileCommitted) {
        committed = config;
      } else {
        try {
          await this.identity.rollbackCredentialPromotion(promotion);
        } catch {
          throw new Error('连接保存失败，且旧设备身份恢复失败');
        }
        throw error as Error;
      }
    }

    try {
      await this.identity.markCredentialPromotionCommitted(promotion);
    } catch {
      // The profile itself proves which side of the cross-store transaction is
      // authoritative. Reconciliation repairs and unlocks the active identity
      // even if writing the final credential marker failed.
      try {
        await this.identity.reconcileCredentialPromotion(config.installationId, true);
      } catch {
        throw new Error('连接已保存，但设备身份完成标记失败');
      }
      try { await this.identity.discardStagedCredential(config.installationId); } catch {}
      try { await this.settings.discardStagedProfile(); } catch {}
      return committed;
    }

    try {
      await this.identity.completeCredentialPromotion(promotion);
    } catch {
      // Cleanup is best-effort, but the promotion journal must not keep a valid
      // committed identity locked for the remainder of this process.
      await this.identity.reconcileCredentialPromotion(config.installationId, true);
      try { await this.identity.discardStagedCredential(config.installationId); } catch {}
    }
    try { await this.settings.discardStagedProfile(); } catch {}
    return committed;
  }
}
