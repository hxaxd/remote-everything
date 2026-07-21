import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { GatewaySecurityPolicy } from '../../main/ets/core/security/GatewaySecurityPolicy';
import { SetupParser } from '../../main/ets/core/network/SetupParser';

const INSTALLATION_ID = 'ab'.repeat(32);

export default function gatewaySecurityPolicyTest() {
  describe('GatewaySecurityPolicy', () => {

    it('fingerprint_is_deterministic_and_lowercase_hex', async () => {
      const encoder = new util.TextEncoder();
      const data = encoder.encodeInto('test-certificate-data');
      const fp1 = await GatewaySecurityPolicy.fingerprint(data);
      const fp2 = await GatewaySecurityPolicy.fingerprint(data);
      expect(fp1).assertEqual(fp2);
      expect(fp1.length).assertEqual(64);
      // Only lowercase hex
      const validHex = /^[0-9a-f]+$/;
      expect(validHex.test(fp1)).assertTrue();
    });

    it('different_data_produces_different_fingerprint', async () => {
      const encoder = new util.TextEncoder();
      const fp1 = await GatewaySecurityPolicy.fingerprint(encoder.encodeInto('cert-a'));
      const fp2 = await GatewaySecurityPolicy.fingerprint(encoder.encodeInto('cert-b'));
      expect(fp1 === fp2).assertFalse();
    });

    it('lan_mode_does_not_allow_client_cert', () => {
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

    it('public_mode_allows_client_cert_only_for_gateway', () => {
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

    it('gateway_origin_validation', () => {
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
