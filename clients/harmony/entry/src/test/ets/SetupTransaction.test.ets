import { DEFAULT, describe, it, expect } from '@ohos/hypium';
import { SetupParser } from '../../main/ets/core/network/SetupParser';
import { RemoteApi } from '../../main/ets/core/network/RemoteApi';
import {
  SetupTransaction, SetupState, SetupStateKind, SetupAction,
  SetupProfileStore, SetupIdentityStore, SetupTransport, HTTPResult
} from '../../main/ets/features/setup/SetupTransaction';
import { ConnectionConfig, ConnectionMode } from '../../main/ets/core/models/ConnectionConfig';
import {
  ClientIdentity, CredentialPromotion
} from '../../main/ets/core/security/CredentialStore';
import { SetupPayload } from '../../main/ets/core/models/SetupPayload';

const INSTALLATION_ID = 'ab'.repeat(32);

interface RequestCall {
  url: string;
  method: string;
  body: string | null;
}

class DeferredVoid {
  readonly promise: Promise<void>;
  private resolver: (() => void) | null = null;

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => {
      this.resolver = resolve;
    });
  }

  resolve(): void {
    if (this.resolver !== null) {
      this.resolver();
      this.resolver = null;
    }
  }
}

class DeferredHTTPResult {
  readonly promise: Promise<HTTPResult>;
  private resolver: ((value: HTTPResult) => void) | null = null;

  constructor() {
    this.promise = new Promise<HTTPResult>((resolve: (value: HTTPResult) => void): void => {
      this.resolver = resolve;
    });
  }

  resolve(value: HTTPResult): void {
    if (this.resolver !== null) {
      this.resolver(value);
      this.resolver = null;
    }
  }
}

// --- Fakes ---

class FakeProfileStore implements SetupProfileStore {
  staged: ConnectionConfig | null = null;
  committed: ConnectionConfig | null = null;
  commitStarted: DeferredVoid | null = null;
  commitGate: DeferredVoid | null = null;
  commitFailuresRemaining = 0;
  commitMutationFailuresRemaining = 0;
  discardFailuresRemaining = 0;

  constructor(stagedProfile: ConnectionConfig | null = null) {
    this.staged = stagedProfile;
  }

  stagedProfile(): ConnectionConfig | null { return this.staged; }
  async stageProfile(value: ConnectionConfig): Promise<void> { this.staged = value; }
  async commitStagedProfile(): Promise<ConnectionConfig> {
    if (this.commitStarted !== null) {
      this.commitStarted.resolve();
    }
    if (this.commitGate !== null) {
      await this.commitGate.promise;
    }
    if (this.commitFailuresRemaining > 0) {
      this.commitFailuresRemaining -= 1;
      throw new Error('injected profile commit failure');
    }
    const profile = this.staged!;
    this.committed = profile;
    if (this.commitMutationFailuresRemaining > 0) {
      this.commitMutationFailuresRemaining -= 1;
      throw new Error('injected post-commit failure');
    }
    return profile;
  }
  async isProfileCommitted(value: ConnectionConfig): Promise<boolean> {
    return this.committed !== null &&
      this.committed.installationId === value.installationId &&
      this.committed.name === value.name &&
      this.committed.mode === value.mode &&
      this.committed.gatewayOrigin === value.gatewayOrigin;
  }
  async discardStagedProfile(): Promise<void> {
    if (this.discardFailuresRemaining > 0) {
      this.discardFailuresRemaining -= 1;
      throw new Error('injected profile cleanup failure');
    }
    this.staged = null;
  }
}

class FakeIdentityStore implements SetupIdentityStore {
  staged = false;
  promoted = false;
  discarded = false;
  stageStarted: DeferredVoid | null = null;
  stageGate: DeferredVoid | null = null;
  promotionStarted: DeferredVoid | null = null;
  promotionGate: DeferredVoid | null = null;
  activeCredential: string | null = null;
  previousActiveCredential: string | null = null;
  rolledBack = false;
  completionFailuresRemaining = 0;
  promotionInProgress = false;
  promotionCommitted = false;

  async credentialPassword(installationId: string): Promise<string> {
    return 'test-password-123';
  }

  async stageCredential(
    installationId: string, encoded: string, password: string, expectedFingerprint: string
  ): Promise<void> {
    if (this.stageStarted !== null) {
      this.stageStarted.resolve();
    }
    if (this.stageGate !== null) {
      await this.stageGate.promise;
    }
    this.staged = true;
  }

  async stagedClientIdentity(installationId: string): Promise<ClientIdentity> {
    if (!this.staged) throw new Error('not found');
    return {
      certPath: '/test/identity.p12',
      keyPath: '',
      password: '',
      privateKeyPath: '/test/identity-key.pem',
      certificateChainPath: '/test/identity-chain.pem'
    };
  }

