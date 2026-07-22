import { DEFAULT, describe, it, expect } from '@ohos/hypium';
import { compareVersions, parseLatestRelease } from '../../main/ets/core/update/AppUpdater';

export default function updateProtocolTest() {
  describe('UpdateProtocol', () => {
    it('parses_trusted_release_and_compares_versions', DEFAULT, () => {
      const body = JSON.stringify({
        draft: false,
        prerelease: false,
        tag_name: 'v3.5.0',
        html_url: 'https://github.com/hxaxd/remote-everything/releases/tag/v3.5.0'
      });
      expect(parseLatestRelease(body).versionName).assertEqual('3.5.0');
      expect(compareVersions('3.10.0', '3.9.9')).assertEqual(1);
      expect(compareVersions('v3.4.0', '3.4.0')).assertEqual(0);
      expect(compareVersions('2.9.9', '3.0.0')).assertEqual(-1);
    });

    it('rejects_untrusted_release_page', DEFAULT, () => {
      const body = JSON.stringify({
        draft: false,
        prerelease: false,
        tag_name: 'v3.5.0',
        html_url: 'https://example.com/releases/tag/v3.5.0'
      });
      expect(() => parseLatestRelease(body)).assertThrowError('发布页面地址无效');
    });
  });
}
