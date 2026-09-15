import { DEFAULT, describe, it, expect } from '@ohos/hypium';
import { SetupParser } from '../../main/ets/core/network/SetupParser';
import { ConnectionMode } from '../../main/ets/core/models/ConnectionConfig';

const INSTALLATION_ID = 'ab'.repeat(32);

export default function setupParserTest() {
  describe('SetupParser', () => {
    it('parses_strict_lan_setup', DEFAULT, () => {
      const token = '01'.repeat(32);
      const uri = buildURI({
        'v': '2',
        'id': INSTALLATION_ID,
        'name': 'Home PC',
        'mode': 'lan',
        'origin': 'https://192.168.1.5:60001',
        'fingerprint': 'cd'.repeat(32),
        'public_key_pin': 'A'.repeat(43) + '=',
        'token': token
      });
      const setup = SetupParser.parse(uri);
      expect(setup.profile.installationId).assertEqual(INSTALLATION_ID);
      expect(setup.profile.gatewayOrigin).assertEqual('https://192.168.1.5:60001');
      expect(setup.profile.mode).assertEqual(ConnectionMode.LAN);
      expect(setup.profile.accessToken).assertEqual(token);
      expect(setup.profile.authorizationHeaders()['Authorization'])
        .assertEqual(`Bearer ${token}`);
      expect(setup.invitation).assertEqual('');
    });

    it('lan_token_is_required_and_public_must_omit_it', DEFAULT, () => {
      const missingToken = buildURI({
        'v': '2',
        'id': INSTALLATION_ID,
        'name': 'PC',
        'mode': 'lan',
        'origin': 'https://192.168.1.5:60001',
        'fingerprint': 'cd'.repeat(32),
        'public_key_pin': 'A'.repeat(43) + '='
      });
      expect(() => SetupParser.parse(missingToken)).assertThrowError(Error);

      expect(() => SetupParser.create(
        INSTALLATION_ID, 'PC', 'lan', 'https://192.168.1.5:60001',
        'cd'.repeat(32), 'A'.repeat(43) + '=', 'not-hex-token'
      )).assertThrowError(Error);

      expect(() => SetupParser.create(
        INSTALLATION_ID, 'Public', 'public', 'https://remote.example.com',
        '', '', '01'.repeat(32)
      )).assertThrowError(Error);

      const publicSetup = SetupParser.parse(buildURI({
        'v': '2',
        'id': INSTALLATION_ID,
        'name': 'Public PC',
        'mode': 'public',
        'origin': 'https://remote.example.com',
        'invitation': 'A'.repeat(43)
      }));
      expect(publicSetup.profile.accessToken).assertEqual('');
      expect(Object.keys(publicSetup.profile.authorizationHeaders()).length).assertEqual(0);
    });

    it('parses_contract_valid_lan_fixture_token', DEFAULT, () => {
      const expectedToken =
        'abababababababababababababababababababababababababababababababab';
      const uri =
        'remote-everything://setup?v=2&id=abababababababababababababababababababababababababababababababab' +
        '&name=Home+PC&mode=lan&origin=https%3A%2F%2F192.168.1.5%3A60001' +
        '&fingerprint=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd' +
        '&public_key_pin=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D' +
        '&token=' + expectedToken;
      const setup = SetupParser.parse(uri);
      expect(setup.profile.accessToken).assertEqual(expectedToken);
      expect(setup.profile.accessToken.length).assertEqual(64);
      const headers = setup.profile.authorizationHeaders();
      expect(headers['Authorization'] === `Bearer ${expectedToken}`).assertTrue();
    });

    it('parses_strict_public_setup', DEFAULT, () => {
      const invitation = 'A'.repeat(43);
      const uri = buildURI({
        'v': '2',
        'id': INSTALLATION_ID,
        'name': 'Public PC',
        'mode': 'public',
        'origin': 'https://remote.example.com',
        'invitation': invitation
      });
      const setup = SetupParser.parse(uri);
      expect(setup.profile.mode).assertEqual('public');
      expect(setup.invitation).assertEqual(invitation);
    });

    it('rejects_duplicates_unknown_fields_and_insecure_origins', DEFAULT, () => {
      const base = buildURI({
        'v': '2',
        'id': INSTALLATION_ID,
        'name': 'PC',
        'mode': 'lan',
        'origin': 'http://127.0.0.1:58626',
        'fingerprint': 'cd'.repeat(32),
        'public_key_pin': 'A'.repeat(43) + '=',
        'token': '01'.repeat(32)
      });
      expect(() => SetupParser.parse(base)).assertThrowError(Error);

      const httpsBase = base.replace('http%3A', 'https%3A');
      expect(() => SetupParser.parse(httpsBase + '&mode=lan')).assertThrowError(Error);
      expect(() => SetupParser.parse(httpsBase + '&extra=x')).assertThrowError(Error);
    });

    it('counts_names_by_unicode_code_point', DEFAULT, () => {
      const emoji = '\u{1F600}';
      const accepted = SetupParser.create(
        INSTALLATION_ID,
        emoji.repeat(80),
        'public',
        'https://remote.example.com'
      );
      expect(accepted.name).assertEqual(emoji.repeat(80));

      expect(() => SetupParser.create(
        INSTALLATION_ID,
        emoji.repeat(81),
        'public',
        'https://remote.example.com'
      )).assertThrowError(Error);
    });

    it('normalizes_default_port_and_rejects_unsafe_authorities', DEFAULT, () => {
      const normalized = SetupParser.create(
        INSTALLATION_ID,
        'Public',
        'public',
        'https://REMOTE.EXAMPLE.COM:443/'
      );
      expect(normalized.gatewayOrigin).assertEqual('https://remote.example.com');

      expect(() => SetupParser.create(
        INSTALLATION_ID, 'Public', 'public', 'https://user@remote.example.com'
      )).assertThrowError(Error);
      expect(() => SetupParser.create(
        INSTALLATION_ID, 'Public', 'public', 'https://remote.example.com?target=evil'
      )).assertThrowError(Error);
      expect(() => SetupParser.create(
        INSTALLATION_ID, 'LAN', 'lan', 'https://999.1.1.1:60001',
        'cd'.repeat(32), 'A'.repeat(43) + '=', '01'.repeat(32)
      )).assertThrowError(Error);
    });

    it('supports_bracketed_ipv6_gateways', DEFAULT, () => {
      const config = SetupParser.create(
        INSTALLATION_ID,
        'IPv6 LAN',
        'lan',
        'https://[fd00::1]:60001',
        'cd'.repeat(32),
        'A'.repeat(43) + '=', '01'.repeat(32)
      );
      expect(config.gatewayOrigin).assertEqual('https://[fd00::1]:60001');
      expect(config.isGatewayEndpoint('fd00::1', 60001)).assertTrue();
      expect(config.isGatewayUrl('https://[fd00::1]:60001/apps')).assertTrue();
    });
  });
}

function buildURI(params: Record<string, string>): string {
  const query = Object.keys(params)
    .map((key: string) => `${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`)
    .join('&');
  return `remote-everything://setup?${query}`;
}
