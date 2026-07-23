import { common } from '@kit.AbilityKit';
import { AppUpdater, UpdateUiStateKind } from '../../core/update/AppUpdater';
import { ClientSettings } from '../../core/storage/ClientSettings';
import { ConnectionConfig, ConnectionMode } from '../../core/models/ConnectionConfig';

/**
 * Settings: orientation, display mode, theme, connection, about & update.
 * Mirrors Android's `SettingsScreen`.
 */
@Component
export struct SettingsPage {
  @Prop activeProfile: ConnectionConfig | null;
  @State selectedTheme: string = 'system';
  @State selectedDisplay: string = 'phone';
  @State selectedOrientation: string = 'system';
  @State updater: AppUpdater = AppUpdater.shared;
  onManageConnections: () => void = (): void => {};

  aboutToAppear(): void {
    this.selectedTheme = ClientSettings.themeMode();
    this.selectedDisplay = ClientSettings.globalDisplayMode();
    this.selectedOrientation = ClientSettings.globalOrientation();
    this.updater.load();
  }

  setOrientation(value: string): void {
    this.selectedOrientation = value;
    ClientSettings.setGlobalOrientation(value);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ClientSettings.applyOrientation(context, value);
  }

  setDisplay(value: string): void {
    this.selectedDisplay = value;
    ClientSettings.setGlobalDisplayMode(value);
  }

  setTheme(value: string): void {
    this.selectedTheme = value;
    ClientSettings.setThemeMode(value);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ClientSettings.applyTheme(context, value);
  }

  async doCheckUpdate(): Promise<void> {
    await this.updater.checkForUpdates();
  }

  updateDescription(): string {
    const state = this.updater.state;
    switch (state.kind) {
      case UpdateUiStateKind.IDLE:
        return '从项目正式发布页检查新版本。';
      case UpdateUiStateKind.CHECKING:
        return '正在查询最新正式发布版…';
      case UpdateUiStateKind.CURRENT:
        return state.currentIsNewer
          ? `当前版本高于最新正式版 ${state.latestVersion}。`
          : `当前已是最新正式版 ${state.latestVersion}。`;
      case UpdateUiStateKind.AVAILABLE:
        return `发现新版本 ${state.release!.versionName}，可在 GitHub 查看详情。`;
      case UpdateUiStateKind.ERROR:
        return state.detail;
      default:
        return '从项目正式发布页检查新版本。';
    }
  }

