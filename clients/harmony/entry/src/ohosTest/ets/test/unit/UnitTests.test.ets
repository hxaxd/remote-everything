// Unit tests for HarmonyOS core logic: SetupUri, Merge, PathSelector, Spki,
// ClientAuthPolicy, the RFC 3339 instant rule, and the update verdicts. Nothing
// here needs a gateway or a device beyond the test runner itself.

import { describe, expect, it } from '@ohos/hypium';
import { parseSetupUri } from '../../../../main/ets/core/setup/SetupUri';
import { isPrivateHost, isPrivateOrigin, mergeNodes, OriginProbe } from '../../../../main/ets/core/api/Merge';
import { NodeSummaryDto } from '../../../../main/ets/core/api/Dto';
import { PathSelector } from '../../../../main/ets/core/pathselect/PathSelector';
import { GatewayPath, Identity, Node } from '../../../../main/ets/core/model/Models';
import { ClientAuthPolicy } from '../../../../main/ets/core/api/ClientAuthPolicy';
import { isCertificateValid } from '../../../../main/ets/core/api/Spki';
import { isRfc3339 } from '../../../../main/ets/core/json/Strict';
import { decodeRelease, ReleaseManifest, UpdateVerdict, verdictFor } from '../../../../main/ets/core/update/UpdateChecker';

const NODE_ID: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const INVITATION: string = 'abcdefghijklmnopqrstuvwxyz0123456789-_ABCDE';

