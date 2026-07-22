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
  @State showRefreshProgress: boolean = false;
  @State errorMessage: string = '';
  @Prop activeConfig: ConnectionConfig;
  onAuthorizationRevoked: (installationId: string) => void = (_installationId: string): void => {};

  private pollTimer: number = -1;
  private catalogOfflineSince: number = 0;
  private requestInFlight: boolean = false;
  private requestOwner: number = 0;
  private pageGeneration: number = 0;
  private isVisible: boolean = false;
  private identity: ClientIdentity | null = null;
  private transport: ProductionSetupTransport = new ProductionSetupTransport();
  private static readonly POLL_INTERVAL = 5000;
  private static readonly OFFLINE_GRACE = 30000;

  aboutToAppear(): void {
    this.isVisible = true;
    const generation = ++this.pageGeneration;
    this.prepareAndStart(generation);
  }

  aboutToDisappear(): void {
    this.isVisible = false;
    ++this.pageGeneration;
    ++this.requestOwner;
    this.requestInFlight = false;
    this.isRefreshing = false;
    this.showRefreshProgress = false;
    this.stopPolling();
  }

  private isCurrentGeneration(generation: number): boolean {
    return this.isVisible && generation === this.pageGeneration;
  }

  async prepareAndStart(generation: number): Promise<void> {
    const config = this.activeConfig;
    try {
      const identity = config.mode === ConnectionMode.PUBLIC
        ? await CredentialStore.activeClientIdentity(config.installationId)
        : null;
      if (!this.isCurrentGeneration(generation)) return;
      this.identity = identity;
      this.startPolling(generation);
    } catch {
      if (!this.isCurrentGeneration(generation)) return;
      this.isLoading = false;
      this.errorMessage = '设备身份不可用，请重新初始化';
    }
  }

  startPolling(requestedGeneration: number = -1): void {
    const generation = requestedGeneration === -1 ? this.pageGeneration : requestedGeneration;
    if (!this.isCurrentGeneration(generation)) return;
    this.stopPolling();
    this.catalogOfflineSince = 0;
    // Preserve the last good catalog while resuming from a remote page. A
    // transient failure must not cover a usable snapshot with a spinner.
    this.isLoading = this.snapshot === null;
    this.fetchCatalog(false, generation);

    this.pollTimer = setInterval(() => {
      this.fetchCatalog(false, generation);
    }, CatalogPage.POLL_INTERVAL);
  }

  stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  async fetchCatalog(showProgress: boolean = false, requestedGeneration: number = -1): Promise<void> {
    const generation = requestedGeneration === -1 ? this.pageGeneration : requestedGeneration;
    if (!this.isCurrentGeneration(generation)) return;
    if (this.requestInFlight) {
      // A poll is already carrying the freshest request. A pull gesture must
      // still release immediately instead of leaving either indicator stuck.
      this.isRefreshing = false;
      return;
    }
    if (showProgress) {
      // The pull indicator only acknowledges the gesture. The top progress bar
      // represents the real request and may remain visible on a slow link.
      this.isRefreshing = false;
      this.showRefreshProgress = true;
    }
    const requestId = ++this.requestOwner;
    this.requestInFlight = true;
    const config = this.activeConfig;
    const identity = this.identity;
    try {
      const response = await this.transport.request(
        config,
        config.appsUrl,
        'GET',
        identity,
        {},
        null
      );
      if (!this.isCurrentGeneration(generation) || requestId !== this.requestOwner) return;

      if (response.status === 401 || response.status === 403) {
        this.stopPolling();
        this.onAuthorizationRevoked(config.installationId);
        return;
      }

      if (response.status !== 200) {
        if (this.snapshot !== null) return; // keep existing snapshot on transient error
        this.errorMessage = `服务返回 ${response.status}`;
        this.isLoading = false;
        return;
      }

      const json = JSON.parse(response.body) as object;
      const catalog = RemoteApi.decodeCatalog(config, json);
      this.publishCatalog(catalog);
    } catch (err) {
      if (!this.isCurrentGeneration(generation) || requestId !== this.requestOwner) return;
      if (this.snapshot === null) {
        this.errorMessage = '无法连接服务';
        this.isLoading = false;
      }
    } finally {
      if (requestId === this.requestOwner) {
        this.requestInFlight = false;
        if (this.isCurrentGeneration(generation)) {
          this.isRefreshing = false;
          this.showRefreshProgress = false;
        }
      }
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
    const generation = this.pageGeneration;
    if (!this.isCurrentGeneration(generation)) return;
    const config = this.activeConfig;
    const identity = this.identity;
    try {
      const response = await this.transport.request(
        config,
        config.appActionUrl(appId, action),
        'POST',
        identity,
        {},
        null
      );
      if (!this.isCurrentGeneration(generation)) return;
      if (response.status !== 200) {
        throw new Error(`控制服务返回 ${response.status}`);
      }
      const payload = JSON.parse(response.body) as object;
      if (!RemoteApi.decodeAction(config, action, payload)) {
        throw new Error('控制操作未完成');
      }
    } catch {
      if (!this.isCurrentGeneration(generation)) return;
      this.getUIContext().getPromptAction().showToast({ message: '操作失败，请稍后重试' });
    } finally {
      if (this.isCurrentGeneration(generation)) {
        await this.fetchCatalog(false, generation);
      }
    }
  }

  confirmStop(app: RemoteApp): void {
    this.getUIContext().showAlertDialog({
      title: `停止 ${app.name}`,
      message: `确定要停止「${app.name}」吗？停止后需要重新启动才能进入。`,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '停止',
        fontColor: $r('app.color.error'),
        action: (): void => { this.controlApp(app.id, 'stop'); }
      }
    });
  }

  openApp(app: RemoteApp): void {
    router.pushUrl({
      url: 'features/remote/RemoteWebPage',
      params: {
        installationId: this.activeConfig.installationId,
        profileName: this.activeConfig.name,
        connectionMode: this.activeConfig.mode,
        gatewayOrigin: this.activeConfig.gatewayOrigin,
        gatewayFingerprint: this.activeConfig.gatewayFingerprint,
        gatewayPublicKeyPin: this.activeConfig.gatewayPublicKeyPin,
        appId: app.id,
        appName: app.name,
        openUrl: app.openUrl
      }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开远程页面' });
    });
  }

  build() {
    Column() {
      if (this.showRefreshProgress) {
        Progress({ value: 65, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
          .color($r('app.color.primary'))
          .backgroundColor($r('app.color.primary_container'))
          .style({ strokeWidth: 3, enableScanEffect: true })
      }
      Refresh({ refreshing: $$this.isRefreshing }) {
        List() {
          if (this.isLoading) {
            ListItem() {
              Column() {
                LoadingProgress().width(36).height(36).color($r('app.color.primary'))
                Text('正在加载应用目录…')
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ top: 12 })
              }
              .width('100%').height('100%').justifyContent(FlexAlign.Center)
            }
            .height('100%')
          } else if (this.errorMessage) {
            ListItem() {
              Column() {
                Text('目录暂时不可用')
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Text(`连接失败：${this.errorMessage}\n\n应用会自动重试，也可手动重试。`)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)
                  .margin({ top: 8 })
                Button('重试')
                  .height(42)
                  .fontColor($r('app.color.on_primary'))
                  .backgroundColor($r('app.color.primary'))
                  .margin({ top: 16 })
                  .onClick(() => { this.errorMessage = ''; this.startPolling(); })
              }
              .width('100%')
              .padding(24)
              .backgroundColor($r('app.color.surface_card'))
              .border({ width: 1, color: $r('app.color.outline') })
              .borderRadius(22)
            }
            .padding({ left: 20, right: 20, top: 12 })
          } else if (this.snapshot === null || !this.snapshot!.computerConnected) {
            ListItem() {
              Column() {
                Text('节点离线')
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('服务入口仍可连接，但节点核心当前不可用。应用会自动重试。')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)
                  .margin({ top: 8 })
              }
              .width('100%')
              .padding(24)
              .backgroundColor($r('app.color.surface_card'))
              .border({ width: 1, color: $r('app.color.outline') })
              .borderRadius(22)
            }
            .padding({ left: 20, right: 20, top: 12 })
          } else if (this.snapshot!.apps.length === 0) {
            ListItem() {
              Column() {
                Text('还没有已注册的应用')
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('在电脑上注册应用后会自动出现在这里。')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)
                  .margin({ top: 8 })
              }
              .width('100%')
              .padding(24)
              .backgroundColor($r('app.color.surface_card'))
              .border({ width: 1, color: $r('app.color.outline') })
              .borderRadius(22)
            }
            .padding({ left: 20, right: 20, top: 12 })
          } else {
            ForEach(this.snapshot!.apps, (app: RemoteApp) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(app.icon)
                      .fontSize(20)
                      .fontColor(Color.White)
                      .width(48).height(48)
                      .textAlign(TextAlign.Center)
                      .backgroundColor(app.accent)
                      .borderRadius(14)

                    Column() {
                      Text(app.name)
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(app.code === 'ready' ? '●  正在运行' :
                           app.code === 'starting' ? '●  正在启动' :
                           app.code === 'stopping' ? '●  正在停止' : '●  已停止')
                        .fontSize(11)
                        .fontWeight(FontWeight.Medium)
                        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                        .backgroundColor(app.code === 'ready'
                          ? $r('app.color.success_container') : $r('app.color.primary_container'))
                        .fontColor(app.code === 'ready'
                          ? $r('app.color.success') : $r('app.color.on_primary_container'))
                        .borderRadius(8)
                        .margin({ top: 6 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .margin({ left: 14 })
                    .layoutWeight(1)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  if (app.description) {
                    Text(app.description)
                      .fontSize(13)
                      .fontColor($r('app.color.text_secondary'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .margin({ top: 12 })
                  }

                  Row() {
                    Button(app.code === 'stopped' ? '启动' : '停止')
                      .layoutWeight(1)
                      .height(42)
                      .fontSize(14)
                      .fontColor(app.code === 'ready'
                        ? $r('app.color.error') : $r('app.color.primary'))
                      .backgroundColor(Color.Transparent)
                      .border({ width: 1, color: $r('app.color.outline') })
                      .enabled(app.code === 'ready' || app.code === 'stopped')
                      .onClick(() => {
                        if (app.code === 'ready') {
                          this.confirmStop(app);
                        } else {
                          this.controlApp(app.id, 'start');
                        }
                      })

                    Button('进入')
                      .layoutWeight(1)
                      .height(42)
                      .margin({ left: 10 })
                      .fontSize(14)
                      .fontColor($r('app.color.on_primary'))
                      .backgroundColor($r('app.color.primary'))
                      .enabled(app.code === 'ready' && this.activeConfig.isGatewayUrl(app.openUrl))
                      .onClick(() => this.openApp(app))
                  }
                  .width('100%')
                  .margin({ top: 16 })
                }
                .width('100%')
                .padding(18)
                .backgroundColor($r('app.color.surface_card'))
                .border({ width: 1, color: $r('app.color.outline') })
                .borderRadius(22)
              }
              .padding({ left: 20, right: 20, top: 6, bottom: 6 })
            })
          }
        }
        .width('100%').layoutWeight(1)
      }
      .onRefreshing(() => {
        this.isRefreshing = false;
        this.fetchCatalog(true);
      })
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
