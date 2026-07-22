import { ConnectionConfig, ConnectionMode } from '../../core/models/ConnectionConfig';

@Component
export struct ConnectionsPage {
  @Prop profiles: ConnectionConfig[];
  @Prop activeInstallationId: string;
  @Prop interactionsEnabled: boolean = true;
  onSelect: (profile: ConnectionConfig) => void = (_profile: ConnectionConfig): void => {};
  onDelete: (profile: ConnectionConfig) => void = (_profile: ConnectionConfig): void => {};

  build() {
    Column() {
      if (this.profiles.length === 0) {
        Column() {
          Text('还没有已保存的连接')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Text('已有连接')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 20, right: 20, top: 16, bottom: 8 })

        List() {
          ForEach(this.profiles, (profile: ConnectionConfig) => {
            ListItem() {
              Row() {
                Column() {
                  Row() {
                    Text(profile.name)
                      .fontSize(16)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                    if (profile.installationId === this.activeInstallationId) {
                      Text('当前')
                        .fontSize(10)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.on_primary_container'))
                        .backgroundColor($r('app.color.primary_container'))
                        .borderRadius(8)
                        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                        .margin({ left: 8 })
                    }
                  }
                  Text(profile.gatewayOrigin)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 5 })
                  Text(profile.mode === ConnectionMode.LAN ? '局域网' : '公网')
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .enabled(this.interactionsEnabled)
                .onClick(() => {
                  if (this.interactionsEnabled) this.onSelect(profile);
                })

                Button('删除')
                  .width(62)
                  .height(36)
                  .fontSize(12)
                  .fontColor($r('app.color.error'))
                  .backgroundColor(Color.Transparent)
                  .border({ width: 1, color: $r('app.color.outline') })
                  .enabled(this.interactionsEnabled)
                  .onClick(() => {
                    if (this.interactionsEnabled) this.onDelete(profile);
                  })
              }
              .width('100%')
              .padding(16)
              .backgroundColor(profile.installationId === this.activeInstallationId
                ? $r('app.color.primary_container')
                : $r('app.color.surface_card'))
              .border({ width: 1, color: profile.installationId === this.activeInstallationId
                ? $r('app.color.primary')
                : $r('app.color.outline') })
              .borderRadius(16)
            }
            .padding({ left: 20, right: 20, top: 6, bottom: 6 })
            .opacity(this.interactionsEnabled ? 1 : 0.55)
          }, (profile: ConnectionConfig) => profile.installationId)
        }
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
