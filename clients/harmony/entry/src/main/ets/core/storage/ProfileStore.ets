import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ConnectionConfig, ConnectionMode } from '../models/ConnectionConfig';
import { CredentialStore } from '../security/CredentialStore';
import { SetupProfileStore } from '../../features/setup/SetupTransaction';

interface StoredProfile {
  installationId: string;
  name: string;
  mode: string;
  gatewayOrigin: string;
  gatewayFingerprint: string;
  gatewayPublicKeyPin: string;
}

export class ProfileStore implements SetupProfileStore {
  private static readonly PROFILES_KEY = 'remote_everything_profiles';
  private static readonly STAGED_PROFILE_KEY = 'remote_everything_staged_profile';
  private static readonly ACTIVE_PROFILE_KEY = 'remote_everything_active_profile';
  private store: preferences.Preferences | null = null;
  profiles: ConnectionConfig[] = [];

  async init(context: common.UIAbilityContext): Promise<void> {
    CredentialStore.configure(context);
    this.store = preferences.getPreferencesSync(context, { name: 'RemoteEverything' });
    await this.load();
  }

  async load(): Promise<void> {
    const store = this.requireStore();
    const serialized = store.getSync(ProfileStore.PROFILES_KEY, '[]') as string;
    this.profiles = ProfileStore.decodeProfiles(serialized);
  }

  async save(): Promise<void> {
    const store = this.requireStore();
    const serialized = JSON.stringify(this.profiles.map((profile: ConnectionConfig): StoredProfile => ({
      installationId: profile.installationId,
      name: profile.name,
      mode: profile.mode,
      gatewayOrigin: profile.gatewayOrigin,
      gatewayFingerprint: profile.gatewayFingerprint,
      gatewayPublicKeyPin: profile.gatewayPublicKeyPin
    })));
    store.putSync(ProfileStore.PROFILES_KEY, serialized);
    await store.flush();
  }

  async add(profile: ConnectionConfig): Promise<void> {
    this.profiles = this.profiles.filter((item: ConnectionConfig) =>
      item.installationId !== profile.installationId
    );
    this.profiles.push(profile);
    await this.save();
  }

  async remove(installationId: string): Promise<void> {
    this.profiles = this.profiles.filter((item: ConnectionConfig) =>
      item.installationId !== installationId
    );
    await this.save();
    if (this.activeInstallationId() === installationId) {
      this.setActiveInstallationId('');
    }
    await CredentialStore.deleteAll(installationId);
  }

  activeInstallationId(): string {
    return this.requireStore().getSync(ProfileStore.ACTIVE_PROFILE_KEY, '') as string;
  }

  setActiveInstallationId(installationId: string): void {
    const store = this.requireStore();
    if (installationId === '') {
      store.deleteSync(ProfileStore.ACTIVE_PROFILE_KEY);
    } else {
      store.putSync(ProfileStore.ACTIVE_PROFILE_KEY, installationId);
    }
    store.flush().catch(() => {
      // The in-memory selection remains usable; the next mutation retries persistence.
    });
  }

  stagedProfile(): ConnectionConfig | null {
    const store = this.requireStore();
    const serialized = store.getSync(ProfileStore.STAGED_PROFILE_KEY, '') as string;
    if (serialized === '') {
      return null;
    }
    const decoded = ProfileStore.decodeProfiles(`[${serialized}]`);
    return decoded.length === 1 ? decoded[0] : null;
  }

  async stageProfile(profile: ConnectionConfig): Promise<void> {
    const store = this.requireStore();
    const value: StoredProfile = {
      installationId: profile.installationId,
      name: profile.name,
      mode: profile.mode,
      gatewayOrigin: profile.gatewayOrigin,
      gatewayFingerprint: profile.gatewayFingerprint,
      gatewayPublicKeyPin: profile.gatewayPublicKeyPin
    };
    store.putSync(ProfileStore.STAGED_PROFILE_KEY, JSON.stringify(value));
    await store.flush();
  }

  async commitStagedProfile(): Promise<ConnectionConfig> {
    const staged = this.stagedProfile();
    if (staged === null) {
      throw new Error('没有待提交的连接');
    }
    await this.add(staged);
    return staged;
  }

  async discardStagedProfile(): Promise<void> {
    const store = this.requireStore();
    store.deleteSync(ProfileStore.STAGED_PROFILE_KEY);
    await store.flush();
  }

  private requireStore(): preferences.Preferences {
    if (this.store === null) {
      throw new Error('连接存储尚未初始化');
    }
    return this.store;
  }

  private static decodeProfiles(serialized: string): ConnectionConfig[] {
    let values: Array<StoredProfile>;
    try {
      values = JSON.parse(serialized) as Array<StoredProfile>;
    } catch {
      throw new Error('连接存储内容损坏');
    }
    if (!Array.isArray(values)) {
      throw new Error('连接存储内容无效');
    }
    const ids = new Set<string>();
    return values.map((value: StoredProfile): ConnectionConfig => {
      if (typeof value.installationId !== 'string' || !/^[0-9a-f]{64}$/.test(value.installationId) ||
          typeof value.name !== 'string' || value.name.length === 0 ||
          typeof value.mode !== 'string' ||
          typeof value.gatewayOrigin !== 'string' ||
          typeof value.gatewayFingerprint !== 'string' ||
          typeof value.gatewayPublicKeyPin !== 'string' || ids.has(value.installationId)) {
        throw new Error('连接存储内容无效');
      }
      ids.add(value.installationId);
      const mode = value.mode === ConnectionMode.LAN
        ? ConnectionMode.LAN
        : value.mode === ConnectionMode.PUBLIC
          ? ConnectionMode.PUBLIC
          : null;
      if (mode === null) {
        throw new Error('连接模式无效');
      }
      return new ConnectionConfig(
        value.installationId,
        value.name,
        mode,
        value.gatewayOrigin,
        value.gatewayFingerprint,
        value.gatewayPublicKeyPin
      );
    });
  }
}
