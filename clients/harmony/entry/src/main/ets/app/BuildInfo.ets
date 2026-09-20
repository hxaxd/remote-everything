// What this build is.
//
// The version numbers are not written twice: they are read from the bundle, which is
// built from AppScope/app.json5, which clients/validate_versions.py checks against
// clients/release.json. The protocol version is the one thing that is not in the
// bundle, and it is the one thing that cannot be negotiated: this client speaks
// protocol 1 or it is paired again (contracts/README.md, Versioning).

import { bundleManager } from '@kit.AbilityKit';

export const PROTOCOL_VERSION: number = 1;

export class BuildInfo {
  static versionName(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (error) {
      return '';
    }
  }

  static buildNumber(): number {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionCode;
    } catch (error) {
      return 0;
    }
  }
}
