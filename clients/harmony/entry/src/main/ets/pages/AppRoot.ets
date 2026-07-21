import { common } from '@kit.AbilityKit';
import { ProfileStore } from '../core/storage/ProfileStore';
import { ConnectionConfig } from '../core/models/ConnectionConfig';
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

@Entry
@Component
struct AppRoot {
  @State activeProfile: ConnectionConfig | null = null;
  @State profiles: ConnectionConfig[] = [];
  @State isLoading: boolean = true;
  @State loadError: string = '';
  @State selectedTab: number = 0;
  @State setupInput: string = '';
  @State setupMessage: string = '';
  @State setupBusy: boolean = false;
  @State pendingConfig: ConnectionConfig | null = null;
  private pendingPayload: SetupPayload | null = null;
  private profileStore: ProfileStore = new ProfileStore();
  private transaction: SetupTransaction | null = null;

  aboutToAppear(): void {
    this.bootstrap();
  }

  async bootstrap(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await this.profileStore.init(context);
      this.transaction = new SetupTransaction(
        this.profileStore,
        new ProductionIdentityStore(),
        'HarmonyOS device'
      );
      await this.reloadProfiles();

      const staged = await this.transaction.recover();
      if (staged !== null) {
        this.pendingConfig = staged;
        this.setupMessage = '发现尚未完成的设备审批，可以继续激活。';
        this.selectedTab = 1;
      }
    } catch (error) {
      this.loadError = error instanceof Error ? error.message : '客户端初始化失败';
    } finally {
      this.isLoading = false;
    }
  }

  async reloadProfiles(preferredId: string = ''): Promise<void> {
    await this.profileStore.load();
    this.profiles = this.profileStore.profiles.slice();
    const selectedId = preferredId !== ''
      ? preferredId
      : this.profileStore.activeInstallationId() !== ''
        ? this.profileStore.activeInstallationId()
        : this.activeProfile?.installationId ?? '';
    this.activeProfile = this.profiles.find((profile: ConnectionConfig) =>
      profile.installationId === selectedId
    ) ?? (this.profiles.length > 0 ? this.profiles[0] : null);
    this.profileStore.setActiveInstallationId(this.activeProfile?.installationId ?? '');
  }

  selectProfile(profile: ConnectionConfig): void {
    this.activeProfile = profile;
    this.profileStore.setActiveInstallationId(profile.installationId);
    this.selectedTab = 0;
  }

  async deleteProfile(profile: ConnectionConfig): Promise<void> {
    await this.profileStore.remove(profile.installationId);
    await this.reloadProfiles();
  }

  async beginSetup(): Promise<void> {
    if (this.transaction === null || this.setupInput.trim() === '') {
      return;
    }
    this.setupBusy = true;
    this.setupMessage = '';
    this.pendingConfig = null;
    try {
      this.pendingPayload = SetupParser.parse(this.setupInput);
      const state = await this.transaction.begin(this.pendingPayload);
      await this.handleSetupState(state);
    } catch (error) {
      this.setupMessage = error instanceof Error ? error.message : '初始化链接无效';
    } finally {
      this.setupBusy = false;
    }
  }

  async retryActivation(): Promise<void> {
    if (this.transaction === null || this.pendingConfig === null) {
      return;
    }
    this.setupBusy = true;
    try {
      const state = await this.transaction.retryActivation(this.pendingConfig);
      await this.handleSetupState(state);
    } finally {
      this.setupBusy = false;
    }
  }

  async cancelSetup(): Promise<void> {
    if (this.transaction !== null) {
      await this.transaction.cancel();
    }
    this.pendingPayload = null;
    this.pendingConfig = null;
    this.setupMessage = '';
  }

  async handleSetupState(state: SetupState): Promise<void> {
    if (state.kind === SetupStateKind.READY) {
      this.setupInput = '';
      this.setupMessage = '';
      this.pendingConfig = null;
      this.pendingPayload = null;
      await this.reloadProfiles(state.config.installationId);
      this.selectedTab = 0;
      return;
    }
    if (state.kind === SetupStateKind.AWAITING_APPROVAL ||
        state.kind === SetupStateKind.ACTIVATING) {
      this.pendingConfig = state.config;
      this.setupMessage = state.kind === SetupStateKind.AWAITING_APPROVAL
        ? '设备正在等待电脑端批准。批准后点击继续。'
        : '设备身份正在激活。';
      return;
    }
    this.setupMessage = state.message === '' ? '连接初始化失败' : state.message;
    if (state.action === SetupAction.RETRY_ACTIVATION) {
      this.pendingConfig = state.config;
    }
  }

  @Builder
  setupPanel() {
    Column() {
      Text('添加连接').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
      TextInput({
        placeholder: '粘贴 remote-everything://setup 链接',
        text: this.setupInput
      })
        .margin({ top: 10 })
        .enabled(!this.setupBusy)
        .onChange((value: string) => { this.setupInput = value; })

      if (this.setupMessage !== '') {
        Text(this.setupMessage)
          .fontSize(13)
          .fontColor(this.pendingConfig === null ? '#D32F2F' : '#666666')
          .width('100%')
          .margin({ top: 8 })
      }

      Row() {
        if (this.pendingConfig !== null) {
          Button(this.setupBusy ? '正在继续…' : '继续激活')
            .enabled(!this.setupBusy)
            .onClick(() => this.retryActivation())
          Button('取消').enabled(!this.setupBusy).onClick(() => this.cancelSetup())
        } else {
          Button(this.setupBusy ? '正在连接…' : '验证并添加')
            .enabled(!this.setupBusy && this.setupInput.trim() !== '')
            .onClick(() => this.beginSetup())
        }
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
  }

  build() {
    if (this.isLoading) {
      Column() {
        LoadingProgress().width(36).height(36)
        Text('正在初始化…').fontSize(13).fontColor('#888888').margin({ top: 10 })
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
    } else if (this.loadError !== '') {
      Column() {
        Text('客户端无法启动').fontSize(20).fontWeight(FontWeight.Bold)
        Text(this.loadError).fontSize(14).fontColor('#D32F2F').margin({ top: 8 })
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
    } else {
      Navigation() {
        Tabs({ barPosition: BarPosition.End, index: $$this.selectedTab }) {
          TabContent() {
            if (this.activeProfile === null) {
              Column() {
                Text('尚未选择连接').fontSize(20).fontWeight(FontWeight.Bold)
                Text('请在“连接”中添加或选择计算机')
                  .fontSize(14).fontColor('#888888').margin({ top: 8 })
              }
              .width('100%').height('100%').justifyContent(FlexAlign.Center)
            } else {
              CatalogPage({ activeConfig: this.activeProfile! })
            }
          }
          .tabBar('目录')

          TabContent() {
            Column() {
              this.setupPanel()
              Divider()
              ConnectionsPage({
                profiles: this.profiles,
                activeInstallationId: this.activeProfile?.installationId ?? '',
                onSelect: (profile: ConnectionConfig): void => this.selectProfile(profile),
                onDelete: (profile: ConnectionConfig): void => { this.deleteProfile(profile); }
              })
            }
            .width('100%').height('100%')
          }
          .tabBar('连接')

          TabContent() {
            SettingsPage()
          }
          .tabBar('设置')
        }
        .width('100%').height('100%')
      }
      .title(this.activeProfile?.name ?? '远程万物')
    }
  }
}
