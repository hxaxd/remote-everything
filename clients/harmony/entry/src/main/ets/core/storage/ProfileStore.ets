import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ConnectionConfig, ConnectionMode } from '../models/ConnectionConfig';
import { CredentialStore } from '../security/CredentialStore';
import { SetupProfileStore } from '../../features/setup/SetupTransaction';
import { ClientSettings } from './ClientSettings';

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
  private static readonly PROFILE_LOG_PREFIX = 'remote-everything-profiles-';
  private static readonly PROFILE_LOG_SUFFIX = '.json';
  private static readonly MAXIMUM_PROFILE_BYTES = 4 * 1024 * 1024;
  private store: preferences.Preferences | null = null;
  private filesDir: string = '';
  profiles: ConnectionConfig[] = [];

  async init(context: common.UIAbilityContext): Promise<void> {
    CredentialStore.configure(context);
    this.filesDir = context.filesDir;
    this.store = preferences.getPreferencesSync(context, { name: 'RemoteEverything' });
    await this.load();
  }

  async load(): Promise<void> {
    const store = this.requireStore();
    const durable = this.latestDurableProfiles();
    if (durable !== null) {
      this.profiles = durable;
      return;
    }

    // Seed the append-only store from the original preference on first use.
    // Subsequent writes never depend on rewriting that mutable value.
    const serialized = store.getSync(ProfileStore.PROFILES_KEY, '[]') as string;
    this.profiles = ProfileStore.decodeProfiles(serialized);
    if (this.profiles.length > 0) {
      this.persistProfiles(this.profiles);
    }
  }

  async save(): Promise<void> {
    this.requireStore();
    this.persistProfiles(this.profiles);
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
    ClientSettings.removeInstallation(installationId);
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

    this.requireStore();
    const nextProfiles = this.profiles.filter((item: ConnectionConfig) =>
      item.installationId !== staged.installationId
    );
    nextProfiles.push(staged);

    // The temporary file is flushed before its atomic rename. A failed write
    // leaves the previous generation untouched; a crash after rename leaves a
    // complete new generation that startup can deterministically select.
    this.persistProfiles(nextProfiles);
    this.profiles = nextProfiles;
    return staged;
  }

  async isProfileCommitted(profile: ConnectionConfig): Promise<boolean> {
    const durable = this.latestDurableProfiles();
    if (durable === null) {
      return false;
    }
    return durable.some((value: ConnectionConfig): boolean =>
      ProfileStore.sameProfile(value, profile)
    );
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

  private persistProfiles(profiles: ConnectionConfig[]): void {
    if (this.filesDir === '') {
      throw new Error('连接存储尚未初始化');
    }
    const generation = this.nextGeneration();
    const name = `${ProfileStore.PROFILE_LOG_PREFIX}${generation.toString().padStart(16, '0')}`;
    const temporaryPath = `${this.filesDir}/${name}.tmp`;
    const durablePath = `${this.filesDir}/${name}${ProfileStore.PROFILE_LOG_SUFFIX}`;
    ProfileStore.deleteFile(temporaryPath);
    try {
      ProfileStore.writeTextDurably(temporaryPath, ProfileStore.encodeProfiles(profiles));
      fileIo.renameSync(temporaryPath, durablePath);
      ProfileStore.syncFile(durablePath);
    } catch (error) {
      ProfileStore.deleteFile(temporaryPath);
      throw error as Error;
    }
    this.cleanupOldGenerations(durablePath);
  }

  private latestDurableProfiles(): ConnectionConfig[] | null {
    const files = this.profileGenerationFiles();
    for (let index = files.length - 1; index >= 0; index--) {
      try {
        return ProfileStore.decodeProfiles(ProfileStore.readText(files[index]));
      } catch {
        // A version without a valid payload is never a committed generation.
      }
    }
    return null;
  }

  private profileGenerationFiles(): string[] {
    if (this.filesDir === '') {
      return [];
    }
    const names = fileIo.listFileSync(this.filesDir).filter((name: string): boolean =>
      name.startsWith(ProfileStore.PROFILE_LOG_PREFIX) &&
      name.endsWith(ProfileStore.PROFILE_LOG_SUFFIX)
    );
    names.sort();
    return names.map((name: string): string => `${this.filesDir}/${name}`);
  }

  private nextGeneration(): number {
    const files = this.profileGenerationFiles();
    if (files.length === 0) {
      return 1;
    }
    const latest = files[files.length - 1];
    const name = latest.substring(latest.lastIndexOf('/') + 1);
    const numeric = name.substring(
      ProfileStore.PROFILE_LOG_PREFIX.length,
      name.length - ProfileStore.PROFILE_LOG_SUFFIX.length
    );
    const generation = Number(numeric);
    return Number.isSafeInteger(generation) ? generation + 1 : files.length + 1;
  }

  private cleanupOldGenerations(latestPath: string): void {
    const files = this.profileGenerationFiles();
    // Retain the current and immediately previous complete generations. Cleanup
    // is not part of the commit and therefore cannot invalidate it.
    for (let index = 0; index < files.length - 2; index++) {
      if (files[index] !== latestPath) {
        ProfileStore.deleteFile(files[index]);
      }
    }
  }

  private static sameProfile(left: ConnectionConfig, right: ConnectionConfig): boolean {
    return left.installationId === right.installationId &&
      left.name === right.name && left.mode === right.mode &&
      left.gatewayOrigin === right.gatewayOrigin &&
      left.gatewayFingerprint === right.gatewayFingerprint &&
      left.gatewayPublicKeyPin === right.gatewayPublicKeyPin;
  }

  private static writeTextDurably(path: string, value: string): void {
    const data = new util.TextEncoder().encodeInto(value);
    const file = fileIo.openSync(path, 0o2 | 0o100 | 0o1000);
    try {
      fileIo.writeSync(file.fd, data.buffer as ArrayBuffer);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static syncFile(path: string): void {
    const file = fileIo.openSync(path);
    try {
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static readText(path: string): string {
    const size = fileIo.statSync(path).size;
    if (size <= 0 || size > ProfileStore.MAXIMUM_PROFILE_BYTES) {
      throw new Error('连接存储文件大小无效');
    }
    const buffer = new ArrayBuffer(size);
    const file = fileIo.openSync(path);
    try {
      const count = fileIo.readSync(file.fd, buffer);
      return new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer.slice(0, count)));
    } finally {
      fileIo.closeSync(file);
    }
  }

  private static deleteFile(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch {
      // Generation cleanup is idempotent and never part of commit visibility.
    }
  }

  private static encodeProfiles(profiles: ConnectionConfig[]): string {
    return JSON.stringify(profiles.map((profile: ConnectionConfig): StoredProfile => ({
      installationId: profile.installationId,
      name: profile.name,
      mode: profile.mode,
      gatewayOrigin: profile.gatewayOrigin,
      gatewayFingerprint: profile.gatewayFingerprint,
      gatewayPublicKeyPin: profile.gatewayPublicKeyPin
    })));
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
