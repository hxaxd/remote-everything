// Unit tests for HarmonyOS core logic: SetupUri, Merge, PathSelector, Spki, and ClientAuthPolicy.

import { describe, expect, it } from '@ohos/hypium';
import { parseSetupUri } from '../../../../main/ets/core/setup/SetupUri';
import { isPrivateHost, isPrivateOrigin, mergeNodes, OriginProbe } from '../../../../main/ets/core/api/Merge';
import { PathSelector } from '../../../../main/ets/core/pathselect/PathSelector';
import { GatewayPath, Identity, Node, NodeStatus } from '../../../../main/ets/core/model/Models';
import { ClientAuthPolicy } from '../../../../main/ets/core/identity/ClientAuthPolicy';
import { isCertificateValid } from '../../../../main/ets/core/identity/Spki';

export default function unitTests() {
  describe('UnitTests', () => {

    it('SetupUri_parses_valid_invitation', 0, () => {
      const node: string = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      const invitation: string = 'abcdefghijklmnopqrstuvwxyz0123456789-_ABCDE';
      const uri: string = `remote-everything://setup?node=${node}&node_name=MyNode&origin=https%3A%2F%2Fgw.example.com%3A8443&invitation=${invitation}`;
      const setup = parseSetupUri(uri);
      expect(setup.origin).assertEqual('https://gw.example.com:8443');
      expect(setup.invitation).assertEqual(invitation);
      expect(setup.node).assertEqual(node);
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
      expect(isPrivateHost('my-box.local')).assertTrue();

      expect(isPrivateHost('8.8.8.8')).assertFalse();
      expect(isPrivateHost('example.com')).assertFalse();
      expect(isPrivateHost('172.32.0.1')).assertFalse();
    });

    it('Merge_isPrivateOrigin_parses_schemes_and_hosts', 0, () => {
      expect(isPrivateOrigin('https://192.168.1.1:8443')).assertTrue();
      expect(isPrivateOrigin('https://gw.example.com')).assertFalse();
    });

    it('Merge_mergeNodes_combines_multiple_gateways', 0, () => {
      const probe1: OriginProbe = new OriginProbe(
        'https://192.168.1.10:8443',
        true,
        [new Node('n1', 'Node 1', [new GatewayPath('https://192.168.1.10:8443', true, 10, true)])]
      );
      const probe2: OriginProbe = new OriginProbe(
        'https://gw.example.com',
        true,
        [new Node('n1', 'Node 1', [new GatewayPath('https://gw.example.com', false, 50, true)])]
      );
      const identities: Identity[] = [
        new Identity('https://192.168.1.10:8443', 'd1', 'fp1', 'k1', 1),
        new Identity('https://gw.example.com', 'd2', 'fp2', 'k2', 1)
      ];

      const merged = mergeNodes([probe1, probe2], identities);
      expect(merged.length).assertEqual(1);
      expect(merged[0].id).assertEqual('n1');
      expect(merged[0].paths.length).assertEqual(2);
    });

    it('PathSelector_prefers_private_reachable_path', 0, () => {
      const selector = new PathSelector();
      const node = new Node('n1', 'Node 1', [
        new GatewayPath('https://gw.example.com', false, 20, true),
        new GatewayPath('https://192.168.1.10:8443', true, 30, true)
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

      expect(ClientAuthPolicy.portMatches(8443, gw)).assertTrue();
      expect(ClientAuthPolicy.portMatches(0, gw)).assertTrue();
      expect(ClientAuthPolicy.portMatches(-1, gw)).assertTrue();
      expect(ClientAuthPolicy.portMatches(8080, gw)).assertFalse();

      expect(ClientAuthPolicy.isKnownApplicationHost(gw, appUrl, 'gw.example.com')).assertTrue();
      expect(ClientAuthPolicy.isKnownApplicationHost(gw, appUrl, 'evil.com')).assertFalse();
    });

    it('Spki_isCertificateValid_rejects_empty_or_garbage', 0, () => {
      const empty = new Uint8Array(0);
      expect(isCertificateValid(empty)).assertFalse();
      const garbage = new Uint8Array([1, 2, 3, 4]);
      expect(isCertificateValid(garbage)).assertFalse();
    });

  });
}
