import { DEFAULT, describe, it, expect } from '@ohos/hypium';
import { GatewaySecurityPolicy } from '../../main/ets/core/security/GatewaySecurityPolicy';
import { SetupParser } from '../../main/ets/core/network/SetupParser';

const INSTALLATION_ID = 'ab'.repeat(32);

export default function gatewaySecurityPolicyTest() {
  describe('GatewaySecurityPolicy', () => {

    it('fingerprint_format_is_lowercase_and_zero_padded', DEFAULT, () => {
      const value = GatewaySecurityPolicy.formatFingerprint(
        new Uint8Array([0, 1, 10, 15, 16, 127, 128, 255])
      );
      expect(value).assertEqual('00010a0f107f80ff');
    });

    it('different_digest_bytes_produce_different_fingerprints', DEFAULT, () => {
      const fp1 = GatewaySecurityPolicy.formatFingerprint(new Uint8Array([1, 2, 3]));
      const fp2 = GatewaySecurityPolicy.formatFingerprint(new Uint8Array([1, 2, 4]));
      expect(fp1 === fp2).assertFalse();
    });

    it('lan_mode_does_not_allow_client_cert', DEFAULT, () => {
      const config = SetupParser.create(
        INSTALLATION_ID, 'LAN PC', 'lan',
        'https://192.168.1.5:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '='
      );
      expect(GatewaySecurityPolicy.allowsClientCertificate(
        config, true, '192.168.1.5', 60001
      )).assertFalse();
    });

    it('public_mode_allows_client_cert_only_for_gateway', DEFAULT, () => {
      const config = SetupParser.create(
        INSTALLATION_ID, 'Public PC', 'public',
        'https://remote.example.com'
      );
      expect(GatewaySecurityPolicy.allowsClientCertificate(
        config, true, 'remote.example.com', 443
      )).assertTrue();

      expect(GatewaySecurityPolicy.allowsClientCertificate(
        config, true, 'evil.example.com', 443
      )).assertFalse();

      expect(GatewaySecurityPolicy.allowsClientCertificate(
        config, false, 'remote.example.com', 443
      )).assertFalse();
    });

    it('gateway_origin_validation', DEFAULT, () => {
      const config = SetupParser.create(
        INSTALLATION_ID, 'PC', 'public',
        'https://remote.example.com:8443'
      );
      expect(GatewaySecurityPolicy.isGatewayOrigin(
        'https://remote.example.com:8443/__remote_everything/apps', config
      )).assertTrue();

      expect(GatewaySecurityPolicy.isGatewayOrigin(
        'https://remote.example.com/apps', config  // port 443 ≠ 8443
      )).assertFalse();

      expect(GatewaySecurityPolicy.isGatewayOrigin(
        'http://remote.example.com:8443/apps', config
      )).assertFalse();
    });
  });
}
