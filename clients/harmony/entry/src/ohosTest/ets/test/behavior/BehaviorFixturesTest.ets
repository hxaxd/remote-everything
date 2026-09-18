// The behaviour all three clients share, asserted against the fixtures in
// clients/behavior — the same files the Android and iOS clients read.
//
// A fixture is a description, not a wire message, and it is allowed to carry prose the
// decoders here do not use, so the fixtures are read leniently. What is asserted is the
// conclusion: the same refusal is the same name, the same two gateways are one row, the
// same paths choose the same one, the same catalog answer is the same screen, and the
// same patience is the same number. A client that stops agreeing with these fails here.
//
// The fixtures are shipped inside the test bundle (`resources/rawfile/behavior/`), and
// `audit_source.py` fails if a copy differs from `clients/behavior/fixtures/`, so the
// bytes asserted on a device are the bytes in the repository.

import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { util } from '@kit.ArkTS';
import { JsonReader } from '../../../../main/ets/core/json/Strict';
import { ErrorCode, parseErrorCode } from '../../../../main/ets/core/api/Errors';
import { CatalogAnswer, decodeCatalog, NodeSummary } from '../../../../main/ets/core/api/Dto';
import { Cadence } from '../../../../main/ets/core/model/Cadence';
import { MessageKeys } from '../../../../main/ets/core/model/MessageKeys';
import { GatewayPath, Identity, Node } from '../../../../main/ets/core/model/Models';
import { OriginProbe, PathSelector } from '../../../../main/ets/core/pathselect/PathSelector';
import { ProtocolClient } from '../../../../main/ets/core/api/ProtocolClient';
import { IdentityVault } from '../../../../main/ets/core/identity/IdentityVault';

/** One fixture file, by name, from the test bundle. */
function fixture(name: string): string {
  const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  try {
    const bytes: Uint8Array = delegator.getAppContext().resourceManager
      .getRawFileContentSync(`behavior/${name}`);
    return new util.TextDecoder().decodeToString(bytes);
  } catch (error) {
    expect(`behavior/${name} is missing from the test bundle`).assertEqual('');
    return '';
  }
}

/** A reader over a fixture: a description, so only what is asserted is read. */
function reader(text: string, what: string): JsonReader {
  return JsonReader.parse(text, what);
}

function arrayOf(document: JsonReader, name: string): JsonReader[] {
  const items: JsonReader[] = [];
  for (const entry of document.array(name)) {
    items.push(JsonReader.of(entry, name));
  }
  return items;
}

/** The selector under test, with no gateway behind it: nothing here touches a network. */
function selector(): PathSelector {
  return new PathSelector(new ProtocolClient(new IdentityVault()));
}