  @Builder
  groupHeader(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 8 })
  }

  build() {
    Column() {
      List() {
        // Orientation
        ListItemGroup({ header: () => { this.groupHeader('屏幕方向'); } }) {
          ListItem() {
            Row() {
              Button('跟随系统')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .fontColor(this.selectedOrientation === 'system'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.selectedOrientation === 'system'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.selectedOrientation === 'system'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => { this.setOrientation('system'); })
              Button('竖屏锁定')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .margin({ left: 6 })
                .fontColor(this.selectedOrientation === 'portrait'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.selectedOrientation === 'portrait'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.selectedOrientation === 'portrait'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => { this.setOrientation('portrait'); })
              Button('横屏锁定')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .margin({ left: 6 })
                .fontColor(this.selectedOrientation === 'landscape'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.selectedOrientation === 'landscape'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.selectedOrientation === 'landscape'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => { this.setOrientation('landscape'); })
            }
            .width('100%').padding({ left: 20, right: 20 })
          }
        }

        // Display mode
        ListItemGroup({ header: () => { this.groupHeader('显示模式'); } }) {
          ListItem() {
            Row() {
              Button('手机')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .fontColor(this.selectedDisplay === 'phone'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.selectedDisplay === 'phone'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.selectedDisplay === 'phone'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => { this.setDisplay('phone'); })
              Button('电脑')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .margin({ left: 6 })
                .fontColor(this.selectedDisplay === 'desktop'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.selectedDisplay === 'desktop'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.selectedDisplay === 'desktop'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => { this.setDisplay('desktop'); })
            }
            .width('100%').padding({ left: 20, right: 20 })
          }
        }

        // Theme
        ListItemGroup({ header: () => { this.groupHeader('主题'); } }) {
          ListItem() {
            Row() {
              Button('跟随系统')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .fontColor(this.selectedTheme === 'system'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.selectedTheme === 'system'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.selectedTheme === 'system'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => { this.setTheme('system'); })
              Button('浅色')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .margin({ left: 6 })
                .fontColor(this.selectedTheme === 'light'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.selectedTheme === 'light'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.selectedTheme === 'light'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => { this.setTheme('light'); })
              Button('深色')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .margin({ left: 6 })
                .fontColor(this.selectedTheme === 'dark'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.selectedTheme === 'dark'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.selectedTheme === 'dark'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => { this.setTheme('dark'); })
            }
            .width('100%').padding({ left: 20, right: 20 })
          }
        }

        ListItemGroup({ header: () => { this.groupHeader('连接'); } }) {
          ListItem() {
            Column() {
              Text(this.activeProfile?.name ?? '未配置')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              if (this.activeProfile !== null) {
                Text(`${this.activeProfile!.mode === ConnectionMode.LAN ? '局域网' : '公网'} · ` +
                  this.activeProfile!.gatewayOrigin)
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(2)
                  .width('100%')
                  .margin({ top: 5 })
              }
              Button('管理连接')
                .id('settings_manage_connections')
                .width('100%')
                .height(44)
                .margin({ top: 14 })
                .fontColor($r('app.color.primary'))
                .backgroundColor(Color.Transparent)
                .border({ width: 1, color: $r('app.color.primary') })
                .onClick(() => this.onManageConnections())
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.surface_card'))
            .border({ width: 1, color: $r('app.color.outline') })
            .borderRadius(16)
          }
          .padding({ left: 20, right: 20 })
        }

        // About & Update
        ListItemGroup({ header: () => { this.groupHeader('关于与更新'); } }) {
          ListItem() {
            Column() {
              Row() {
                Text('ⓘ').fontSize(22).fontColor($r('app.color.primary'))
                Column() {
                  Text('远程万物')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text(`版本 ${this.updater.currentVersion} (${this.updater.currentVersionCode})`)
                    .fontSize(12).fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start).margin({ left: 12 })
              }
              .width('100%')

              Divider().color($r('app.color.outline')).margin({ top: 14, bottom: 14 })

              Text(this.updateDescription())
                .fontSize(13)
                .fontColor(this.updater.state.kind === UpdateUiStateKind.ERROR
                  ? $r('app.color.error') : $r('app.color.text_secondary'))
                .width('100%')

              if (this.updater.state.kind === UpdateUiStateKind.AVAILABLE) {
                Button('查看正式发布版')
                  .width('100%').height(44).margin({ top: 14 })
                  .fontColor($r('app.color.on_primary'))
                  .backgroundColor($r('app.color.primary'))
                  .onClick(() => {
                    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
                    if (this.updater.state.release !== null) {
                      this.updater.openGitHubRelease(context, this.updater.state.release)
                        .catch((error: Error) => {
                          this.getUIContext().getPromptAction().showToast({
                            message: error.message !== '' ? error.message : '无法打开 GitHub'
                          });
                        });
                    }
                  })
              } else {
                Button(this.updater.state.kind === UpdateUiStateKind.CHECKING ? '正在检查…' : '检查更新')
                  .width('100%').height(44).margin({ top: 14 })
                  .fontColor($r('app.color.on_primary'))
                  .backgroundColor($r('app.color.primary'))
                  .enabled(this.updater.state.kind !== UpdateUiStateKind.CHECKING)
                  .onClick(() => { this.doCheckUpdate(); })
              }

              Button('查看 GitHub 项目')
                .width('100%').height(42).margin({ top: 8 })
                .fontColor($r('app.color.primary'))
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
                  this.updater.openGitHubProject(context)
                    .catch((error: Error) => {
                      this.getUIContext().getPromptAction().showToast({
                        message: error.message !== '' ? error.message : '无法打开 GitHub'
                      });
                    });
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.surface_card'))
            .border({ width: 1, color: $r('app.color.outline') })
            .borderRadius(16)
          }
          .padding({ left: 20, right: 20, bottom: 20 })
        }
      }
      .width('100%').layoutWeight(1)
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
