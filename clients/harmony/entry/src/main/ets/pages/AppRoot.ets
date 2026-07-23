import { common } from '@kit.AbilityKit';
import { ProfileStore } from '../core/storage/ProfileStore';
import { ConnectionConfig, ConnectionMode } from '../core/models/ConnectionConfig';
import { CredentialStore } from '../core/security/CredentialStore';
import { SetupParser } from '../core/network/SetupParser';
import { SetupPayload } from '../core/models/SetupPayload';
import {
  ProductionIdentityStore,
  SetupAction,
  SetupState,
  SetupStateKind,
  SetupTransaction
} from '../features/setup/SetupTransaction';
import { CatalogPage } from '../features/catalog/CatalogPage';
import { ConnectionsPage } from '../features/connections/ConnectionsPage';
import { SettingsPage } from '../features/settings/SettingsPage';
import { ClientSettings } from '../core/storage/ClientSettings';
import { AppUpdater } from '../core/update/AppUpdater';
import { scanBarcode, scanCore } from '@kit.ScanKit';

enum RootPage {
  CATALOG = 'catalog',
  SETTINGS = 'settings',
  CONNECTIONS = 'connections'
}

enum ConnectionOperationKind {
  NONE = 'none',
  SELECT = 'select',
  DELETE = 'delete'
}

@Entry
@Component
struct AppRoot {
  @State activeProfile: ConnectionConfig | null = null;
  @State profiles: ConnectionConfig[] = [];
  @State isLoading: boolean = true;
  @State loadError: string = '';
  @State currentPage: RootPage = RootPage.CONNECTIONS;
  @State connectionsCanGoBack: boolean = false;
  @State setupInput: string = '';
  @State setupMessage: string = '';
  @State setupMessageIsError: boolean = false;
  @State setupBusy: boolean = false;
  @State scanBusy: boolean = false;
  @State cleanupBusy: boolean = false;
  @State connectionOperationBusy: boolean = false;
  @State setupAction: SetupAction | null = null;
  @State pendingConfig: ConnectionConfig | null = null;
  private pendingPayload: SetupPayload | null = null;
  private profileStore: ProfileStore = new ProfileStore();
  private transaction: SetupTransaction | null = null;
  private approvalRetryTimer: number = -1;
  private operationGeneration: number = 0;
  private setupOperationInFlight: boolean = false;
  private setupOperationOwner: number = -1;
  private setupOperationCompletion: Promise<void> | null = null;
  private setupOperationResolver: (() => void) | null = null;
  private cleanupPromise: Promise<void> | null = null;
  private connectionOperationKind: ConnectionOperationKind = ConnectionOperationKind.NONE;
  private scanOwner: number = -1;
  private rootVisible: boolean = false;

  beginTrackedSetupOperation(generation: number): void {
    this.setupOperationInFlight = true;
    this.setupOperationOwner = generation;
    this.setupOperationCompletion = new Promise<void>((resolve: () => void): void => {
      this.setupOperationResolver = resolve;
    });
  }

  finishTrackedSetupOperation(generation: number): void {
    if (this.setupOperationOwner !== generation) {
      return;
    }
    const resolver = this.setupOperationResolver;
    this.setupOperationResolver = null;
    this.setupOperationCompletion = null;
    this.setupOperationOwner = -1;
    this.setupOperationInFlight = false;
    if (resolver !== null) {
      resolver();
    }
  }

  supersedeProfileSelection(): void {
    if (this.connectionOperationKind === ConnectionOperationKind.SELECT) {
      this.connectionOperationKind = ConnectionOperationKind.NONE;
      this.connectionOperationBusy = false;
    }
  }

  discardOwnedScan(beforeGeneration: number): void {
    if (this.scanOwner !== -1 && this.scanOwner < beforeGeneration) {
      this.scanOwner = -1;
      this.scanBusy = false;
    }
  }

  finishOwnedScan(generation: number): void {
    if (this.scanOwner === generation) {
      this.scanOwner = -1;
      this.scanBusy = false;
    }
  }

  connectionActionsEnabled(): boolean {
    return !this.cleanupBusy && !this.setupBusy && !this.scanBusy &&
      !this.connectionOperationBusy && !this.hasPendingSetup();
  }

  aboutToAppear(): void {
    this.rootVisible = true;
    this.bootstrap();
  }