  async promoteCredential(installationId: string): Promise<CredentialPromotion> {
    if (!this.staged) throw new Error('not found');
    if (this.promotionStarted !== null) {
      this.promotionStarted.resolve();
    }
    if (this.promotionGate !== null) {
      await this.promotionGate.promise;
    }
    if (!this.staged) throw new Error('not found');
    this.previousActiveCredential = this.activeCredential;
    const promotion = new CredentialPromotion(
      installationId,
      this.previousActiveCredential !== null
    );
    this.activeCredential = 'pending';
    this.promoted = true;
    this.promotionInProgress = true;
    this.promotionCommitted = false;
    return promotion;
  }

  async markCredentialPromotionCommitted(promotion: CredentialPromotion): Promise<void> {
    if (!this.promotionInProgress) throw new Error('no promotion');
    this.promotionCommitted = true;
  }

  async reconcileCredentialPromotion(
    installationId: string, profileCommitted: boolean
  ): Promise<void> {
    if (!this.promotionInProgress) return;
    if (profileCommitted || this.promotionCommitted) {
      this.activeCredential = 'pending';
    } else {
      this.activeCredential = this.previousActiveCredential;
      this.rolledBack = true;
    }
    this.promotionInProgress = false;
    this.promotionCommitted = false;
  }

  async rollbackCredentialPromotion(promotion: CredentialPromotion): Promise<void> {
    this.activeCredential = promotion.hadPreviousCredential
      ? this.previousActiveCredential
      : null;
    this.rolledBack = true;
    this.promotionInProgress = false;
    this.promotionCommitted = false;
  }

  async completeCredentialPromotion(promotion: CredentialPromotion): Promise<void> {
    if (this.completionFailuresRemaining > 0) {
      this.completionFailuresRemaining -= 1;
      throw new Error('injected credential cleanup failure');
    }
    this.staged = false;
    this.discarded = true;
    this.promotionInProgress = false;
    this.promotionCommitted = false;
  }

  async hasStagedCredential(installationId: string): Promise<boolean> {
    return this.staged;
  }

  async discardStagedCredential(installationId: string): Promise<void> {
    this.discarded = true;
    this.staged = false;
  }
}

class FakeTransport implements SetupTransport {
  verifyCalls = 0;
  requestCalls: RequestCall[] = [];
  activateResponses: HTTPResult[] = [];
  verifyStarted: DeferredVoid | null = null;
  verifyGate: DeferredVoid | null = null;
  activationStarted: DeferredVoid | null = null;
  activationGate: DeferredHTTPResult | null = null;
  pairResponse: HTTPResult = {
    status: 200,
    body: JSON.stringify({
      'ok': true,
      'device_name': 'device',
      'certificate_fingerprint': 'cd'.repeat(32),
      'credential_format': 'pkcs12',
      'credential_pkcs12': 'dGVzdA==',
      'pending_expires_at': '2027-01-01T00:00:00Z'
    })
  };
  activateResponse: HTTPResult = {
    status: 200,
    body: JSON.stringify({ 'ok': true, 'computer_connected': true, 'code': 'ready', 'apps': [] })
  };

  async verifyCatalog(config: ConnectionConfig): Promise<void> {
    this.verifyCalls += 1;
    if (this.verifyStarted !== null) {
      this.verifyStarted.resolve();
    }
    if (this.verifyGate !== null) {
      await this.verifyGate.promise;
    }
  }

  async request(
    config: ConnectionConfig, url: string, method: string,
    identity: ClientIdentity | null, headers: Record<string, string>, body: string | null
  ): Promise<HTTPResult> {
    const call: RequestCall = { url: url, method: method, body: body };
    this.requestCalls.push(call);
    if (url.includes('pair')) return this.pairResponse;
    if (this.activationStarted !== null) {
      this.activationStarted.resolve();
    }
    if (this.activationGate !== null) {
      return await this.activationGate.promise;
    }
    if (this.activateResponses.length > 0) return this.activateResponses.shift()!;
    return this.activateResponse;
  }
}

enum DurableProfileFailure {
  NONE = 'none',
  BEFORE_PUBLISH = 'before_publish',
  AFTER_PUBLISH = 'after_publish'
}

class DurableProfileState {
  staged: ConnectionConfig | null = null;
  generations: ConnectionConfig[][] = [];
  unpublished: ConnectionConfig[] | null = null;
  failure: DurableProfileFailure = DurableProfileFailure.NONE;
}

class RestartableProfileStore implements SetupProfileStore {
  private state: DurableProfileState;

  constructor(state: DurableProfileState) {
    this.state = state;
  }

  stagedProfile(): ConnectionConfig | null { return this.state.staged; }
  async stageProfile(value: ConnectionConfig): Promise<void> { this.state.staged = value; }