export default function behaviorFixturesTest() {
  describe('BehaviorFixtures', () => {
    // --- errors.json ---------------------------------------------------------

    it('every refusal is the name the contract gives it', 0, () => {
      const document: JsonReader = reader(fixture('errors.json'), 'errors.json');
      const cases: JsonReader[] = arrayOf(document, 'cases');
      expect(cases.length).assertEqual(19);
      for (const entry of cases) {
        const code: string = entry.string('code');
        const key: string = entry.string('key');
        const parsed: ErrorCode | null = parseErrorCode(code);
        expect(parsed === null ? `unknown code ${code}` : code).assertEqual(code);
        expect(MessageKeys.forError(parsed as ErrorCode)).assertEqual(key);
      }
    });

    // --- nodes.json ----------------------------------------------------------

    it('the same machine through two gateways is one row with the LAN path chosen', 0, () => {
      const document: JsonReader = reader(fixture('nodes.json'), 'nodes.json');
      const identities: Identity[] = [];
      for (const entry of arrayOf(document, 'identities')) {
        identities.push(new Identity(entry.string('origin'), 'Pixel', 'f'.repeat(64), entry.string('origin'), null, 0));
      }
      const probes: OriginProbe[] = [];
      for (const entry of arrayOf(document, 'answers')) {
        const summaries: NodeSummary[] = [];
        for (const node of arrayOf(entry.object('nodes'), 'nodes')) {
          summaries.push(new NodeSummary(node.string('id'), node.string('name')));
        }
        probes.push(new OriginProbe(entry.string('origin'), true, entry.number('latencyMs'), summaries, null));
      }
      const expected: JsonReader = document.object('expected');
      const wanted: JsonReader[] = arrayOf(expected, 'nodes');
      const merged: Node[] = selector().merge(probes, identities, []);
      expect(merged.length).assertEqual(wanted.length);
      for (const want of wanted) {
        const id: string = want.string('id');
        let found: Node | null = null;
        for (const candidate of merged) {
          if (candidate.id === id) {
            found = candidate;
          }
        }
        expect(found === null ? 'missing node' : 'found').assertEqual('found');
        const node: Node = found as Node;
        expect(node.name).assertEqual(want.string('name'));
        expect(node.paths.length).assertEqual(want.number('pathCount'));
        // The chosen path is the first one after routing.
        expect(node.paths[0].origin).assertEqual(want.string('chosenOrigin'));
        expect(node.paths[0].isPrivate).assertEqual(want.bool('chosenIsPrivate'));
      }
    });

    // --- paths.json ----------------------------------------------------------

    it('the chosen path is the same everywhere', 0, () => {
      const document: JsonReader = reader(fixture('paths.json'), 'paths.json');
      const cases: JsonReader[] = arrayOf(document, 'cases');
      expect(cases.length > 0).assertTrue();
      for (const entry of cases) {
        const name: string = entry.string('name');
        const paths: GatewayPath[] = [];
        for (const path of arrayOf(entry, 'paths')) {
          const reachable: boolean | null = path.optionalBool('reachable');
          const latency: number | null = path.optionalNumber('latencyMs');
          paths.push(new GatewayPath(path.string('origin'), path.string('origin'), reachable, latency,
            path.bool('isPrivate'), null));
        }
        const chosen: GatewayPath | null = selector().choose(new Node('node', 'node', paths));
        const want: string | null = entry.optionalString('chosen');
        const got: string = chosen === null ? 'none' : chosen.origin;
        expect(`${name}: ${got}`).assertEqual(`${name}: ${want === null ? 'none' : want}`);
      }
    });

    // --- cadence.json --------------------------------------------------------

    it('the patience is the one all three clients share', 0, () => {
      const document: JsonReader = reader(fixture('cadence.json'), 'cadence.json');
      expect(document.number('nodeRefreshMs')).assertEqual(Cadence.nodeRefreshMs);
      expect(document.number('catalogRefreshMs')).assertEqual(Cadence.catalogRefreshMs);
      expect(document.number('controlPollMs')).assertEqual(Cadence.controlPollMs);
      // A factor, not a duration: asserted as close rather than equal, the way the
      // other two clients assert it.
      expect(Math.abs(document.number('controlPollFactor') - Cadence.controlPollFactor) < 0.0001).assertTrue();
      expect(document.number('controlPollCeilingMs')).assertEqual(Cadence.controlPollCeilingMs);
      expect(document.number('controlPollTimeoutMs')).assertEqual(Cadence.controlPollTimeoutMs);
      expect(document.number('approvalPollMs')).assertEqual(Cadence.approvalPollMs);
      expect(document.number('approvalPollTimeoutMs')).assertEqual(Cadence.approvalPollTimeoutMs);
      expect(document.number('pendingFallbackMs')).assertEqual(Cadence.pendingFallbackMs);
      expect(document.number('probeTimeoutMs')).assertEqual(Cadence.probeTimeoutMs);
      expect(document.number('requestTimeoutMs')).assertEqual(Cadence.requestTimeoutMs);
    });

    // --- catalog.json --------------------------------------------------------

    it('a catalog answer is the screen the contract gives it', 0, () => {
      const document: JsonReader = reader(fixture('catalog.json'), 'catalog.json');
      const cases: JsonReader[] = arrayOf(document, 'cases');
      expect(cases.length > 0).assertTrue();
      for (const entry of cases) {
        const name: string = entry.string('name');
        const answer: CatalogAnswer = decodeCatalog(entry.object('answer').json());
        const screen: string = entry.string('screen');
        if (screen === 'apps') {
          const wanted: JsonReader[] = arrayOf(entry, 'apps');
          expect(`${name}: ${answer.apps.length}`).assertEqual(`${name}: ${wanted.length}`);
          for (const app of wanted) {
            const id: string = app.string('id');
            for (const info of answer.apps) {
              if (info.id === id) {
                expect(`${name}: ${MessageKeys.forAppState(info.code)}`).assertEqual(`${name}: ${app.string('key')}`);
                expect(`${name}: ${info.launchFragment}`).assertEqual(`${name}: ${app.string('fragment')}`);
              }
            }
          }
        } else {
          // `node.offline` is a state the screen shows, not an error page.
          expect(`${name}: ${screen}`).assertEqual(`${name}: ${MessageKeys.NODE_OFFLINE}`);
          expect(answer.computerConnected).assertFalse();
        }
      }
    });
  });
}
