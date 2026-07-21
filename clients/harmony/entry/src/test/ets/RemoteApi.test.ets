import { describe, it, expect } from '@ohos/hypium';
import { SetupParser } from '../../main/ets/core/network/SetupParser';
import { RemoteApi } from '../../main/ets/core/network/RemoteApi';

const INSTALLATION_ID = 'ab'.repeat(32);

export default function remoteApiTest() {
  describe('RemoteApi', () => {
    const config = SetupParser.create(
      INSTALLATION_ID,
      'Public',
      'public',
      'https://remote.example.com'
    );

    it('catalog_requires_exact_schema_and_consistent_application_state', () => {
      const valid = {
        'ok': true,
        'computer_connected': true,
        'code': 'ready',
        'apps': [{
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
        }]
      };
      const snapshot = RemoteApi.decodeCatalog(config, valid);
      expect(snapshot.apps.length).assertEqual(1);
      expect(snapshot.apps[0].code).assertEqual('stopped');

      const unknown = Object.assign({}, valid, { 'legacy': true });
      expect(() => RemoteApi.decodeCatalog(config, unknown)).assertError();
    });

    it('offline_catalog_must_be_empty', () => {
      const invalid = {
        'ok': true,
        'computer_connected': false,
        'code': 'computer_offline',
        'apps': [{}]
      };
      expect(() => RemoteApi.decodeCatalog(config, invalid)).assertError();
    });

    it('pairing_deadline_must_be_an_instant', () => {
      const invalid = {
        'ok': true,
        'device_name': 'phone',
        'certificate_fingerprint': 'cd'.repeat(32),
        'credential_format': 'pkcs12',
        'credential_pkcs12': 'credential',
        'pending_expires_at': 'later'
      };
      expect(() => RemoteApi.decodePairingCredential(invalid)).assertError();
    });
  });
}