  async commitStagedProfile(): Promise<ConnectionConfig> {
    const staged = this.state.staged;
    if (staged === null) throw new Error('not staged');
    const previous = this.latest();
    const next = previous.filter((value: ConnectionConfig): boolean =>
      value.installationId !== staged.installationId
    );
    next.push(staged);
    this.state.unpublished = next;
    if (this.state.failure === DurableProfileFailure.BEFORE_PUBLISH) {
      this.state.failure = DurableProfileFailure.NONE;
      throw new Error('injected pre-publish failure');
    }
    this.state.generations.push(next);
    this.state.unpublished = null;
    if (this.state.failure === DurableProfileFailure.AFTER_PUBLISH) {
      this.state.failure = DurableProfileFailure.NONE;
      throw new Error('injected post-publish failure');
    }
    return staged;
  }

  async isProfileCommitted(value: ConnectionConfig): Promise<boolean> {
    return this.latest().some((profile: ConnectionConfig): boolean =>
      RestartableProfileStore.same(profile, value)
    );
  }

  async discardStagedProfile(): Promise<void> { this.state.staged = null; }

  latest(): ConnectionConfig[] {
    if (this.state.generations.length === 0) return [];
    return this.state.generations[this.state.generations.length - 1].slice();
  }

  private static same(left: ConnectionConfig, right: ConnectionConfig): boolean {
    return left.installationId === right.installationId && left.name === right.name &&
      left.mode === right.mode && left.gatewayOrigin === right.gatewayOrigin &&
      left.gatewayFingerprint === right.gatewayFingerprint &&
      left.gatewayPublicKeyPin === right.gatewayPublicKeyPin &&
      left.accessToken === right.accessToken;
  }
}

enum DurablePromotionBase {
  NONE = 'none',
  PREVIOUS = 'previous',
  NEW = 'new'
}

class DurableCredentialState {
  pendingFile: string | null = null;
  pendingPassword: string | null = null;
  activeFile: string | null = null;
  activePassword: string | null = null;
  rollbackFile: string | null = null;
  rollbackPassword: string | null = null;
  promotionBase: DurablePromotionBase = DurablePromotionBase.NONE;
  installedMarker = false;
  committedMarker = false;
}

class RestartableIdentityStore implements SetupIdentityStore {
  private state: DurableCredentialState;

  constructor(state: DurableCredentialState) {
    this.state = state;
  }

  async credentialPassword(installationId: string): Promise<string> {
    if (this.state.pendingPassword === null) this.state.pendingPassword = 'new-password';
    return this.state.pendingPassword;
  }

  async stageCredential(
    installationId: string, encoded: string, password: string, expectedFingerprint: string
  ): Promise<void> {
    this.state.pendingFile = 'new-file';
    this.state.pendingPassword = password;
  }

  async stagedClientIdentity(installationId: string): Promise<ClientIdentity> {
    if (this.state.pendingFile === null || this.state.pendingPassword === null) {
      throw new Error('pending missing');
    }
    return {
      certPath: '/pending.p12', keyPath: '', password: this.state.pendingPassword,
      privateKeyPath: '/pending-key.pem', certificateChainPath: '/pending-chain.pem'
    };
  }

  async promoteCredential(installationId: string): Promise<CredentialPromotion> {
    if (this.state.pendingFile === null || this.state.pendingPassword === null) {
      throw new Error('pending missing');
    }
    if (this.state.promotionBase !== DurablePromotionBase.NONE) {
      throw new Error('promotion unresolved');
    }
    const hadPrevious = this.state.activeFile !== null && this.state.activePassword !== null;
    if (hadPrevious) {
      this.state.rollbackFile = this.state.activeFile;
      this.state.rollbackPassword = this.state.activePassword;
    }
    this.state.promotionBase = hadPrevious
      ? DurablePromotionBase.PREVIOUS
      : DurablePromotionBase.NEW;
    this.state.activePassword = this.state.pendingPassword;
    this.state.activeFile = this.state.pendingFile;
    this.state.installedMarker = true;
    return new CredentialPromotion(installationId, hadPrevious);
  }

  async markCredentialPromotionCommitted(promotion: CredentialPromotion): Promise<void> {
    if (!this.state.installedMarker) throw new Error('not installed');
    this.state.committedMarker = true;
  }

  async reconcileCredentialPromotion(
    installationId: string, profileCommitted: boolean
  ): Promise<void> {
    if (this.state.promotionBase === DurablePromotionBase.NONE) return;
    if (profileCommitted || this.state.committedMarker) {
      if (this.state.pendingFile !== null && this.state.pendingPassword !== null) {
        this.state.activeFile = this.state.pendingFile;
        this.state.activePassword = this.state.pendingPassword;
      } else if (this.state.activeFile !== null && this.state.activePassword !== null) {
        this.state.pendingFile = this.state.activeFile;
        this.state.pendingPassword = this.state.activePassword;
      } else {
        throw new Error('committed identity missing');
      }
    } else if (this.state.promotionBase === DurablePromotionBase.PREVIOUS) {
      if (this.state.rollbackFile === null || this.state.rollbackPassword === null) {
        throw new Error('rollback incomplete');
      }
      this.state.activeFile = this.state.rollbackFile;
      this.state.activePassword = this.state.rollbackPassword;
    } else {
      this.state.activeFile = null;
      this.state.activePassword = null;
    }
    this.clearJournal();
  }