export default function unitTests() {
  describe('UnitTests', () => {

    it('SetupUri_parses_valid_invitation', 0, () => {
      const uri: string = `remote-everything://setup?node=${NODE_ID}&node_name=MyNode&origin=https%3A%2F%2Fgw.example.com%3A8443&invitation=${INVITATION}`;
      const setup = parseSetupUri(uri);
      expect(setup.origin).assertEqual('https://gw.example.com:8443');
      expect(setup.invitation).assertEqual(INVITATION);
      expect(setup.node).assertEqual(NODE_ID);
      expect(setup.nodeName).assertEqual('MyNode');
    });

    it('SetupUri_rejects_invalid_scheme', 0, () => {
      const uri: string = 'https://setup?node=n1&node_name=MyNode&origin=https%3A%2F%2Fgw.example.com&invitation=inv1';
      let rejected: boolean = false;
      try {
        parseSetupUri(uri);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('Merge_isPrivateHost_detects_lan_ips', 0, () => {
      expect(isPrivateHost('127.0.0.1')).assertTrue();
      expect(isPrivateHost('192.168.1.50')).assertTrue();
      expect(isPrivateHost('10.0.0.1')).assertTrue();
      expect(isPrivateHost('172.16.0.1')).assertTrue();
      expect(isPrivateHost('172.31.255.255')).assertTrue();
      expect(isPrivateHost('localhost')).assertTrue();

      // An mDNS name is a name, not an address range: like the other two clients,
      // this one does not treat `.local` as a private network.
      expect(isPrivateHost('my-box.local')).assertFalse();

      expect(isPrivateHost('8.8.8.8')).assertFalse();
      expect(isPrivateHost('example.com')).assertFalse();
      expect(isPrivateHost('172.32.0.1')).assertFalse();
    });

    it('Merge_isPrivateOrigin_parses_schemes_and_hosts', 0, () => {
      expect(isPrivateOrigin('https://192.168.1.1:8443')).assertTrue();
      expect(isPrivateOrigin('https://gw.example.com')).assertFalse();
    });

    it('Merge_mergeNodes_combines_multiple_gateways', 0, () => {
      const probe1: OriginProbe = new OriginProbe('https://192.168.1.10:8443', true, 10,
        [new NodeSummaryDto(NODE_ID, 'Node 1')], null);
      const probe2: OriginProbe = new OriginProbe('https://gw.example.com', true, 50,
        [new NodeSummaryDto(NODE_ID, 'Node 1')], null);
      const identities: Identity[] = [
        new Identity('https://192.168.1.10:8443', 'd1', 'f'.repeat(64), 'k1', null, 1),
        new Identity('https://gw.example.com', 'd2', 'e'.repeat(64), 'k2', null, 1)
      ];

      const merged: Node[] = mergeNodes([probe1, probe2], identities, []);
      expect(merged.length).assertEqual(1);
      expect(merged[0].id).assertEqual(NODE_ID);
      expect(merged[0].paths.length).assertEqual(2);
    });

    it('PathSelector_prefers_private_reachable_path', 0, () => {
      const selector = new PathSelector();
      const node = new Node('n1', 'Node 1', [
        new GatewayPath('https://gw.example.com', 'k1', false, 20, true, null),
        new GatewayPath('https://192.168.1.10:8443', 'k1', true, 30, true, null)
      ]);
      const chosen = selector.choose(node);
      expect(chosen !== null).assertTrue();
      if (chosen !== null) {
        expect(chosen.origin).assertEqual('https://192.168.1.10:8443');
        expect(chosen.isPrivate).assertTrue();
      }
    });

    it('ClientAuthPolicy_matches_ports_and_hosts', 0, () => {
      const gw = 'https://gw.example.com:8443';
      const appUrl = 'https://gw.example.com:8443/app1';

      expect(ClientAuthPolicy.portMatches(8443, gw, appUrl)).assertTrue();
      expect(ClientAuthPolicy.portMatches(0, gw, appUrl)).assertTrue();
      expect(ClientAuthPolicy.portMatches(-1, gw, appUrl)).assertTrue();
      expect(ClientAuthPolicy.portMatches(8080, gw, appUrl)).assertFalse();

      expect(ClientAuthPolicy.isKnownApplicationHost(gw, appUrl, 'gw.example.com')).assertTrue();
      expect(ClientAuthPolicy.isKnownApplicationHost(gw, appUrl, 'evil.com')).assertFalse();
    });

    it('Spki_isCertificateValid_rejects_empty_or_garbage', 0, () => {
      const empty = new Uint8Array(0);
      expect(isCertificateValid(empty)).assertFalse();
      const garbage = new Uint8Array([1, 2, 3, 4]);
      expect(isCertificateValid(garbage)).assertFalse();
    });

    it('Strict_isRfc3339_takes_full_date_times_and_refuses_the_rest', 0, () => {
      // Full date-time with a zone, fractional seconds included.
      expect(isRfc3339('2026-09-17T10:00:00Z')).assertTrue();
      expect(isRfc3339('2026-09-17T10:00:00.500Z')).assertTrue();
      expect(isRfc3339('2026-09-17T10:00:00+02:00')).assertTrue();
      // A bare date, a missing zone, a loose word: none is an instant.
      expect(isRfc3339('soon')).assertFalse();
      expect(isRfc3339('2026-09-17')).assertFalse();
      expect(isRfc3339('2026-09-17T10:00:00')).assertFalse();
      // JavaScript's Date.parse would roll these over; the strict rule refuses them.
      expect(isRfc3339('2026-02-30T10:00:00Z')).assertFalse();
      expect(isRfc3339('2026-13-01T10:00:00Z')).assertFalse();
    });

    it('UpdateChecker_verdictFor_compares_builds_and_protocol', 0, () => {
      const manifest: ReleaseManifest = new ReleaseManifest('3.5.0', 29, 1);
      expect(verdictFor(manifest, 29, 1).verdict).assertEqual(UpdateVerdict.UpToDate);
      expect(verdictFor(manifest, 28, 1).verdict).assertEqual(UpdateVerdict.Available);
      expect(verdictFor(manifest, 30, 1).verdict).assertEqual(UpdateVerdict.UpToDate);
      expect(verdictFor(manifest, 29, 2).verdict).assertEqual(UpdateVerdict.ProtocolChanged);
    });

    it('UpdateChecker_decodeRelease_requires_the_three_platform_fields', 0, () => {
      const good: string = '{"schema":1,"versionName":"3.5.0","buildNumber":28,"protocolVersion":1,' +
        '"minimumPlatforms":{"androidSdk":30,"ios":"17.0","harmonyApi":"24"}}';
      let accepted: boolean = true;
      try {
        decodeRelease(good);
      } catch (error) {
        accepted = false;
      }
      expect(accepted).assertTrue();

      const missing: string = '{"schema":1,"versionName":"3.5.0","buildNumber":28,"protocolVersion":1,' +
        '"minimumPlatforms":{"androidSdk":30,"ios":"17.0"}}';
      accepted = true;
      try {
        decodeRelease(missing);
      } catch (error) {
        accepted = false;
      }
      expect(accepted).assertFalse();
    });

  });
}