  aboutToDisappear(): void {
    this.rootVisible = false;
    this.stopApprovalRetry();
    if (this.connectionOperationKind === ConnectionOperationKind.SELECT) {
      ++this.operationGeneration;
      this.supersedeProfileSelection();
    }
  }

  async bootstrap(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ClientSettings.init(context);
      ClientSettings.applyTheme(context);
      ClientSettings.applyOrientation(context);
      AppUpdater.shared.load()
        .then((): Promise<void> => AppUpdater.shared.checkForUpdatesIfNeeded())
        .catch((): void => {});
      await this.profileStore.init(context);
      this.transaction = new SetupTransaction(
        this.profileStore,
        new ProductionIdentityStore(),
        'HarmonyOS device'
      );
      await this.reloadProfiles();
      this.currentPage = this.activeProfile === null ? RootPage.CONNECTIONS : RootPage.CATALOG;

      try {
        const staged = await this.transaction.recover();
        if (staged !== null) {
          this.pendingConfig = staged;
          this.pendingPayload = null;
          this.setupAction = SetupAction.RETRY_ACTIVATION;
          this.setupMessageIsError = false;
          this.setupMessage = '发现尚未完成的设备审批，将自动继续。';
          this.connectionsCanGoBack = false;
          this.currentPage = RootPage.CONNECTIONS;
          this.scheduleApprovalRetry();
        }
      } catch {
        // Incomplete public-setup recovery must not brick cold start; the user
        // can re-scan. Prefer a clean connections page over a fatal loadError.
        this.pendingConfig = null;
        this.pendingPayload = null;
        this.setupAction = null;
        this.setupMessage = '';
        this.setupMessageIsError = false;
        this.currentPage = this.activeProfile === null ? RootPage.CONNECTIONS : RootPage.CATALOG;
      }
    } catch (error) {
      this.loadError = error instanceof Error ? error.message : '客户端初始化失败';
    } finally {
      this.isLoading = false;
    }
  }

  async reloadProfiles(
    preferredId: string = '', expectedOperationGeneration: number = -1
  ): Promise<boolean> {
    await this.profileStore.load();
    const loadedProfiles = this.profileStore.profiles.slice();
    const selectedId = preferredId !== ''
      ? preferredId
      : this.profileStore.activeInstallationId() !== ''
        ? this.profileStore.activeInstallationId()
        : this.activeProfile?.installationId ?? '';
    const selected = selectedId === ''
      ? null
      : loadedProfiles.find((profile: ConnectionConfig) => profile.installationId === selectedId) ?? null;
    const usable = selected !== null && await this.hasUsableCredential(selected);
    if (expectedOperationGeneration !== -1 && expectedOperationGeneration !== this.operationGeneration) {
      return false;
    }
    this.profiles = loadedProfiles;
    this.activeProfile = usable
      ? selected
      : null;
    this.profileStore.setActiveInstallationId(this.activeProfile?.installationId ?? '');
    return preferredId === '' || this.activeProfile?.installationId === preferredId;
  }

  async hasUsableCredential(profile: ConnectionConfig): Promise<boolean> {
    if (profile.mode !== ConnectionMode.PUBLIC) {
      return true;
    }
    try {
      if (!(await CredentialStore.hasCredential(profile.installationId))) {
        return false;
      }
      await CredentialStore.activeClientIdentity(profile.installationId);
      return true;
    } catch {
      return false;
    }
  }

  async selectProfile(profile: ConnectionConfig): Promise<void> {
    if (!this.connectionActionsEnabled()) {
      return;
    }
    const generation = ++this.operationGeneration;
    this.connectionOperationKind = ConnectionOperationKind.SELECT;
    this.connectionOperationBusy = true;
    try {
      const usable = await this.hasUsableCredential(profile);
      if (generation !== this.operationGeneration ||
          this.connectionOperationKind !== ConnectionOperationKind.SELECT) {
        return;
      }
      if (!usable) {
        this.setupMessage = '该连接缺少设备身份，请重新扫描初始化二维码';
        this.setupMessageIsError = true;
        return;
      }
      this.setupMessage = '';
      this.setupMessageIsError = false;
      this.activeProfile = profile;
      this.profileStore.setActiveInstallationId(profile.installationId);
      this.connectionsCanGoBack = false;
      this.currentPage = RootPage.CATALOG;
    } catch (error) {
      if (generation === this.operationGeneration &&
          this.connectionOperationKind === ConnectionOperationKind.SELECT) {
        this.setupMessage = error instanceof Error ? error.message : '无法切换连接';
        this.setupMessageIsError = true;
      }
    } finally {
      if (generation === this.operationGeneration &&
          this.connectionOperationKind === ConnectionOperationKind.SELECT) {
        this.connectionOperationKind = ConnectionOperationKind.NONE;
        this.connectionOperationBusy = false;
      }
    }
  }

  async deleteProfile(profile: ConnectionConfig): Promise<void> {
    if (!this.connectionActionsEnabled()) {
      return;
    }
    const generation = ++this.operationGeneration;
    this.connectionOperationKind = ConnectionOperationKind.DELETE;
    this.connectionOperationBusy = true;
    try {
      await this.profileStore.remove(profile.installationId);
      const reloaded = await this.reloadProfiles('', generation);
      if (!reloaded || generation !== this.operationGeneration) {
        return;
      }
      if (this.activeProfile === null) {
        this.connectionsCanGoBack = false;
        this.currentPage = RootPage.CONNECTIONS;
      }
    } catch (error) {
      if (generation !== this.operationGeneration) {
        return;
      }
      const removalMessage = error instanceof Error ? error.message : '无法完整删除连接';
      let reconciliationMessage = '';
      try {
        await this.reloadProfiles('', generation);
      } catch (reloadError) {
        if (generation !== this.operationGeneration) {
          return;
        }
        this.profiles = this.profileStore.profiles.slice();
        const activeStillExists = this.activeProfile !== null &&
          this.profiles.some((item: ConnectionConfig) =>
            item.installationId === this.activeProfile?.installationId
          );
        if (!activeStillExists) {
          this.activeProfile = null;
          this.profileStore.setActiveInstallationId('');
        }
        reconciliationMessage = reloadError instanceof Error
          ? `；连接列表刷新失败：${reloadError.message}`
          : '；连接列表刷新失败';
      }
      if (generation !== this.operationGeneration) {
        return;
      }
      if (this.activeProfile === null) {
        this.connectionsCanGoBack = false;
        this.currentPage = RootPage.CONNECTIONS;
      }
      this.setupMessage = `${removalMessage}${reconciliationMessage}`;
      this.setupMessageIsError = true;
    } finally {
      if (generation === this.operationGeneration &&
          this.connectionOperationKind === ConnectionOperationKind.DELETE) {
        this.connectionOperationKind = ConnectionOperationKind.NONE;
        this.connectionOperationBusy = false;
      }
    }
  }

  confirmDeleteProfile(profile: ConnectionConfig): void {
    if (!this.connectionActionsEnabled()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: `删除 ${profile.name}？`,
      message: profile.mode === 'public'
        ? '将删除本机保存的连接和设备私钥。服务器上的设备记录仍需单独吊销。'
        : '将删除本机保存的连接。',
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: (): void => { this.deleteProfile(profile); }
      }
    });
  }

  async handleAuthorizationRevoked(installationId: string): Promise<void> {
    if (!this.connectionActionsEnabled()) {
      return;
    }
    const wasCurrent = this.activeProfile?.installationId === installationId;
    const generation = ++this.operationGeneration;
    this.supersedeProfileSelection();
    this.connectionOperationKind = ConnectionOperationKind.DELETE;
    this.connectionOperationBusy = true;
    try {
      await this.profileStore.remove(installationId);
      const reloaded = await this.reloadProfiles('', generation);
      if (!reloaded || generation !== this.operationGeneration) {
        return;
      }
      if (!wasCurrent) {
        return;
      }
      this.connectionsCanGoBack = false;
      this.currentPage = RootPage.CONNECTIONS;
      this.setupMessage = '设备授权已失效，请重新初始化';
      this.setupMessageIsError = true;
    } catch (error) {
      if (generation !== this.operationGeneration) {
        return;
      }
      const removalMessage = error instanceof Error ? error.message : '无法完整移除失效连接';
      let reconciliationMessage = '';
      try {
        await this.reloadProfiles('', generation);
      } catch (reloadError) {
        if (generation !== this.operationGeneration) {
          return;
        }
        this.profiles = this.profileStore.profiles.slice();
        const activeStillExists = this.activeProfile !== null &&
          this.profiles.some((item: ConnectionConfig) =>
            item.installationId === this.activeProfile?.installationId
          );
        if (!activeStillExists) {
          this.activeProfile = null;
          this.profileStore.setActiveInstallationId('');
        }
        reconciliationMessage = reloadError instanceof Error
          ? `；连接列表刷新失败：${reloadError.message}`
          : '；连接列表刷新失败';
      }
      if (generation !== this.operationGeneration) {
        return;
      }
      if (wasCurrent || this.activeProfile === null) {
        this.connectionsCanGoBack = false;
        this.currentPage = RootPage.CONNECTIONS;
      }
      this.setupMessage = `${removalMessage}${reconciliationMessage}`;
      this.setupMessageIsError = true;
    } finally {
      if (generation === this.operationGeneration &&
          this.connectionOperationKind === ConnectionOperationKind.DELETE) {
        this.connectionOperationKind = ConnectionOperationKind.NONE;
        this.connectionOperationBusy = false;
      }
    }
  }

  openSettings(): void {
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE) {
      return;
    }
    ++this.operationGeneration;
    this.discardOwnedScan(this.operationGeneration);
    this.supersedeProfileSelection();
    this.currentPage = RootPage.SETTINGS;
  }

  openConnections(): void {
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE) {
      return;
    }
    ++this.operationGeneration;
    this.discardOwnedScan(this.operationGeneration);
    this.supersedeProfileSelection();
    this.connectionsCanGoBack = this.activeProfile !== null;
    this.currentPage = RootPage.CONNECTIONS;
  }

  async closeSubPage(): Promise<void> {
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE) {
      return;
    }
    if (this.currentPage === RootPage.CONNECTIONS && this.connectionsCanGoBack) {
      if (this.hasPendingSetup()) {
        const generation = await this.cancelSetup(false);
        if (generation === -1 || generation !== this.operationGeneration) {
          return;
        }
      } else {
        ++this.operationGeneration;
        this.discardOwnedScan(this.operationGeneration);
        this.supersedeProfileSelection();
      }
      this.connectionsCanGoBack = false;
      this.currentPage = RootPage.SETTINGS;
      return;
    }
    ++this.operationGeneration;
    this.discardOwnedScan(this.operationGeneration);
    this.supersedeProfileSelection();
    this.currentPage = this.activeProfile === null ? RootPage.CONNECTIONS : RootPage.CATALOG;
  }

  onBackPress(): boolean {
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE) {
      return true;
    }
    if (this.connectionOperationKind === ConnectionOperationKind.SELECT) {
      ++this.operationGeneration;
      this.discardOwnedScan(this.operationGeneration);
      this.supersedeProfileSelection();
    }
    if (this.scanBusy) {
      ++this.operationGeneration;
      this.discardOwnedScan(this.operationGeneration);
    }
    if (this.currentPage === RootPage.CONNECTIONS && this.hasPendingSetup()) {
      this.cancelSetupAndLeave();
      return true;
    }
    if (this.currentPage === RootPage.SETTINGS ||
        (this.currentPage === RootPage.CONNECTIONS && this.connectionsCanGoBack)) {
      this.closeSubPage();
      return true;
    }
    return false;
  }

  hasPendingSetup(): boolean {
    return this.cleanupBusy || this.setupOperationInFlight || this.pendingPayload !== null ||
      this.pendingConfig !== null || this.setupAction !== null;
  }

  stopApprovalRetry(): void {
    if (this.approvalRetryTimer !== -1) {
      clearTimeout(this.approvalRetryTimer);
      this.approvalRetryTimer = -1;
    }
  }

  scheduleApprovalRetry(): void {
    this.stopApprovalRetry();
    if (!this.rootVisible) {
      return;
    }
    const generation = this.operationGeneration;
    const installationId = this.pendingConfig?.installationId ?? '';
    this.approvalRetryTimer = setTimeout(() => {
      this.approvalRetryTimer = -1;
      if (!this.rootVisible || generation !== this.operationGeneration ||
          this.currentPage !== RootPage.CONNECTIONS ||
          this.pendingConfig?.installationId !== installationId) {
        return;
      }
      this.retryActivation().catch((error: Error): void => {
        if (generation === this.operationGeneration) {
          this.setupMessage = error.message || '设备身份激活失败';
          this.setupMessageIsError = true;
        }
      });
    }, 5000);
  }

  async cancelSetupAndLeave(): Promise<void> {
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE) {
      return;
    }
    const returnToSettings = this.connectionsCanGoBack;
    const generation = await this.cancelSetup(false);
    if (generation === -1 || generation !== this.operationGeneration) {
      return;
    }
    if (returnToSettings) {
      this.connectionsCanGoBack = false;
      this.currentPage = RootPage.SETTINGS;
      return;
    }
    if (this.activeProfile !== null) {
      this.currentPage = RootPage.CATALOG;
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.terminateSelf();
    } catch (error) {
      if (generation === this.operationGeneration) {
        this.currentPage = RootPage.CONNECTIONS;
        this.setupMessage = error instanceof Error ? error.message : '无法退出应用';
        this.setupMessageIsError = true;
      }
    }
  }

  async beginSetup(): Promise<void> {
    if (this.transaction === null || this.setupInput.trim() === '') {
      return;
    }
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE ||
        this.setupOperationInFlight || this.scanBusy) {
      this.setupMessage = '上一项初始化正在清理，请稍候';
      return;
    }
    this.stopApprovalRetry();
    const generation = ++this.operationGeneration;
    this.discardOwnedScan(generation);
    this.supersedeProfileSelection();
    this.beginTrackedSetupOperation(generation);
    this.setupBusy = true;
    this.setupMessage = '';
    this.setupMessageIsError = false;
    this.setupAction = null;
    this.pendingPayload = null;
    this.pendingConfig = null;
    let parsed = false;
    try {
      const payload = SetupParser.parse(this.setupInput);
      parsed = true;
      this.pendingPayload = payload;
      const state = await this.transaction.begin(payload);
      if (generation === this.operationGeneration) {
        await this.handleSetupState(state, generation);
      }
    } catch (error) {
      if (generation === this.operationGeneration) {
        this.setupMessage = error instanceof Error ? error.message : '初始化链接无效';
        this.setupMessageIsError = true;
        this.setupAction = parsed ? SetupAction.RESTART_SETUP : null;
        this.pendingPayload = null;
        this.pendingConfig = null;
      }
    } finally {
      this.finishTrackedSetupOperation(generation);
      if (generation === this.operationGeneration && !this.cleanupBusy) {
        this.setupBusy = false;
      }
    }
  }

  async retryPairing(): Promise<void> {
    if (this.transaction === null || this.pendingPayload === null || this.cleanupBusy ||
        this.connectionOperationKind === ConnectionOperationKind.DELETE ||
        this.setupOperationInFlight || this.scanBusy) {
      return;
    }
    this.stopApprovalRetry();
    const payload = this.pendingPayload;
    const generation = ++this.operationGeneration;
    this.discardOwnedScan(generation);
    this.supersedeProfileSelection();
    this.beginTrackedSetupOperation(generation);
    this.setupBusy = true;
    this.setupMessageIsError = false;
    try {
      const state = await this.transaction.retryPairing(payload);
      if (generation === this.operationGeneration) {
        await this.handleSetupState(state, generation);
      }
    } catch (error) {
      if (generation === this.operationGeneration) {
        this.setupMessage = error instanceof Error ? error.message : '设备配对失败';
        this.setupMessageIsError = true;
        this.setupAction = SetupAction.RETRY_PAIRING;
      }
    } finally {
      this.finishTrackedSetupOperation(generation);
      if (generation === this.operationGeneration && !this.cleanupBusy) {
        this.setupBusy = false;
      }
    }
  }

  async retryActivation(): Promise<void> {
    if (this.transaction === null || this.pendingConfig === null || this.cleanupBusy ||
        this.connectionOperationKind === ConnectionOperationKind.DELETE ||
        this.setupOperationInFlight || this.scanBusy) {
      return;
    }
    this.stopApprovalRetry();
    const config = this.pendingConfig;
    const generation = ++this.operationGeneration;
    this.discardOwnedScan(generation);
    this.supersedeProfileSelection();
    this.beginTrackedSetupOperation(generation);
    this.setupBusy = true;
    this.setupMessageIsError = false;
    try {
      const state = await this.transaction.retryActivation(config);
      if (generation === this.operationGeneration) {
        await this.handleSetupState(state, generation);
      }
    } catch (error) {
      if (generation === this.operationGeneration) {
        this.pendingConfig = config;
        this.setupAction = SetupAction.RETRY_ACTIVATION;
        this.setupMessage = error instanceof Error ? error.message : '设备身份激活失败';
        this.setupMessageIsError = true;
      }
    } finally {
      this.finishTrackedSetupOperation(generation);
      if (generation === this.operationGeneration && !this.cleanupBusy) {
        this.setupBusy = false;
      }
    }
  }

  async retrySetup(): Promise<void> {
    if (this.setupAction === SetupAction.RETRY_PAIRING) {
      await this.retryPairing();
      return;
    }
    if (this.setupAction === SetupAction.RETRY_ACTIVATION) {
      await this.retryActivation();
      return;
    }
    if (this.setupAction === SetupAction.RESTART_SETUP) {
      const failureMessage = this.setupMessage;
      await this.cancelSetup(false, failureMessage);
    }
  }

  async performSetupCleanup(
    transaction: SetupTransaction | null, setupCompletion: Promise<void> | null
  ): Promise<void> {
    let cleanupError: Error | null = null;
    if (transaction !== null) {
      try {
        await transaction.cancel();
      } catch (error) {
        cleanupError = error instanceof Error ? error : new Error('初始化状态清理失败');
      }
    }
    if (setupCompletion !== null) {
      await setupCompletion;
    }
    if (cleanupError !== null) {
      throw cleanupError;
    }
  }

  async cancelSetup(
    navigateAfter: boolean = true, preservedMessage: string = ''
  ): Promise<number> {
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE) {
      return -1;
    }
    const generation = ++this.operationGeneration;
    this.discardOwnedScan(generation);
    this.supersedeProfileSelection();
    this.stopApprovalRetry();
    this.cleanupBusy = true;
    this.setupBusy = true;

    const setupCompletion = this.setupOperationCompletion;
    const cleanup = this.performSetupCleanup(this.transaction, setupCompletion);
    this.cleanupPromise = cleanup;
    let cleanupError: Error | null = null;
    try {
      await cleanup;
    } catch (error) {
      cleanupError = error instanceof Error ? error : new Error('初始化状态清理失败');
    } finally {
      if (this.cleanupPromise === cleanup) {
        this.cleanupPromise = null;
      }
    }

    if (generation !== this.operationGeneration) {
      return -1;
    }
    this.cleanupBusy = false;
    this.setupBusy = false;
    if (cleanupError !== null) {
      this.setupMessage = cleanupError.message || '初始化状态清理失败';
      this.setupMessageIsError = true;
      return -1;
    }

    this.pendingPayload = null;
    this.pendingConfig = null;
    this.setupAction = null;
    this.setupMessage = preservedMessage;
    this.setupMessageIsError = preservedMessage !== '';
    if (navigateAfter) {
      if (this.connectionsCanGoBack) {
        this.connectionsCanGoBack = false;
        this.currentPage = RootPage.SETTINGS;
      } else if (this.activeProfile !== null) {
        this.currentPage = RootPage.CATALOG;
      }
    }
    return generation;
  }

  async handleSetupState(state: SetupState, generation: number): Promise<void> {
    if (generation !== this.operationGeneration) {
      return;
    }
    if (state.kind === SetupStateKind.READY) {
      this.stopApprovalRetry();
      const reloaded = await this.reloadProfiles(state.config.installationId, generation);
      if (generation !== this.operationGeneration) {
        return;
      }
      if (!reloaded || this.activeProfile?.installationId !== state.config.installationId) {
        this.connectionsCanGoBack = false;
        this.currentPage = RootPage.CONNECTIONS;
        this.pendingConfig = null;
        this.pendingPayload = null;
        this.setupAction = null;
        this.setupMessage = '连接已保存，但设备身份无法读取，请重新扫描新的初始化二维码';
        this.setupMessageIsError = true;
        return;
      }
      this.setupInput = '';
      this.setupMessage = '';
      this.setupMessageIsError = false;
      this.setupAction = null;
      this.pendingConfig = null;
      this.pendingPayload = null;
      this.connectionsCanGoBack = false;
      this.currentPage = RootPage.CATALOG;
      return;
    }
    if (state.kind === SetupStateKind.PAIRING) {
      this.pendingConfig = null;
      this.setupAction = SetupAction.RETRY_PAIRING;
      this.setupMessage = '正在验证连接。';
      this.setupMessageIsError = false;
      return;
    }
    if (state.kind === SetupStateKind.AWAITING_APPROVAL ||
        state.kind === SetupStateKind.ACTIVATING) {
      this.pendingConfig = state.config;
      this.pendingPayload = null;
      this.setupAction = SetupAction.RETRY_ACTIVATION;
      this.setupMessageIsError = false;
      this.setupMessage = state.kind === SetupStateKind.AWAITING_APPROVAL
        ? '设备正在等待电脑端批准，将自动继续。'
        : '设备身份正在激活。';
      if (state.kind === SetupStateKind.AWAITING_APPROVAL) {
        this.scheduleApprovalRetry();
      }
      return;
    }
    this.stopApprovalRetry();
    this.setupMessage = state.message === '' ? '连接初始化失败' : state.message;
    this.setupMessageIsError = true;
    if (state.action === SetupAction.RETRY_PAIRING && this.pendingPayload !== null) {
      this.pendingConfig = null;
      this.setupAction = SetupAction.RETRY_PAIRING;
      return;
    }
    if (state.action === SetupAction.RETRY_ACTIVATION) {
      this.pendingPayload = null;
      this.pendingConfig = state.config;
      this.setupAction = SetupAction.RETRY_ACTIVATION;
      return;
    }
    this.pendingPayload = null;
    this.pendingConfig = null;
    this.setupAction = SetupAction.RESTART_SETUP;
  }

  async scanSetup(): Promise<void> {
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE ||
        this.setupBusy || this.scanBusy || this.hasPendingSetup()) {
      return;
    }
    const generation = ++this.operationGeneration;
    this.supersedeProfileSelection();
    this.scanOwner = generation;
    this.scanBusy = true;
    this.setupMessage = '';
    this.setupMessageIsError = false;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableAlbum: true
      });
      if (generation !== this.operationGeneration || this.currentPage !== RootPage.CONNECTIONS) {
        return;
      }
      const value = result.originalValue.trim();
      if (value === '') {
        throw new Error('二维码内容为空');
      }
      this.setupInput = value;
      this.finishOwnedScan(generation);
      await this.beginSetup();
    } catch (error) {
      if (generation === this.operationGeneration && this.currentPage === RootPage.CONNECTIONS) {
        this.setupMessage = error instanceof Error && error.message !== ''
          ? error.message
          : '未读取到初始化二维码';
        this.setupMessageIsError = true;
      }
    } finally {
      this.finishOwnedScan(generation);
    }
  }

  async submitSetup(): Promise<void> {
    if (this.cleanupBusy || this.connectionOperationKind === ConnectionOperationKind.DELETE ||
        this.setupBusy || this.scanBusy) {
      return;
    }
    if (this.setupInput.trim() === '') {
      this.setupMessage = '请先粘贴初始化链接';
      this.setupMessageIsError = true;
      return;
    }
    await this.beginSetup();
  }

  @Builder
  catalogHeader() {
    Row() {
      Column() {
        Text('远程万物')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.activeProfile?.name ?? '')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Button('⚙')
        .id('catalog_settings_button')
        .type(ButtonType.Circle)
        .width(44)
        .height(44)
        .fontSize(21)
        .fontColor($r('app.color.primary'))
        .backgroundColor($r('app.color.primary_container'))
        .onClick(() => this.openSettings())
    }
    .width('100%')
    .height(72)
    .padding({ left: 20, right: 14 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  subPageHeader(title: string, canGoBack: boolean) {
    Row() {
      if (canGoBack) {
        Button('‹')
          .type(ButtonType.Circle)
          .width(44)
          .height(44)
          .fontSize(32)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent)
          .onClick(() => this.closeSubPage())
      }
      Text(title)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: canGoBack ? 4 : 6 })
    }
    .width('100%')
    .height(64)
    .padding({ left: canGoBack ? 8 : 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  setupPanel() {
    Column() {
      Text('扫描电脑端展示的初始化二维码，或粘贴初始化链接。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Button(this.cleanupBusy
        ? '正在清理…'
        : this.scanBusy
          ? '正在扫描…'
          : '▣  扫描连接')
        .width('100%')
        .height(50)
        .margin({ top: 16 })
        .fontSize(15)
        .fontColor($r('app.color.on_primary'))
        .backgroundColor($r('app.color.primary'))
        .enabled(!this.cleanupBusy && !this.setupBusy && !this.scanBusy &&
          !this.connectionOperationBusy && this.setupAction === null)
        .onClick(() => this.scanSetup())

      TextInput({
        placeholder: '或粘贴一条初始化链接',
        text: this.setupInput
      })
        .margin({ top: 10 })
        .height(48)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.surface_card'))
        .border({ width: 1, color: $r('app.color.outline') })
        .borderRadius(12)
        .enabled(!this.cleanupBusy && !this.setupBusy && !this.scanBusy &&
          !this.connectionOperationBusy && this.setupAction === null)
        .onChange((value: string) => {
          this.setupInput = value;
          if (this.setupMessage !== '' && this.pendingConfig === null) {
            this.setupMessage = '';
            this.setupMessageIsError = false;
          }
        })

      if (this.setupMessage !== '') {
        Text(this.setupMessage)
          .fontSize(13)
          .fontColor(this.setupMessageIsError
            ? $r('app.color.error')
            : $r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 8 })
      }

      Row() {
        if (this.setupAction !== null) {
          Button(this.cleanupBusy
            ? '正在清理…'
            : this.setupBusy
              ? '正在继续…'
            : this.setupAction === SetupAction.RETRY_PAIRING
              ? '重试配对'
              : this.setupAction === SetupAction.RETRY_ACTIVATION
                ? '继续激活'
                : '重新初始化')
            .layoutWeight(1)
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .enabled(!this.cleanupBusy && !this.setupBusy && !this.scanBusy &&
              !this.connectionOperationBusy)
            .onClick(() => this.retrySetup())
          Button('取消并返回')
            .layoutWeight(1)
            .margin({ left: 10 })
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: $r('app.color.outline') })
            .enabled(!this.cleanupBusy && !this.setupBusy && !this.scanBusy &&
              !this.connectionOperationBusy)
            .onClick(() => this.cancelSetupAndLeave())
        } else {
          Button(this.cleanupBusy
            ? '正在清理…'
            : this.setupBusy
              ? '正在连接…'
            : '验证并添加')
            .width('100%')
            .height(46)
            .fontColor($r('app.color.primary'))
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: $r('app.color.primary') })
            .enabled(!this.cleanupBusy && !this.setupBusy && !this.scanBusy &&
              !this.connectionOperationBusy && this.setupInput.trim() !== '')
            .onClick(() => this.submitSetup())
        }
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 18 })
  }

  build() {
    if (this.isLoading) {
      Column() {
        LoadingProgress().width(36).height(36)
          .color($r('app.color.primary'))
        Text('正在初始化…')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 10 })
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.page_background'))
    } else if (this.loadError !== '') {
      Column() {
        Text('客户端无法启动')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.loadError).fontSize(14).fontColor($r('app.color.error')).margin({ top: 8 })
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.page_background'))
    } else {
      Column() {
        if (this.currentPage === RootPage.CATALOG && this.activeProfile !== null) {
          this.catalogHeader()
          Column() {
            if (this.activeProfile !== null) {
              CatalogPage({
                activeConfig: this.activeProfile!,
                onAuthorizationRevoked: (installationId: string): void => {
                  this.handleAuthorizationRevoked(installationId);
                }
              })
            }
          }
          .id('catalog_page')
          .width('100%')
          .layoutWeight(1)
        } else if (this.currentPage === RootPage.SETTINGS) {
          this.subPageHeader('设置', true)
          Column() {
            SettingsPage({
              activeProfile: this.activeProfile,
              onManageConnections: (): void => this.openConnections()
            })
          }
          .id('settings_page')
          .width('100%')
          .layoutWeight(1)
        } else {
          this.subPageHeader('连接', this.connectionsCanGoBack)
          this.setupPanel()
          Divider().color($r('app.color.outline'))
          Column() {
            ConnectionsPage({
              profiles: this.profiles,
              activeInstallationId: this.activeProfile?.installationId ?? '',
              interactionsEnabled: this.connectionActionsEnabled(),
              onSelect: (profile: ConnectionConfig): void => { this.selectProfile(profile); },
              onDelete: (profile: ConnectionConfig): void => this.confirmDeleteProfile(profile)
            })
          }
          .id('connections_page')
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
  }
}
