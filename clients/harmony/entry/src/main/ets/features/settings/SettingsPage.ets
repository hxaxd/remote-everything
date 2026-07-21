import { common } from '@kit.AbilityKit';
import { AppUpdater, UpdateUiState, UpdateUiStateKind } from '../../core/update/AppUpdater';

/**
 * Settings: orientation, display mode, theme, connection, about & update.
 * Mirrors Android's `SettingsScreen`.
 */
@Component
export struct SettingsPage {
  @State selectedTheme: string = 'system';
  @State selectedDisplay: string = 'phone';
  @State selectedOrientation: string = 'system';
  @State versionName: string = '';
  @State versionCode: number = 0;
  @State updater: AppUpdater = new AppUpdater();
  @State updateText: string = '从项目正式发布页检查新版本。';
  @State updateProgress: number = 0;
  @State checking: boolean = false;
  @State hasUpdate: boolean = false;
  @State updateUrl: string = '';
  @State updateError: boolean = false;

  aboutToAppear(): void {
    this.updater.load().then(() => {
      this.versionName = this.updater.currentVersion;
      this.versionCode = this.updater.currentVersionCode;
    });
  }

  async doCheckUpdate(): Promise<void> {
    this.checking = true;
    this.updateError = false;
    this.updateText = '正在查询最新正式发布版…';

    await this.updater.checkForUpdates();

    const state = this.updater.state;
    switch (state.kind) {
      case UpdateUiStateKind.CURRENT:
        this.updateText = state.currentIsNewer
          ? `当前版本高于最新正式版 ${state.latestVersion}。`
          : `当前已是最新正式版 ${state.latestVersion}。`;
        break;
      case UpdateUiStateKind.AVAILABLE:
        this.hasUpdate = true;
        this.updateText = `发现新版本 ${state.release!.versionName}，可在 GitHub 查看详情。`;
        this.updateUrl = state.release!.pageUrl;
        break;
      case UpdateUiStateKind.ERROR:
        this.updateError = true;
        this.updateText = state.detail;
        break;
    }
    this.checking = false;
  }

  @Builder
  groupHeader(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor('#666666')
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 6 })
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
                .type(this.selectedOrientation === 'system' ? ButtonType.Normal : ButtonType.Capsule)
                .onClick(() => { this.selectedOrientation = 'system'; })
              Button('竖屏锁定')
                .fontSize(13)
                .type(this.selectedOrientation === 'portrait' ? ButtonType.Normal : ButtonType.Capsule)
                .onClick(() => { this.selectedOrientation = 'portrait'; })
              Button('横屏锁定')
                .fontSize(13)
                .type(this.selectedOrientation === 'landscape' ? ButtonType.Normal : ButtonType.Capsule)
                .onClick(() => { this.selectedOrientation = 'landscape'; })
            }
            .width('100%').padding(8)
          }
        }

        // Display mode
        ListItemGroup({ header: () => { this.groupHeader('显示模式'); } }) {
          ListItem() {
            Row() {
              Button('手机')
                .fontSize(13)
                .type(this.selectedDisplay === 'phone' ? ButtonType.Normal : ButtonType.Capsule)
                .onClick(() => { this.selectedDisplay = 'phone'; })
              Button('电脑')
                .fontSize(13)
                .type(this.selectedDisplay === 'desktop' ? ButtonType.Normal : ButtonType.Capsule)
                .onClick(() => { this.selectedDisplay = 'desktop'; })
            }
            .width('100%').padding(8)
          }
        }

        // Theme
        ListItemGroup({ header: () => { this.groupHeader('主题'); } }) {
          ListItem() {
            Row() {
              Button('跟随系统')
                .fontSize(13)
                .type(this.selectedTheme === 'system' ? ButtonType.Normal : ButtonType.Capsule)
                .onClick(() => { this.selectedTheme = 'system'; })
              Button('浅色')
                .fontSize(13)
                .type(this.selectedTheme === 'light' ? ButtonType.Normal : ButtonType.Capsule)
                .onClick(() => { this.selectedTheme = 'light'; })
              Button('深色')
                .fontSize(13)
                .type(this.selectedTheme === 'dark' ? ButtonType.Normal : ButtonType.Capsule)
                .onClick(() => { this.selectedTheme = 'dark'; })
            }
            .width('100%').padding(8)
          }
        }

        // About & Update
        ListItemGroup({ header: () => { this.groupHeader('关于与更新'); } }) {
          ListItem() {
            Column() {
              Row() {
                Text('ℹ').fontSize(20).fontColor('#007AFF')
                Column() {
                  Text('远程万物').fontSize(16).fontWeight(FontWeight.Medium)
                  Text(`版本 ${this.versionName} (${this.versionCode})`)
                    .fontSize(12).fontColor('#999999')
                }
                .alignItems(HorizontalAlign.Start).margin({ left: 12 })
              }
              .width('100%')

              Divider().margin({ top: 12, bottom: 12 })

              Text(this.updateText)
                .fontSize(13)
                .fontColor(this.updateError ? '#F44336' : '#999999')
                .width('100%')

              if (this.updateProgress > 0 && this.updateProgress < 1) {
                Progress({ value: this.updateProgress * 100, total: 100 })
                  .width('100%').margin({ top: 8, bottom: 8 })
              }

              if (this.hasUpdate) {
                Button('查看正式发布版')
                  .width('100%').margin({ top: 12 })
                  .onClick(() => {
                    const context = getContext(this) as common.UIAbilityContext;
                    if (this.updater.state.release !== null) {
                      this.updater.openGitHubRelease(context, this.updater.state.release);
                    }
                  })
              } else {
                Button(this.checking ? '正在检查…' : '检查更新')
                  .width('100%').margin({ top: 12 })
                  .enabled(!this.checking)
                  .onClick(() => { this.doCheckUpdate(); })
              }

              Button('查看 GitHub 项目')
                .width('100%').margin({ top: 8 })
                .fontColor('#007AFF')
                .onClick(() => {
                  const context = getContext(this) as common.UIAbilityContext;
                  this.updater.openGitHubProject(context);
                })
            }
            .width('100%').padding(12)
          }
        }
      }
      .width('100%').layoutWeight(1)
    }
    .width('100%').height('100%')
  }
}
