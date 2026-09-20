import { appTasks } from '@ohos/hvigor-ohos-plugin';
import * as fs from 'fs';

// Signing material belongs to the machine, not to the repository. It lives beside
// this file in signing.json — which git ignores — and is injected here as an
// override, so build-profile.json5 stays the configuration everyone shares and
// commits. A machine without the file builds an unsigned hap, which is all a
// machine that only runs tests needs.
const SIGNING_FILE = './signing.json';

const buildConfig: Record<string, Object> = {
  system: appTasks,
  plugins: []
};

if (fs.existsSync(SIGNING_FILE)) {
  buildConfig.config = {
    ohos: {
      overrides: {
        signingConfig: JSON.parse(fs.readFileSync(SIGNING_FILE, 'utf8'))
      }
    }
  };
}

export default buildConfig;
