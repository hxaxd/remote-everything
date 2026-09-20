// The wire-strictness cases all three clients run, from
// clients/behavior/fixtures/wire-cases.json: every case goes through the same
// strict decoders the production client uses, so a rule iOS enforces and this
// client does not shows up here as a failure, and vice versa. The fixture is the
// arbiter; this test is only its runner.

import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { util } from '@kit.ArkTS';
import { JsonReader } from '../../../../main/ets/core/json/Strict';
import { CatalogAnswer, decodeCatalog, decodeControl, decodeError, decodeNodes, decodePairing } from
  '../../../../main/ets/core/api/Dto';
import { validateActivation } from '../../../../main/ets/core/api/Wire';
import { decodeRelease } from '../../../../main/ets/core/update/UpdateChecker';
import { parseSetupUri } from '../../../../main/ets/core/setup/SetupUri';

/** The test module's own name: the HAP these fixtures ship inside. */
const TEST_MODULE: string = 'entry_test';

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

function decodeByKind(kind: string, payload: string): void {
  switch (kind) {
    case 'nodes':
      decodeNodes(payload);
      break;
    case 'catalog':
    case 'apps':
      decodeCatalog(payload);
      break;
    case 'control':
      decodeControl(payload);
      break;
    case 'pairing':
      decodePairing(payload);
      break;
    case 'error':
      decodeError(payload);
      break;
    case 'activation':
      decodeActivation(payload);
      break;
    case 'release':
      decodeRelease(payload);
      break;
    case 'setup': {
      const reader: JsonReader = JsonReader.parse(payload, 'setup case');
      parseSetupUri(reader.string('uri'));
      break;
    }
    default:
      throw new Error(`unknown wire kind ${kind}`);
  }
}

/** An activation is the connected catalog, or a refusal — never the offline catalog. */
function decodeActivation(payload: string): void {
  try {
    const catalog: CatalogAnswer = decodeCatalog(payload);
    validateActivation(catalog.computerConnected, catalog.code);
    return;
  } catch (error) {
    // Not a connected catalog; it must be a refusal.
  }
  decodeError(payload);
}

export default function wireCasesTest() {
  describe('WireCases', () => {
    it('the wire is as strict here as the fixture says', 0, () => {
      const document: JsonReader = JsonReader.parse(fixture('wire-cases.json'), 'wire-cases.json');
      const cases: JsonReader[] = [];
      for (const entry of document.array('cases')) {
        cases.push(JsonReader.of(entry, 'wire-cases.json'));
      }
      expect(cases.length > 0).assertTrue();
      for (const entry of cases) {
        const name: string = entry.string('name');
        const kind: string = entry.string('kind');
        const want: string = entry.string('expect');
        const payload: string = entry.object('payload').json();
        let accepted: boolean = false;
        try {
          decodeByKind(kind, payload);
          accepted = true;
        } catch (error) {
          accepted = false;
        }
        const outcome: string = accepted ? 'accepted' : 'rejected';
        const wanted: string = want === 'accept' ? 'accepted' : 'rejected';
        expect(`${name}: ${outcome}`).assertEqual(`${name}: ${wanted}`);
      }
    });
  });
}
