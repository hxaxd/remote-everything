import { ConnectionConfig, ConnectionMode } from '../../core/models/ConnectionConfig';

@Component
export struct ConnectionsPage {
  @Prop profiles: ConnectionConfig[];
  @Prop activeInstallationId: string;
  onSelect: (profile: ConnectionConfig) => void = (_profile: ConnectionConfig): void => {};
  onDelete: (profile: ConnectionConfig) => void = (_profile: ConnectionConfig): void => {};

  build() {
    Column() {
      if (this.profiles.length === 0) {
        Column() {
          Text('💻').fontSize(48)
          Text('没有连接').fontSize(20).fontWeight(FontWeight.Bold).margin({ top: 16 })
          Text('粘贴初始化链接添加第一台计算机')
            .fontSize(14).fontColor('#999999').margin({ top: 8 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.profiles, (profile: ConnectionConfig) => {
            ListItem() {
              Row() {
                Column() {
                  Text(profile.name).fontSize(16).fontWeight(FontWeight.Medium)
                  Text(profile.gatewayOrigin).fontSize(12).fontColor('#999999')
                  Text(profile.mode === ConnectionMode.LAN ? '局域网' : '公网')
                    .fontSize(10).fontColor('#BBBBBB')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (profile.installationId === this.activeInstallationId) {
                  Text('✓').fontColor('#4CAF50').fontSize(18).fontWeight(FontWeight.Bold)
                }
              }
              .width('100%').padding(12)
              .onClick(() => this.onSelect(profile))
            }
            .swipeAction({ end: { builder: () => { this.deleteAction(profile) } } })
          }, (profile: ConnectionConfig) => profile.installationId)
        }
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  deleteAction(profile: ConnectionConfig) {
    Button('删除')
      .backgroundColor('#F44336')
      .fontColor(Color.White)
      .onClick(() => this.onDelete(profile))
  }
}
