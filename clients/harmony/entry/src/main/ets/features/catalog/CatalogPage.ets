import { CatalogSnapshot, RemoteApp, AppCode } from '../../core/models/RemoteApp';
import { ConnectionConfig } from '../../core/models/ConnectionConfig';
import { ConnectionMode } from '../../core/models/ConnectionConfig';
import { RemoteApi } from '../../core/network/RemoteApi';
import { ClientIdentity, CredentialStore } from '../../core/security/CredentialStore';
import { ProductionSetupTransport } from '../setup/SetupTransaction';
import { router } from '@kit.ArkUI';

/**
 * App catalog with pull-to-refresh, start/stop, and offline state.
 * Mirrors Android's `CatalogScreen`.
 */
@Component
export struct CatalogPage {
  @State snapshot: CatalogSnapshot | null = null;
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  @State errorMessage: string = '';
  @Prop activeConfig: ConnectionConfig;

  private pollTimer: number = -1;
  private catalogOfflineSince: number = 0;
  private requestInFlight: boolean = false;
  private identity: ClientIdentity | null = null;
  private transport: ProductionSetupTransport = new ProductionSetupTransport();
  private static readonly POLL_INTERVAL = 5000;
  private static readonly OFFLINE_GRACE = 30000;

  aboutToAppear(): void {
    this.prepareAndStart();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  async prepareAndStart(): Promise<void> {
    try {
      this.identity = this.activeConfig.mode === ConnectionMode.PUBLIC
        ? await CredentialStore.activeClientIdentity(this.activeConfig.installationId)
        : null;
      this.startPolling();
    } catch {
      this.isLoading = false;
      this.errorMessage = '设备身份不可用，请重新初始化';
    }
  }

  startPolling(): void {
    this.stopPolling();
    this.catalogOfflineSince = 0;
    this.isLoading = true;
    this.fetchCatalog();

    this.pollTimer = setInterval(() => {
      this.fetchCatalog();
    }, CatalogPage.POLL_INTERVAL);
  }

  stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  async fetchCatalog(): Promise<void> {
    if (this.requestInFlight) {
      return;
    }
    this.requestInFlight = true;
    try {
      const response = await this.transport.request(
        this.activeConfig,
        this.activeConfig.appsUrl,
        'GET',
        this.identity,
        {},
        null
      );

      if (response.status === 401 || response.status === 403) {
        // Device authorization revoked
        this.errorMessage = '设备授权已失效，请重新初始化';
        this.stopPolling();
        return;
      }

      if (response.status !== 200) {
        if (this.snapshot !== null) return; // keep existing snapshot on transient error
        this.errorMessage = `服务返回 ${response.status}`;
        return;
      }

      const json = JSON.parse(response.body) as object;
      const catalog = RemoteApi.decodeCatalog(this.activeConfig, json);
      this.publishCatalog(catalog);
    } catch (err) {
      if (this.snapshot === null) {
        this.errorMessage = '无法连接服务';
      }
    } finally {
      this.requestInFlight = false;
      this.isRefreshing = false;
    }
  }

  publishCatalog(snapshot: CatalogSnapshot): void {
    if (snapshot.computerConnected) {
      this.catalogOfflineSince = 0;
      this.snapshot = snapshot;
      this.isLoading = false;
      this.errorMessage = '';
      return;
    }

    if (this.snapshot?.computerConnected) {
      const now = Date.now();
      if (this.catalogOfflineSince === 0) this.catalogOfflineSince = now;
      if (now - this.catalogOfflineSince < CatalogPage.OFFLINE_GRACE) {
        return; // 30s grace period
      }
    }

    this.snapshot = snapshot;
    this.isLoading = false;
    this.errorMessage = '';
  }

  async controlApp(appId: string, action: string): Promise<void> {
    try {
      const response = await this.transport.request(
        this.activeConfig,
        this.activeConfig.appActionUrl(appId, action),
        'POST',
        this.identity,
        {},
        null
      );
      if (response.status !== 200) {
        throw new Error(`控制服务返回 ${response.status}`);
      }
      await this.fetchCatalog();
    } catch (err) {
      // Silently fail, next poll will update
    }
  }

  openApp(app: RemoteApp): void {
    router.pushUrl({
      url: 'features/remote/RemoteWebPage',
      params: {
        config: this.activeConfig,
        appId: app.id,
        appName: app.name,
        openUrl: app.openUrl
      }
    });
  }

  build() {
    Column() {
      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36)
          Text('正在加载应用目录…').fontSize(14).fontColor('#999999').margin({ top: 12 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.errorMessage) {
        Column() {
          Text('加载失败').fontSize(20).fontWeight(FontWeight.Bold)
          Text(this.errorMessage).fontSize(14).fontColor('#999999').margin({ top: 8 })
          Button('重试').margin({ top: 16 }).onClick(() => { this.errorMessage = ''; this.startPolling(); })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.snapshot === null || !this.snapshot!.computerConnected) {
        Column() {
          Text('💻').fontSize(48)
          Text('电脑离线').fontSize(18).fontWeight(FontWeight.Medium).margin({ top: 12 })
          Text('请确认电脑已开机且网络正常').fontSize(14).fontColor('#999999').margin({ top: 4 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          List() {
            ForEach(this.snapshot!.apps, (app: RemoteApp) => {
              ListItem() {
                Row() {
                  Text(app.icon)
                    .fontSize(24)
                    .width(44).height(44)
                    .textAlign(TextAlign.Center)
                    .backgroundColor(app.accent + '20')
                    .borderRadius(10)

                  Column() {
                    Text(app.name).fontSize(16).fontWeight(FontWeight.Medium)
                    if (app.description) {
                      Text(app.description).fontSize(12).fontColor('#999999').maxLines(1)
                    }
                    Row() {
                      Text(app.code === 'ready' ? '运行中' :
                           app.code === 'starting' ? '启动中' :
                           app.code === 'stopping' ? '停止中' : '已停止')
                        .fontSize(10).fontWeight(FontWeight.Medium)
                        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                        .backgroundColor((app.code === 'ready' ? '#4CAF50' : '#FF9800') + '20')
                        .fontColor(app.code === 'ready' ? '#4CAF50' : '#FF9800')
                        .borderRadius(8)
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .margin({ left: 12 })
                  .layoutWeight(1)

                  Button(app.code === 'stopped' ? '▶' : '⏹')
                    .width(36).height(36)
                    .fontColor(app.code === 'stopped' ? '#4CAF50' : '#F44336')
                    .onClick(() => {
                      this.controlApp(app.id, app.code === 'stopped' ? 'start' : 'stop');
                    })

                  Button('◎')
                    .width(36).height(36)
                    .fontColor('#007AFF')
                    .enabled(app.code === 'ready')
                    .onClick(() => this.openApp(app))
                }
                .width('100%')
                .padding(12)
              }
            })
          }
          .width('100%').layoutWeight(1)
        }
        .onRefreshing(() => {
          this.fetchCatalog();
        })
      }
    }
    .width('100%').height('100%')
  }
}
