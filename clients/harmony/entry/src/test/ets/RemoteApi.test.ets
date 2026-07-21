import { DEFAULT, describe, it, expect } from '@ohos/hypium';
import { SetupParser } from '../../main/ets/core/network/SetupParser';
import { RemoteApi } from '../../main/ets/core/network/RemoteApi';

const INSTALLATION_ID = 'ab'.repeat(32);

interface AppPayload {
  id: string;
  name: string;
  description: string;
  icon: string;
  accent: string;
  launch_fragment: string;
  computer_connected: boolean;
  enabled: boolean;
  running: boolean;
  code: string;
}

interface CatalogPayload {
  ok: boolean;
  computer_connected: boolean;
  code: string;
  apps: Array<Object>;
}

interface LegacyCatalogPayload extends CatalogPayload {
  legacy: boolean;
}

interface PairingPayload {
  ok: boolean;
  device_name: string;
  certificate_fingerprint: string;
  credential_format: string;
  credential_pkcs12: string;
  pending_expires_at: string;
}

class EmptyPayload {}

export default function remoteApiTest() {
  describe('RemoteApi', () => {
    const config = SetupParser.create(
      INSTALLATION_ID,
      'Public',
      'public',
      'https://remote.example.com'
    );

    it('catalog_requires_exact_schema_and_consistent_application_state', DEFAULT, () => {
      const app: AppPayload = {
        'id': 'editor',
        'name': 'Editor',
        'description': '',
        'icon': 'E',
        'accent': '#2563eb',
        'launch_fragment': '#workspace=main',
        'computer_connected': true,
        'enabled': false,
        'running': false,
        'code': 'stopped'
      };
      const valid: CatalogPayload = {
        'ok': true,
        'computer_connected': true,
        'code': 'ready',
        'apps': [app]
      };
      const snapshot = RemoteApi.decodeCatalog(config, valid);
      expect(snapshot.apps.length).assertEqual(1);
      expect(snapshot.apps[0].code).assertEqual('stopped');

      const unknown: LegacyCatalogPayload = {
        'ok': valid.ok,
        'computer_connected': valid.computer_connected,
        'code': valid.code,
        'apps': valid.apps,
        'legacy': true
      };
      expect(() => RemoteApi.decodeCatalog(config, unknown)).assertThrowError(Error);
    });

    it('offline_catalog_must_be_empty', DEFAULT, () => {
      const invalid: CatalogPayload = {
        'ok': true,
        'computer_connected': false,
        'code': 'computer_offline',
        'apps': [new EmptyPayload()]
      };
      expect(() => RemoteApi.decodeCatalog(config, invalid)).assertThrowError(Error);
    });

    it('pairing_deadline_must_be_an_instant', DEFAULT, () => {
      const invalid: PairingPayload = {
        'ok': true,
        'device_name': 'phone',
        'certificate_fingerprint': 'cd'.repeat(32),
        'credential_format': 'pkcs12',
        'credential_pkcs12': 'credential',
        'pending_expires_at': 'later'
      };
      expect(() => RemoteApi.decodePairingCredential(invalid)).assertThrowError(Error);
    });
  });
}
