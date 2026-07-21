import { describe, it, expect } from '@ohos/hypium';
import { SetupParser } from '../../main/ets/core/network/SetupParser';
import { RemoteApi } from '../../main/ets/core/network/RemoteApi';
import {
  SetupTransaction, SetupState, SetupStateKind, SetupAction,
  SetupProfileStore, SetupIdentityStore, SetupTransport, HTTPResult
} from '../../main/ets/features/setup/SetupTransaction';
import { ConnectionConfig, ConnectionMode } from '../../main/ets/core/models/ConnectionConfig';
import { ClientIdentity } from '../../main/ets/core/security/CredentialStore';

const INSTALLATION_ID = 'ab'.repeat(32);

// --- Fakes ---

class FakeProfileStore implements SetupProfileStore {
  staged: ConnectionConfig | null = null;
  committed: ConnectionConfig | null = null;

  constructor(stagedProfile: ConnectionConfig | null = null) {
    this.staged = stagedProfile;
  }

  stagedProfile(): ConnectionConfig | null { return this.staged; }
  async stageProfile(value: ConnectionConfig): Promise<void> { this.staged = value; }
  async commitStagedProfile(): Promise<ConnectionConfig> {
    const profile = this.staged!;
    this.committed = profile;
    this.staged = null;
    return profile;
  }
  async discardStagedProfile(): Promise<void> { this.staged = null; }
}

class FakeIdentityStore implements SetupIdentityStore {
  staged = false;
  promoted = false;
  discarded = false;

  async credentialPassword(installationId: string): Promise<string> {
    return 'test-password-123';
  }

  async stageCredential(
    installationId: string, encoded: string, password: string, expectedFingerprint: string
  ): Promise<void> {
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

  async promoteCredential(installationId: string): Promise<void> {
    if (!this.staged) throw new Error('not found');
    this.promoted = true;
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
  requestCalls: Array<{ url: string, method: string, body: string | null }> = [];
  activateResponses: HTTPResult[] = [];
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
  }

  async request(
    config: ConnectionConfig, url: string, method: string,
    identity: ClientIdentity | null, headers: Record<string, string>, body: string | null
  ): Promise<HTTPResult> {
    this.requestCalls.push({ url, method, body });
    if (url.includes('pair')) return this.pairResponse;
    if (this.activateResponses.length > 0) return this.activateResponses.shift()!;
    return this.activateResponse;
  }
}

// --- Tests ---

export default function setupTransactionTest() {
  describe('SetupTransaction', () => {

    it('lan_connection_verifies_before_committing', async () => {
      const store = new FakeProfileStore();
      const transport = new FakeTransport();

      const transaction = new SetupTransaction(
        store, new FakeIdentityStore(), 'Test Device', transport
      );

      const config = SetupParser.create(
        INSTALLATION_ID, 'Test LAN', 'lan',
        'https://192.168.1.5:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '='
      );

      const result = await transaction.begin(
        { profile: config, invitation: '' }
      );

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(transport.verifyCalls).assertEqual(1);
      expect(store.committed).assertNotNull();
    });

    it('public_pairing_commits_after_activation', async () => {
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

      const result = await transaction.begin({
        profile: config,
        invitation: 'A'.repeat(43)
      });

      expect(result.kind).assertEqual(SetupStateKind.READY);
      expect(identityStore.promoted).assertTrue();
      expect(identityStore.staged).assertFalse();
    });

    it('activation_failure_retries_without_pairing_again', async () => {
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
      const setup = { profile: config, invitation: 'A'.repeat(43) };

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

    it('approval_pending_continues_without_re_pairing', async () => {
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
      const setup = { profile: config, invitation: 'A'.repeat(43) };

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

    it('denied_invitation_discards_local_transaction', async () => {
      const store = new FakeProfileStore();
      const identityStore = new FakeIdentityStore();
      const transport = new FakeTransport();
      transport.pairResponse = { status: 401, body: '' };

      const config = SetupParser.create(
        INSTALLATION_ID, 'Public', 'public',
        'https://remote.example.com'
      );
      const setup = { profile: config, invitation: 'A'.repeat(43) };

      const transaction = new SetupTransaction(
        store, identityStore, 'device', transport
      );

      const result = await transaction.begin(setup);
      expect(result.kind).assertEqual(SetupStateKind.FAILED);
      expect(result.action).assertEqual(SetupAction.RESTART_SETUP);
    });

    it('recovery_only_returns_activatable_public_transaction', async () => {
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
      expect(recovered).assertNotNull();

      // LAN staged should not be recoverable
      const lanConfig = SetupParser.create(
        INSTALLATION_ID, 'LAN', 'lan',
        'https://192.168.1.5:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '='
      );
      store.staged = lanConfig;
      identityStore.staged = false;
      const lanRecovered = await transaction.recover();
      expect(lanRecovered).assertNull();
    });
  });
}
