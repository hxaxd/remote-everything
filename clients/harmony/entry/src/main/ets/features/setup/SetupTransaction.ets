import { ConnectionConfig, ConnectionMode } from '../../core/models/ConnectionConfig';
import { SetupPayload } from '../../core/models/SetupPayload';
import { CatalogSnapshot } from '../../core/models/RemoteApp';
import { PairingCredential } from '../../core/models/PairingCredential';
import { RemoteApi as RemoteApiDecoder } from '../../core/network/RemoteApi';
import { ClientIdentity, CredentialStore } from '../../core/security/CredentialStore';
import { GatewaySecurityPolicy } from '../../core/security/GatewaySecurityPolicy';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

// MARK: - Protocols

export interface SetupProfileStore {
  stagedProfile(): ConnectionConfig | null;
  stageProfile(value: ConnectionConfig): Promise<void>;
  commitStagedProfile(): Promise<ConnectionConfig>;
  discardStagedProfile(): Promise<void>;
}

export interface SetupIdentityStore {
  credentialPassword(installationId: string): Promise<string>;
  stageCredential(
    installationId: string, encoded: string, password: string, expectedFingerprint: string
  ): Promise<void>;
  stagedClientIdentity(installationId: string): Promise<ClientIdentity>;
  promoteCredential(installationId: string): Promise<void>;
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

  async promoteCredential(installationId: string): Promise<void> {
    await CredentialStore.promoteCredential(installationId);
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

// MARK: - Transaction

export class SetupTransaction {
  private settings: SetupProfileStore;
  private identity: SetupIdentityStore;
  private deviceName: string;
  private transport: SetupTransport;

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
    await this.discardPending();

    if (setup.profile.mode === ConnectionMode.LAN) {
      return await this.connectLAN(setup.profile);
    } else {
      return await this.pair(setup);
    }
  }

  async retryPairing(setup: SetupPayload): Promise<SetupState> {
    return await this.pair(setup);
  }

  async retryActivation(config: ConnectionConfig): Promise<SetupState> {
    return await this.activate(config, null);
  }

  async discardPending(): Promise<void> {
    const staged = this.settings.stagedProfile();
    if (staged === null) {
      return;
    }
    await this.identity.discardStagedCredential(staged.installationId);
    await this.settings.discardStagedProfile();
  }

  async cancel(): Promise<void> {
    await this.discardPending();
  }

  // MARK: - Private Steps

  private async connectLAN(config: ConnectionConfig): Promise<SetupState> {
    try {
      await this.transport.verifyCatalog(config);
      await this.settings.stageProfile(config);
      const committed = await this.settings.commitStagedProfile();
      await this.settings.discardStagedProfile();
      return SetupState.ready(committed);
    } catch (err) {
      await this.discardPending();
      return SetupState.failed(
        config,
        failureDetail(err as Error, '局域网连接验证失败'),
        SetupAction.RESTART_SETUP
      );
    }
  }

  private async pair(setup: SetupPayload): Promise<SetupState> {
    const config = setup.profile;
    await this.settings.stageProfile(config);

    // Generate credential password
    let password: string;
    try {
      password = await this.identity.credentialPassword(config.installationId);
    } catch (err) {
      await this.discardPending();
      return SetupState.failed(
        config,
        failureDetail(err as Error, '无法创建设备身份'),
        SetupAction.RESTART_SETUP
      );
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
      return SetupState.failed(
        config,
        failureDetail(err as Error, '无法连接配对服务'),
        SetupAction.RETRY_PAIRING
      );
    }

    if (response.status === 401) {
      await this.discardPending();
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
      await this.discardPending();
      return SetupState.failed(
        config,
        failureDetail(err as Error, '设备身份保存失败'),
        SetupAction.RESTART_SETUP
      );
    }

    return await this.activate(config, credential.pendingExpiresAt);
  }

  private async activate(
    config: ConnectionConfig,
    pendingExpiresAt: string | null
  ): Promise<SetupState> {
    // Load staged client identity
    let clientIdentity: ClientIdentity;
    try {
      clientIdentity = await this.identity.stagedClientIdentity(config.installationId);
    } catch {
      await this.discardPending();
      return SetupState.failed(
        config, '待激活设备身份已丢失', SetupAction.RESTART_SETUP
      );
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
      return SetupState.failed(
        config,
        failureDetail(err as Error, '无法连接激活服务'),
        SetupAction.RETRY_ACTIVATION
      );
    }

    if (response.status === 401) {
      await this.discardPending();
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

    // Commit
    let committed: ConnectionConfig;
    try {
      await this.identity.promoteCredential(config.installationId);
      committed = await this.settings.commitStagedProfile();
    } catch (err) {
      return SetupState.failed(
        config,
        failureDetail(err as Error, '连接保存失败'),
        SetupAction.RETRY_ACTIVATION
      );
    }

    // Clean up
    try { await this.identity.discardStagedCredential(config.installationId); } catch {}
    await this.settings.discardStagedProfile();

    return SetupState.ready(committed);
  }
}