  async rollbackCredentialPromotion(promotion: CredentialPromotion): Promise<void> {
    await this.reconcileCredentialPromotion(promotion.installationId, false);
  }

  async completeCredentialPromotion(promotion: CredentialPromotion): Promise<void> {
    if (!this.state.committedMarker) throw new Error('not committed');
    this.state.pendingFile = null;
    this.state.pendingPassword = null;
    this.clearJournal();
  }

  async hasStagedCredential(installationId: string): Promise<boolean> {
    return this.state.pendingFile !== null && this.state.pendingPassword !== null;
  }

  async discardStagedCredential(installationId: string): Promise<void> {
    if (this.state.promotionBase !== DurablePromotionBase.NONE) {
      throw new Error('promotion unresolved');
    }
    this.state.pendingFile = null;
    this.state.pendingPassword = null;
  }

  private clearJournal(): void {
    this.state.rollbackFile = null;
    this.state.rollbackPassword = null;
    this.state.promotionBase = DurablePromotionBase.NONE;
    this.state.installedMarker = false;
    this.state.committedMarker = false;
  }
}

function publicConfig(name: string, origin: string): ConnectionConfig {
  return SetupParser.create(INSTALLATION_ID, name, 'public', origin);
}

function oldAndPendingCredential(): DurableCredentialState {
  const state = new DurableCredentialState();
  state.pendingFile = 'new-file';
  state.pendingPassword = 'new-password';
  state.activeFile = 'old-file';
  state.activePassword = 'old-password';
  return state;
}

async function recoverAfterRestart(
  profiles: DurableProfileState,
  credentials: DurableCredentialState
): Promise<ConnectionConfig | null> {
  const transaction = new SetupTransaction(
    new RestartableProfileStore(profiles),
    new RestartableIdentityStore(credentials),
    'restarted device',
    new FakeTransport()
  );
  return await transaction.recover();
}

// --- Tests ---

