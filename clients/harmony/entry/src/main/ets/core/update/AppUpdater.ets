import { http } from '@kit.NetworkKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { uri } from '@kit.ArkTS';

// MARK: - Types

export interface AppRelease {
  versionName: string;
  tagName: string;
  pageUrl: string;
}

export enum UpdateUiStateKind {
  IDLE = 'idle',
  CHECKING = 'checking',
  CURRENT = 'current',
  AVAILABLE = 'available',
  DOWNLOADING = 'downloading',
  READY = 'ready',
  ERROR = 'error'
}

export class UpdateUiState {
  kind: UpdateUiStateKind;
  latestVersion: string;
  currentIsNewer: boolean;
  release: AppRelease | null;
  progress: number;
  detail: string;

  constructor(
    kind: UpdateUiStateKind,
    latestVersion: string = '',
    currentIsNewer: boolean = false,
    release: AppRelease | null = null,
    progress: number = 0,
    detail: string = ''
  ) {
    this.kind = kind;
    this.latestVersion = latestVersion;
    this.currentIsNewer = currentIsNewer;
    this.release = release;
    this.progress = progress;
    this.detail = detail;
  }

  static idle(): UpdateUiState { return new UpdateUiState(UpdateUiStateKind.IDLE); }
  static checking(): UpdateUiState { return new UpdateUiState(UpdateUiStateKind.CHECKING); }
  static current(version: string, newer: boolean): UpdateUiState {
    return new UpdateUiState(UpdateUiStateKind.CURRENT, version, newer);
  }
  static available(release: AppRelease): UpdateUiState {
    return new UpdateUiState(UpdateUiStateKind.AVAILABLE, '', false, release);
  }
  static downloading(release: AppRelease, progress: number): UpdateUiState {
    return new UpdateUiState(UpdateUiStateKind.DOWNLOADING, '', false, release, progress);
  }
  static ready(release: AppRelease): UpdateUiState {
    return new UpdateUiState(UpdateUiStateKind.READY, '', false, release);
  }
  static error(detail: string): UpdateUiState {
    return new UpdateUiState(UpdateUiStateKind.ERROR, '', false, null, 0, detail);
  }
}

// MARK: - Update Protocol

const PROJECT_URL = 'https://github.com/hxaxd/remote-everything';
const VERSION_PATTERN = /^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;

function canonicalVersion(value: string): string {
  const match = value.match(VERSION_PATTERN);
  if (!match) throw new Error('版本号格式无效');
  return `${match[1]}.${match[2]}.${match[3]}`;
}

function versionParts(value: string): number[] {
  const canonical = canonicalVersion(value);
  return canonical.split('.').map(p => {
    const n = parseInt(p, 10);
    if (isNaN(n) || n > 2147483647) throw new Error('版本号超出范围');
    return n;
  });
}

export function parseLatestRelease(body: string): AppRelease {
  const json = JSON.parse(body) as Record<string, Object>;

  if (json['draft'] !== false || json['prerelease'] !== false) {
    throw new Error('最新发布版不可安装');
  }

  const tag = json['tag_name'] as string;
  const version = canonicalVersion(tag);
  if (tag !== `v${version}`) throw new Error('发布标签格式无效');

  const pageUrl = json['html_url'] as string;
  if (pageUrl !== `${PROJECT_URL}/releases/tag/${tag}`) {
    throw new Error('发布页面地址无效');
  }

  return { versionName: version, tagName: tag, pageUrl };
}

export function compareVersions(left: string, right: string): number {
  const a = versionParts(left);
  const b = versionParts(right);
  for (let i = 0; i < a.length; i++) {
    if (a[i] < b[i]) return -1;
    if (a[i] > b[i]) return 1;
  }
  return 0;
}

// MARK: - App Updater

@Observed
export class AppUpdater {
  static readonly shared: AppUpdater = new AppUpdater();
  state: UpdateUiState = UpdateUiState.idle();
  currentVersion: string = '';
  currentVersionCode: number = 0;
  private checking: boolean = false;
  private checkedAutomatically: boolean = false;

  private static readonly LATEST_RELEASE_API =
    'https://api.github.com/repos/hxaxd/remote-everything/releases/latest';

  async load(): Promise<void> {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
      );
      this.currentVersion = info.versionName;
      this.currentVersionCode = info.versionCode;
    } catch {
      this.currentVersion = '3.4.1';
      this.currentVersionCode = 27;
    }
  }

  async checkForUpdates(): Promise<void> {
    if (this.checking) return;
    this.checking = true;
    if (this.currentVersion === '') await this.load();
    this.state = UpdateUiState.checking();

    try {
      const body = await this.downloadText(AppUpdater.LATEST_RELEASE_API, true);
      const release = parseLatestRelease(body);

      const comparison = compareVersions(release.versionName, this.currentVersion);
      if (comparison > 0) {
        this.state = UpdateUiState.available(release);
      } else {
        this.state = UpdateUiState.current(release.versionName, comparison < 0);
      }
    } catch (err) {
      this.state = UpdateUiState.error(
        err instanceof Error ? err.message : '检查更新失败'
      );
    } finally {
      this.checking = false;
    }
  }

  async checkForUpdatesIfNeeded(): Promise<void> {
    if (this.checkedAutomatically) return;
    this.checkedAutomatically = true;
    await this.checkForUpdates();
  }

  async openGitHubRelease(context: common.UIAbilityContext, release: AppRelease): Promise<void> {
    await this.openUrl(context, release.pageUrl);
  }

  async openGitHubProject(context: common.UIAbilityContext): Promise<void> {
    await this.openUrl(context, PROJECT_URL);
  }

  private async openUrl(context: common.UIAbilityContext, url: string): Promise<void> {
    const parsed = new uri.URI(url);
    const userInfo = parsed.userInfo;
    if (parsed.scheme !== 'https' || parsed.host !== 'github.com' ||
        (userInfo !== undefined && userInfo !== null && userInfo !== '')) {
      throw new Error('项目地址无效');
    }
    try {
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: url,
        entities: ['entity.system.browsable']
      });
    } catch (error) {
      const detail = error instanceof Error && error.message !== ''
        ? error.message
        : '系统没有可用的浏览器';
      throw new Error(`无法打开 GitHub：${detail}`);
    }
  }

  private async downloadText(url: string, apiRequest: boolean): Promise<string> {
    const httpRequest = http.createHttp();

    const headers: Record<string, string> = {
      'Accept': apiRequest ? 'application/vnd.github+json' : 'application/octet-stream',
      'User-Agent': `RemoteEverything/${this.currentVersion}`
    };
    if (apiRequest) {
      headers['X-GitHub-Api-Version'] = '2022-11-28';
    }

    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false
      });

      if (response.responseCode !== 200) {
        if (response.responseCode === 403) {
          throw new Error('拒绝访问');
        }
        throw new Error(`无法访问（HTTP ${response.responseCode}）`);
      }
      if (typeof response.result !== 'string' || response.result === '') {
        throw new Error('发布信息无效');
      }
      return response.result;
    } catch (error) {
      if (error instanceof Error &&
          (error.message === '拒绝访问' ||
            error.message.startsWith('无法访问') ||
            error.message === '发布信息无效')) {
        throw error;
      }
      throw new Error('无法连接');
    } finally {
      httpRequest.destroy();
    }
  }
}
