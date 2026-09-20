// Store tests: what this client writes into its own sandbox, read back. The
// pairing stage file, the node cache, and the settings/identity store — no
// gateway, no certificate manager, nothing beyond the test context's own
// directories, which is all these stores ever touch.

import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { AtomicFile } from '../../../../main/ets/core/store/AtomicFile';
import { SettingsStore } from '../../../../main/ets/core/store/SettingsStore';
import { NodeCacheStore } from '../../../../main/ets/core/store/NodeCacheStore';
import { StagedSetup, StagedSetupStore } from '../../../../main/ets/core/pairing/StagedSetup';
import { IdentityVault } from '../../../../main/ets/core/identity/IdentityVault';
import { CachedNodes, GatewayPath, Identity, Language, Node, ServerPin } from '../../../../main/ets/core/model/Models';

const NODE_ID: string = 'a'.repeat(64);
const FINGERPRINT: string = 'b'.repeat(64);
const PUBLIC_KEY_PIN: string = 'A'.repeat(43) + '=';

function staged(expiresAtMs: number, pin: ServerPin | null): StagedSetup {
  return new StagedSetup('https://gw.example.com', NODE_ID, '客厅电脑', 'Pixel', FINGERPRINT, 'ref-1',
    expiresAtMs, pin);
}

function identity(origin: string, pin: ServerPin | null): Identity {
  return new Identity(origin, 'Pixel', FINGERPRINT, 'ref-1', pin, 1000);
}

export default function storeTests() {
  describe('StoreTests', () => {
    const context: Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
    AtomicFile.init(`${context.filesDir}/storetests`);

    it('AtomicFile_write_then_read_round_trips_and_replaces', 0, () => {
      AtomicFile.writeAtomic('probe.txt', 'one');
      expect(AtomicFile.readText('probe.txt')).assertEqual('one');
      AtomicFile.writeAtomic('probe.txt', 'two');
      expect(AtomicFile.readText('probe.txt')).assertEqual('two');
      AtomicFile.removeWithTemporary('probe.txt');
      expect(AtomicFile.readText('probe.txt')).assertNull();
    });

    it('StagedSetup_expiry_is_the_window_the_gateway_named', 0, () => {
      // A window that has passed is expired; one still open is not; the boundary
      // instant itself is gone.
      expect(staged(1_000, null).expired).assertTrue();
      expect(staged(Date.now() + 60_000, null).expired).assertFalse();
      expect(staged(Date.now(), null).expired).assertTrue();
    });

    it('StagedSetupStore_reads_back_what_it_staged', 0, () => {
      // The vault is only constructed so the store can be built; none of its
      // platform calls run in these tests.
      const store: StagedSetupStore = new StagedSetupStore(new IdentityVault());
      const pin: ServerPin = new ServerPin(FINGERPRINT, PUBLIC_KEY_PIN);
      store.stage(staged(Date.now() + 600_000, pin));
      const loaded: StagedSetup | null = store.read();
      expect(loaded === null ? 'missing' : 'found').assertEqual('found');
      const setup: StagedSetup = loaded as StagedSetup;
      expect(setup.nodeName).assertEqual('客厅电脑');
      expect(setup.deviceName).assertEqual('Pixel');
      expect(setup.certificateFingerprint).assertEqual(FINGERPRINT);
      expect(setup.pendingExpiresAtMs > Date.now()).assertTrue();
      expect(setup.serverPin === null ? 'no pin' : setup.serverPin.certFingerprint)
        .assertEqual(FINGERPRINT);
      expect(setup.serverPin === null ? 'no pin' : setup.serverPin.publicKeyPin)
        .assertEqual(PUBLIC_KEY_PIN);
      store.clear();
      expect(store.read()).assertNull();
    });

    it('StagedSetupStore_refuses_what_it_cannot_read', 0, () => {
      const store: StagedSetupStore = new StagedSetupStore(new IdentityVault());
      AtomicFile.writeAtomic('pairing/staged.json', 'not json at all');
      expect(store.read()).assertNull();
      AtomicFile.writeAtomic('pairing/staged.json',
        `{"schema":2,"origin":"https://gw.example.com","node":"${NODE_ID}","node_name":"n",` +
        `"device_name":"d","certificate_fingerprint":"${FINGERPRINT}","credential_ref":"r",` +
        '"pending_expires_at":9999999999999}');
      expect(store.read()).assertNull();
      store.clear();
      expect(store.read()).assertNull();
    });

    it('NodeCacheStore_round_trips_one_gateways_answer', 0, () => {
      const cache: NodeCacheStore = new NodeCacheStore();
      const origin: string = 'https://192.168.1.10:8443';
      const node: Node = new Node(NODE_ID, '客厅电脑',
        [new GatewayPath(origin, 'ref-1', true, 12, true, 5000)]);
      cache.write(origin, [node], 12345);
      const read: CachedNodes | null = cache.read(origin, 'ref-1');
      expect(read === null ? 'missing' : 'found').assertEqual('found');
      if (read !== null) {
        expect(read.origin).assertEqual(origin);
        expect(read.nodes.length).assertEqual(1);
        expect(read.nodes[0].name).assertEqual('客厅电脑');
        expect(read.nodes[0].paths[0].isPrivate).assertTrue();
      }
      cache.remove(origin);
      expect(cache.read(origin)).assertNull();
    });

    it('SettingsStore_keeps_settings_and_identities_in_one_home', 0, () => {
      const store: SettingsStore = new SettingsStore();
      const defaults = store.open(context);
      expect(defaults.language).assertEqual(Language.System);
      store.write(defaults.withLanguage(Language.Chinese));
      expect(store.read().language).assertEqual(Language.Chinese);

      const pin: ServerPin = new ServerPin(FINGERPRINT, PUBLIC_KEY_PIN);
      store.writeIdentities([identity('https://192.168.1.10:8443', pin),
        identity('https://gw.example.com', null)]);
      const identities: Identity[] = store.readIdentities();
      expect(identities.length).assertEqual(2);
      expect(identities[0].origin).assertEqual('https://192.168.1.10:8443');
      expect(identities[0].serverPin === null ? 'no pin' : identities[0].serverPin.certFingerprint)
        .assertEqual(FINGERPRINT);
      expect(identities[1].serverPin).assertNull();
    });

  });
}
