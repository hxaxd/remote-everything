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
import { ErrorCode, parseErrorCode } from '../../../../main/ets/core/model/Errors';
import { CatalogAnswer, decodeCatalog, NodeSummary, NodeSummaryDto } from '../../../../main/ets/core/api/Dto';
import { Cadence } from '../../../../main/ets/core/model/Cadence';
import { MessageKeys } from '../../../../main/ets/core/model/MessageKeys';
import { AppState, GatewayPath, Identity, Node, NodeStatus } from '../../../../main/ets/core/model/Models';
import { mergeNodes, OriginProbe } from '../../../../main/ets/core/api/Merge';
import { PathSelector } from '../../../../main/ets/core/pathselect/PathSelector';
import { WebAppPrefs } from '../../../../main/ets/core/store/WebAppPrefs';
import { WebSessionScope } from '../../../../main/ets/core/store/WebSessionScope';

/** The test module's own name: the HAP these fixtures ship inside. */
const TEST_MODULE: string = 'entry_test';

/** One fixture file, by name, from the test bundle. */
function fixture(name: string): string {
  const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  try {
    // The fixtures ship in the test module's own HAP, so they are read through that
    // module's context: the application context answers with the module under test,
    // whose resources hold no `behavior/` directory at all.
    const context: Context = delegator.getAppContext().createModuleContext(TEST_MODULE);
    const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(`behavior/${name}`);
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

/** The shape of web-app-prefs.json: a description, read as one. */
interface WebAppPrefsDefaults {
  orientation: string;
  userAgent: string;
}

interface WebAppPrefsFixture {
  appKey: string;
  defaults: WebAppPrefsDefaults;
  orientations: string[];
  userAgents: string[];
}

/** The selector under test, with no gateway behind it: nothing here touches a network. */
function selector(): PathSelector {
  return new PathSelector();
}

export default function behaviorFixturesTest() {
  describe('BehaviorFixtures', () => {
    it('web_sessions_are_scoped_to_gateway_node_and_application', 0, () => {
      const cases: Object[] = JSON.parse(fixture('web-session-scope.json')) as Object[];
      for (const value of cases) {
        const row: JsonReader = JsonReader.of(value, 'web session scope');
        expect(WebSessionScope.profileName(row.string('gatewayOrigin'), row.string('appKey')))
          .assertEqual(row.string('profile'));
      }
    });

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
        for (const node of arrayOf(entry, 'nodes')) {
          const declared: string | null = node.optionalString('link');
          summaries.push(new NodeSummaryDto(node.string('id'), node.string('name'),
            declared !== null ? declared : ''));
        }
        probes.push(new OriginProbe(entry.string('origin'), true, entry.number('latencyMs'), summaries, null));
      }
      const expected: JsonReader = document.object('expected');
      const wanted: JsonReader[] = arrayOf(expected, 'nodes');
      const routed: PathSelector = selector();
      const merged: Node[] = mergeNodes(probes, identities, []).map((node: Node) => routed.route(node));
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
        // What the link is called follows the gateway's declaration when it made one:
        // a private address can still be a path that crosses the internet.
        const chosenLink: string | null = want.optionalString('chosenLink');
        if (chosenLink !== null) {
          expect(`${node.paths[0].link}`).assertEqual(chosenLink);
        }
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

    /**
     * A remembered path is kept while it answers *and* while it is still the best
     * class there is: the moment a private path answers, the phone takes it — which
     * is what makes walking into the LAN's room switch a phone off the tunnel it
     * happened to pair with first.
     */
    it('a remembered path holds its place only while it is the best there is', 0, () => {
      const document: JsonReader = reader(fixture('paths.json'), 'paths.json');
      const cases: JsonReader[] = arrayOf(document, 'remembered');
      expect(cases.length > 0).assertTrue();
      for (const entry of cases) {
        const name: string = entry.string('name');
        const remembered: string = entry.string('remembered');
        const paths: GatewayPath[] = [];
        const seed: GatewayPath[] = [];
        for (const path of arrayOf(entry, 'paths')) {
          const reachable: boolean | null = path.optionalBool('reachable');
          const latency: number | null = path.optionalNumber('latencyMs');
          const isPrivate: boolean = path.bool('isPrivate');
          const origin: string = path.string('origin');
          paths.push(new GatewayPath(origin, origin, reachable, latency, isPrivate, null));
          // The state an app is in when it has paired over the internet and has not
          // yet been in the same room as the gateway: only the remembered path answers.
          seed.push(new GatewayPath(origin, origin, origin === remembered ? reachable : false, latency,
            isPrivate, null));
        }
        const selector: PathSelector = new PathSelector();
        selector.route(new Node('node', 'node', seed));
        selector.remember([new Node('node', 'node', seed)]);
        const chosen: GatewayPath | null = selector.choose(new Node('node', 'node', paths));
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

    // --- message-keys.json ---------------------------------------------------

    it('the vocabulary is the one the fixture names', 0, () => {
      const text: string = fixture('message-keys.json');
      const canonical: string[] = JSON.parse(text) as string[];
      expect(canonical.length > 0).assertTrue();

      const keys: Set<string> = new Set<string>(canonical);
      expect(keys.size).assertEqual(canonical.length);

      for (const key of canonical) {
        const resName: string = MessageKeys.resource(key);
        expect(resName).assertEqual(key.replace(/\./g, '_'));
      }
    });

    // --- web-app-prefs.json --------------------------------------------------

    it('the per-application web choices are the vocabulary the fixture names', 0, () => {
      const document: WebAppPrefsFixture = JSON.parse(fixture('web-app-prefs.json')) as WebAppPrefsFixture;
      const orientations: string[] = WebAppPrefs.orientationValues();
      const userAgents: string[] = WebAppPrefs.userAgentValues();
      expect(document.orientations.length).assertEqual(orientations.length);
      for (let index: number = 0; index < orientations.length; index += 1) {
        expect(document.orientations[index]).assertEqual(orientations[index]);
      }
      expect(document.userAgents.length).assertEqual(userAgents.length);
      for (let index: number = 0; index < userAgents.length; index += 1) {
        expect(document.userAgents[index]).assertEqual(userAgents[index]);
      }
      const defaults: WebAppPrefs = WebAppPrefs.defaults();
      expect(document.defaults.orientation).assertEqual(defaults.orientation);
      expect(document.defaults.userAgent).assertEqual(defaults.userAgent);
    });

    it('the state names are the ones the fixtures use', 0, () => {
      expect(MessageKeys.forNodeStatus(NodeStatus.OnlineLan)).assertEqual(MessageKeys.NODE_LAN);
      expect(MessageKeys.forNodeStatus(NodeStatus.OnlineTunnel)).assertEqual(MessageKeys.NODE_TUNNEL);
      expect(MessageKeys.forNodeStatus(NodeStatus.Offline)).assertEqual(MessageKeys.NODE_OFFLINE);
      expect(MessageKeys.forNodeStatus(NodeStatus.PendingApproval)).assertEqual(MessageKeys.NODE_PENDING);
      expect(MessageKeys.forNodeStatus(NodeStatus.Unknown)).assertEqual(MessageKeys.NODE_UNKNOWN);

      expect(MessageKeys.forAppState(AppState.Ready)).assertEqual(MessageKeys.APP_READY);
      expect(MessageKeys.forAppState(AppState.Starting)).assertEqual(MessageKeys.APP_STARTING);
      expect(MessageKeys.forAppState(AppState.Stopping)).assertEqual(MessageKeys.APP_STOPPING);
      expect(MessageKeys.forAppState(AppState.Stopped)).assertEqual(MessageKeys.APP_STOPPED);
    });
  });
}