export default function setupTransactionTest() {
  describe('SetupTransaction', () => {

    it('lan_connection_verifies_before_committing', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const transport = new FakeTransport();

      const transaction = new SetupTransaction(
        store, new FakeIdentityStore(), 'Test Device', transport
      );

      const config = SetupParser.create(
        INSTALLATION_ID, 'Test LAN', 'lan',
        'https://192.168.1.5:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '=', '01'.repeat(32)
      );

      const result = await transaction.begin(new SetupPayload(config, ''));

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(transport.verifyCalls).assertEqual(1);
      expect(store.committed).not().assertNull();
    });

    it('cancel_discards_an_existing_staged_transaction', DEFAULT, async () => {
      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const store = new FakeProfileStore(config);
      const identityStore = new FakeIdentityStore();
      identityStore.staged = true;
      const transaction = new SetupTransaction(
        store, identityStore, 'device', new FakeTransport()
      );

      await transaction.cancel();

      expect(store.staged).assertNull();
      expect(store.committed).assertNull();
      expect(identityStore.staged).assertFalse();
      expect(identityStore.discarded).assertTrue();
      expect(identityStore.promoted).assertFalse();
    });

    it('cancel_during_lan_verification_prevents_commit', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      const transport = new FakeTransport();
      transport.verifyStarted = new DeferredVoid();
      transport.verifyGate = new DeferredVoid();
      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );
      const config = SetupParser.create(
        INSTALLATION_ID, 'LAN', 'lan',
        'https://192.168.1.5:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '=', '01'.repeat(32)
      );

      const resultPromise = transaction.begin(new SetupPayload(config, ''));
      await transport.verifyStarted.promise;
      const cancelPromise = transaction.cancel();
      transport.verifyGate.resolve();
      const result = await resultPromise;
      await cancelPromise;

      expect(result.kind).assertEqual(SetupStateKind.FAILED);
      expect(store.staged).assertNull();
      expect(store.committed).assertNull();
      expect(identityStore.promoted).assertFalse();
    });

    it('cancel_during_lan_commit_finishes_ready_without_split_state', DEFAULT, async () => {
      const store = new FakeProfileStore();
      store.commitStarted = new DeferredVoid();
      store.commitGate = new DeferredVoid();
      const identityStore = new FakeIdentityStore();
      const transaction = new SetupTransaction(
        store, identityStore, 'device', new FakeTransport()
      );
      const config = SetupParser.create(
        INSTALLATION_ID, 'LAN', 'lan',
        'https://192.168.1.5:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '=', '01'.repeat(32)
      );

      const resultPromise = transaction.begin(new SetupPayload(config, ''));
      await store.commitStarted.promise;
      const cancelPromise = transaction.cancel();
      store.commitGate.resolve();
      const result = await resultPromise;
      await cancelPromise;

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(store.committed).not().assertNull();
      expect(store.staged).assertNull();
      expect(identityStore.promoted).assertFalse();
    });

    it('cancel_during_credential_staging_cleans_the_late_write', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      identityStore.stageStarted = new DeferredVoid();
      identityStore.stageGate = new DeferredVoid();
      const transport = new FakeTransport();
      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );

      const resultPromise = transaction.begin(
        new SetupPayload(config, 'A'.repeat(43))
      );
      await identityStore.stageStarted.promise;
      const cancelPromise = transaction.cancel();
      identityStore.stageGate.resolve();
      const result = await resultPromise;
      await cancelPromise;

      expect(result.kind).assertEqual(SetupStateKind.FAILED);
      expect(store.staged).assertNull();
      expect(store.committed).assertNull();
      expect(identityStore.staged).assertFalse();
      expect(identityStore.promoted).assertFalse();
      expect(transport.requestCalls.filter((call) => call.url.includes('activate')).length).assertEqual(0);
    });

    it('cancel_during_activation_prevents_promotion_and_commit', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      const transport = new FakeTransport();
      transport.activationStarted = new DeferredVoid();
      transport.activationGate = new DeferredHTTPResult();
      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const setup = new SetupPayload(config, 'A'.repeat(43));
      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );

      const resultPromise = transaction.begin(setup);
      await transport.activationStarted.promise;
      expect(identityStore.staged).assertTrue();
      const cancelPromise = transaction.cancel();
      transport.activationGate.resolve(transport.activateResponse);
      const result = await resultPromise;
      await cancelPromise;

      expect(result.kind).assertEqual(SetupStateKind.FAILED);
      expect(store.staged).assertNull();
      expect(store.committed).assertNull();
      expect(identityStore.staged).assertFalse();
      expect(identityStore.discarded).assertTrue();
      expect(identityStore.promoted).assertFalse();
    });

    it('cancel_after_finalization_barrier_keeps_profile_and_identity_consistent', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      identityStore.promotionStarted = new DeferredVoid();
      identityStore.promotionGate = new DeferredVoid();
      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const transaction = new SetupTransaction(
        store, identityStore, 'device', new FakeTransport()
      );

      const resultPromise = transaction.begin(
        new SetupPayload(config, 'A'.repeat(43))
      );
      await identityStore.promotionStarted.promise;
      const cancelPromise = transaction.cancel();
      identityStore.promotionGate.resolve();
      const result = await resultPromise;
      await cancelPromise;

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(store.committed).not().assertNull();
      expect(store.staged).assertNull();
      expect(identityStore.promoted).assertTrue();
      expect(identityStore.staged).assertFalse();
    });

    it('profile_commit_failure_restores_old_identity_and_activation_is_retryable', DEFAULT, async () => {
      const oldConfig = SetupParser.create(
        INSTALLATION_ID, 'Old Public', 'public',
        'https://old.example.com'
      );
      const config = SetupParser.create(
        INSTALLATION_ID, 'New Public', 'public',
        'https://remote.example.com'
      );
      const store = new FakeProfileStore();
      store.committed = oldConfig;
      store.commitFailuresRemaining = 1;
      const identityStore = new FakeIdentityStore();
      identityStore.activeCredential = 'old-active';
      const transport = new FakeTransport();
      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );

      const first = await transaction.begin(
        new SetupPayload(config, 'A'.repeat(43))
      );

      expect(first.kind).assertEqual(SetupStateKind.FAILED);
      expect(first.action).assertEqual(SetupAction.RETRY_ACTIVATION);
      expect(store.committed?.name).assertEqual('Old Public');
      expect(store.staged?.name).assertEqual('New Public');
      expect(identityStore.activeCredential).assertEqual('old-active');
      expect(identityStore.staged).assertTrue();
      expect(identityStore.rolledBack).assertTrue();

      const second = await transaction.retryActivation(config);

      expect(second.kind).assertEqual(SetupStateKind.READY);
      expect(store.committed?.name).assertEqual('New Public');
      expect(store.staged).assertNull();
      expect(identityStore.activeCredential).assertEqual('pending');
      expect(identityStore.staged).assertFalse();
      expect(transport.requestCalls.filter((call) => call.url.includes('pair')).length).assertEqual(1);
      expect(transport.requestCalls.filter((call) => call.url.includes('activate')).length).assertEqual(2);
    });

    it('profile_commit_failure_removes_new_active_when_no_old_identity_exists', DEFAULT, async () => {
      const store = new FakeProfileStore();
      store.commitFailuresRemaining = 1;
      const identityStore = new FakeIdentityStore();
      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const transaction = new SetupTransaction(
        store, identityStore, 'device', new FakeTransport()
      );

      const result = await transaction.begin(
        new SetupPayload(config, 'A'.repeat(43))
      );

      expect(result.kind).assertEqual(SetupStateKind.FAILED);
      expect(result.action).assertEqual(SetupAction.RETRY_ACTIVATION);
      expect(store.committed).assertNull();
      expect(store.staged).not().assertNull();
      expect(identityStore.activeCredential).assertNull();
      expect(identityStore.staged).assertTrue();
      expect(identityStore.rolledBack).assertTrue();
    });

    it('cancel_during_failed_finalization_waits_for_rollback_then_cleans_staging', DEFAULT, async () => {
      const oldConfig = SetupParser.create(
        INSTALLATION_ID, 'Old Public', 'public',
        'https://old.example.com'
      );
      const config = SetupParser.create(
        INSTALLATION_ID, 'New Public', 'public',
        'https://remote.example.com'
      );
      const store = new FakeProfileStore();
      store.committed = oldConfig;
      store.commitFailuresRemaining = 1;
      const identityStore = new FakeIdentityStore();
      identityStore.activeCredential = 'old-active';
      identityStore.promotionStarted = new DeferredVoid();
      identityStore.promotionGate = new DeferredVoid();
      const transaction = new SetupTransaction(
        store, identityStore, 'device', new FakeTransport()
      );

      const resultPromise = transaction.begin(
        new SetupPayload(config, 'A'.repeat(43))
      );
      await identityStore.promotionStarted.promise;
      const cancelPromise = transaction.cancel();
      identityStore.promotionGate.resolve();
      await resultPromise;
      await cancelPromise;

      expect(store.committed?.name).assertEqual('Old Public');
      expect(store.staged).assertNull();
      expect(identityStore.activeCredential).assertEqual('old-active');
      expect(identityStore.staged).assertFalse();
      expect(identityStore.rolledBack).assertTrue();
    });

    it('lan_cleanup_failure_after_commit_still_returns_ready', DEFAULT, async () => {
      const store = new FakeProfileStore();
      store.discardFailuresRemaining = 1;
      const config = SetupParser.create(
        INSTALLATION_ID, 'LAN', 'lan',
        'https://192.168.1.5:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '=', '01'.repeat(32)
      );
      const transaction = new SetupTransaction(
        store, new FakeIdentityStore(), 'device', new FakeTransport()
      );

      const result = await transaction.begin(new SetupPayload(config, ''));

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(store.committed).not().assertNull();
      expect(store.staged).not().assertNull();
    });

    it('public_cleanup_failures_after_commit_still_return_ready', DEFAULT, async () => {
      const store = new FakeProfileStore();
      store.discardFailuresRemaining = 1;
      const identityStore = new FakeIdentityStore();
      identityStore.completionFailuresRemaining = 1;
      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const transaction = new SetupTransaction(
        store, identityStore, 'device', new FakeTransport()
      );

      const result = await transaction.begin(
        new SetupPayload(config, 'A'.repeat(43))
      );

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(store.committed).not().assertNull();
      expect(store.staged).not().assertNull();
      expect(identityStore.activeCredential).assertEqual('pending');
      expect(identityStore.staged).assertFalse();
    });

    it('public_pairing_commits_after_activation', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      const transport = new FakeTransport();

      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );

      const config = SetupParser.create(
        INSTALLATION_ID, 'Test Public', 'public',
        'https://remote.example.com'
      );

      const result = await transaction.begin(new SetupPayload(config, 'A'.repeat(43)));

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(identityStore.promoted).assertTrue();
      expect(identityStore.staged).assertFalse();
    });

    it('activation_failure_retries_without_pairing_again', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      const transport = new FakeTransport();

      transport.activateResponses = [
        { status: 503, body: '' },
        transport.activateResponse
      ];

      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const setup = new SetupPayload(config, 'A'.repeat(43));

      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );

      const first = await transaction.begin(setup);
      expect(first.kind).assertEqual(SetupStateKind.FAILED);
      expect(first.action).assertEqual(SetupAction.RETRY_ACTIVATION);
      expect(identityStore.staged).assertTrue();

      const second = await transaction.retryActivation(config);
      expect(second.kind).assertEqual(SetupStateKind.READY);
      expect(transport.requestCalls.filter((call) => call.url.includes('activate')).length).assertEqual(2);
    });

    it('approval_pending_continues_without_re_pairing', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      const transport = new FakeTransport();

      transport.activateResponses = [
        { status: 202, body: '{"ok":false,"code":"approval_pending"}' },
        transport.activateResponse
      ];

      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const setup = new SetupPayload(config, 'A'.repeat(43));

      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );

      const first = await transaction.begin(setup);
      expect(first.kind).assertEqual(SetupStateKind.AWAITING_APPROVAL);
      expect(identityStore.staged).assertTrue();

      const second = await transaction.retryActivation(config);
      expect(second.kind).assertEqual(SetupStateKind.READY);
      expect(transport.requestCalls.filter((call) => call.url.includes('activate')).length).assertEqual(2);
    });

    it('denied_invitation_discards_local_transaction', DEFAULT, async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      const transport = new FakeTransport();
      transport.pairResponse = { status: 401, body: '' };

      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const setup = new SetupPayload(config, 'A'.repeat(43));

      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );

      const result = await transaction.begin(setup);
      expect(result.kind).assertEqual(SetupStateKind.FAILED);
      expect(result.action).assertEqual(SetupAction.RESTART_SETUP);
    });

    it('restart_after_rollback_p12_copy_before_password_keeps_old_identity', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.staged = nextConfig;
      const credentials = oldAndPendingCredential();
      credentials.rollbackFile = 'old-file';

      const recovered = await recoverAfterRestart(profiles, credentials);

      expect(recovered?.name).assertEqual('New');
      expect(credentials.activeFile).assertEqual('old-file');
      expect(credentials.activePassword).assertEqual('old-password');
    });

    it('restart_after_rollback_password_before_marker_keeps_old_identity', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.staged = nextConfig;
      const credentials = oldAndPendingCredential();
      credentials.rollbackFile = 'old-file';
      credentials.rollbackPassword = 'old-password';

      await recoverAfterRestart(profiles, credentials);

      expect(credentials.activeFile).assertEqual('old-file');
      expect(credentials.activePassword).assertEqual('old-password');
    });

    it('restart_after_marker_before_active_password_restores_old_identity', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.staged = nextConfig;
      const credentials = oldAndPendingCredential();
      credentials.rollbackFile = 'old-file';
      credentials.rollbackPassword = 'old-password';
      credentials.promotionBase = DurablePromotionBase.PREVIOUS;

      await recoverAfterRestart(profiles, credentials);

      expect(credentials.activeFile).assertEqual('old-file');
      expect(credentials.activePassword).assertEqual('old-password');
      expect(credentials.promotionBase).assertEqual(DurablePromotionBase.NONE);
    });

    it('restart_between_active_password_and_p12_rename_restores_old_identity', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.staged = nextConfig;
      const credentials = oldAndPendingCredential();
      credentials.rollbackFile = 'old-file';
      credentials.rollbackPassword = 'old-password';
      credentials.promotionBase = DurablePromotionBase.PREVIOUS;
      credentials.activePassword = 'new-password';

      await recoverAfterRestart(profiles, credentials);

      expect(credentials.activeFile).assertEqual('old-file');
      expect(credentials.activePassword).assertEqual('old-password');
    });

    it('restart_after_active_unlink_before_rename_restores_old_identity', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.staged = nextConfig;
      const credentials = oldAndPendingCredential();
      credentials.rollbackFile = 'old-file';
      credentials.rollbackPassword = 'old-password';
      credentials.promotionBase = DurablePromotionBase.PREVIOUS;
      credentials.activeFile = null;
      credentials.activePassword = 'new-password';

      await recoverAfterRestart(profiles, credentials);

      expect(credentials.activeFile).assertEqual('old-file');
      expect(credentials.activePassword).assertEqual('old-password');
    });

    it('restart_after_active_rename_before_profile_publish_restores_old_identity', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.staged = nextConfig;
      const credentials = oldAndPendingCredential();
      credentials.rollbackFile = 'old-file';
      credentials.rollbackPassword = 'old-password';
      credentials.promotionBase = DurablePromotionBase.PREVIOUS;
      credentials.activeFile = 'new-file';
      credentials.activePassword = 'new-password';
      credentials.installedMarker = true;

      await recoverAfterRestart(profiles, credentials);

      expect(credentials.activeFile).assertEqual('old-file');
      expect(credentials.activePassword).assertEqual('old-password');
    });

    it('restart_after_profile_publish_before_credential_marker_rolls_forward', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.generations.push([nextConfig]);
      profiles.staged = nextConfig;
      const credentials = oldAndPendingCredential();
      credentials.rollbackFile = 'old-file';
      credentials.rollbackPassword = 'old-password';
      credentials.promotionBase = DurablePromotionBase.PREVIOUS;
      credentials.activeFile = 'new-file';
      credentials.activePassword = 'new-password';
      credentials.installedMarker = true;

      const recovered = await recoverAfterRestart(profiles, credentials);

      expect(recovered?.name).assertEqual('New');
      expect(credentials.activeFile).assertEqual('new-file');
      expect(credentials.activePassword).assertEqual('new-password');
      expect(credentials.promotionBase).assertEqual(DurablePromotionBase.NONE);
    });

    it('restart_after_credential_commit_marker_is_idempotent', DEFAULT, async () => {
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([nextConfig]);
      profiles.staged = nextConfig;
      const credentials = oldAndPendingCredential();
      credentials.rollbackFile = 'old-file';
      credentials.rollbackPassword = 'old-password';
      credentials.promotionBase = DurablePromotionBase.PREVIOUS;
      credentials.activeFile = 'new-file';
      credentials.activePassword = 'new-password';
      credentials.installedMarker = true;
      credentials.committedMarker = true;

      await recoverAfterRestart(profiles, credentials);
      await recoverAfterRestart(profiles, credentials);

      expect(credentials.activeFile).assertEqual('new-file');
      expect(credentials.activePassword).assertEqual('new-password');
      expect(credentials.promotionBase).assertEqual(DurablePromotionBase.NONE);
    });

    it('restart_mid_install_without_previous_identity_removes_partial_active', DEFAULT, async () => {
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.staged = nextConfig;
      const credentials = new DurableCredentialState();
      credentials.pendingFile = 'new-file';
      credentials.pendingPassword = 'new-password';
      credentials.activePassword = 'new-password';
      credentials.promotionBase = DurablePromotionBase.NEW;

      const recovered = await recoverAfterRestart(profiles, credentials);

      expect(recovered?.name).assertEqual('New');
      expect(credentials.activeFile).assertNull();
      expect(credentials.activePassword).assertNull();
      expect(credentials.pendingFile).assertEqual('new-file');
    });

    it('profile_failure_before_publish_restarts_on_old_generation', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.staged = nextConfig;
      profiles.failure = DurableProfileFailure.BEFORE_PUBLISH;
      const credentials = oldAndPendingCredential();
      const transaction = new SetupTransaction(
        new RestartableProfileStore(profiles), new RestartableIdentityStore(credentials),
        'device', new FakeTransport()
      );

      const result = await transaction.retryActivation(nextConfig);
      const recovered = await recoverAfterRestart(profiles, credentials);

      expect(result.kind).assertEqual(SetupStateKind.FAILED);
      expect(recovered?.name).assertEqual('New');
      expect(credentials.activeFile).assertEqual('old-file');
      expect(new RestartableProfileStore(profiles).latest()[0].name).assertEqual('Old');
    });

    it('profile_mutation_then_failure_restarts_on_new_generation', DEFAULT, async () => {
      const oldConfig = publicConfig('Old', 'https://old.example.com');
      const nextConfig = publicConfig('New', 'https://new.example.com');
      const profiles = new DurableProfileState();
      profiles.generations.push([oldConfig]);
      profiles.staged = nextConfig;
      profiles.failure = DurableProfileFailure.AFTER_PUBLISH;
      const credentials = oldAndPendingCredential();
      const transaction = new SetupTransaction(
        new RestartableProfileStore(profiles), new RestartableIdentityStore(credentials),
        'device', new FakeTransport()
      );

      const result = await transaction.retryActivation(nextConfig);
      const restartedProfiles = new RestartableProfileStore(profiles);
      const restartedIdentity = new RestartableIdentityStore(credentials);

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(restartedProfiles.latest()[0].name).assertEqual('New');
      expect(credentials.activeFile).assertEqual('new-file');
      expect(await restartedIdentity.hasStagedCredential(INSTALLATION_ID)).assertFalse();
    });

    it('cancel_and_immediate_same_installation_begin_isolated_from_stale_cleanup', DEFAULT, async () => {
      const config = publicConfig('Public', 'https://remote.example.com');
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      identityStore.stageStarted = new DeferredVoid();
      identityStore.stageGate = new DeferredVoid();
      const transaction = new SetupTransaction(
        store, identityStore, 'device', new FakeTransport()
      );

      const staleResult = transaction.begin(new SetupPayload(config, 'A'.repeat(43)));
      await identityStore.stageStarted.promise;
      const cancelPromise = transaction.cancel();
      const freshResultPromise = transaction.begin(new SetupPayload(config, 'A'.repeat(43)));
      identityStore.stageGate.resolve();
      await cancelPromise;
      await staleResult;
      const freshResult = await freshResultPromise;

      expect(freshResult.kind).assertEqual(SetupStateKind.READY);
      expect(store.committed?.name).assertEqual('Public');
      expect(identityStore.activeCredential).assertEqual('pending');
    });

    it('recovery_only_returns_activatable_public_transaction', DEFAULT, async () => {
      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );

      const store = new FakeProfileStore(config);
      const identityStore = new FakeIdentityStore();
      identityStore.staged = true;

      const transaction = new SetupTransaction(
        store, identityStore, 'device', new FakeTransport()
      );

      const recovered = await transaction.recover();
      expect(recovered).not().assertNull();

      // LAN staged should not be recoverable
      const lanConfig = SetupParser.create(
        INSTALLATION_ID, 'LAN', 'lan',
        'https://192.168.1.5:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '=', '01'.repeat(32)
      );
      store.staged = lanConfig;
      identityStore.staged = false;
      const lanRecovered = await transaction.recover();
      expect(lanRecovered).assertNull();
    });
  });
}
