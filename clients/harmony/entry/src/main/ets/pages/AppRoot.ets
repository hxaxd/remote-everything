// The one page: the navigation shell, and with it S0, S1 and the destinations for
// S2, S3, S4 and S5.
//
// Narrow screens stack: the node list, and whatever is pushed on top of it. Wide ones
// — a short side of 840 vp or more, which is a tablet or an unfolded foldable — split
// (ui-contract §6): the list stays on the left and a node's applications appear on the
// right, which is what the same two screens are when there is room for both.

import { deviceInfo } from '@kit.BasicServicesKit';
import { model } from '../app/AppModel';
import { Strings, defaultDeviceName } from '../app/i18n/Strings';
import { Metrics } from '../app/theme/Tokens';
import { palette } from '../app/ui/Components';
import { EmptyScreen, NodesScreen } from '../app/ui/HomeScreen';
import { AddNodeScreen } from '../app/ui/PairScreen';
import { NodeAppsScreen } from '../app/ui/NodeScreen';
import { SettingsScreen } from '../app/ui/SettingsScreen';
import { WebScreen } from '../app/web/WebScreen';

@Entry
@ComponentV2
struct AppRoot {
  @Local private stack: NavPathStack = new NavPathStack();

  build() {
    Stack() {
      Navigation(this.stack) {
        Column() {
          if (model.identities.length === 0) {
            EmptyScreen()
          } else {
            NodesScreen()
          }
        }
        .width('100%')
        .height('100%')
      }
      .mode(model.wide ? NavigationMode.Split : NavigationMode.Stack)
      .navBarWidth('38%')
      .navBarWidthRange(['320vp', '480vp'])
      .hideTitleBar(true)
      .navDestination(this.destination)
      .width('100%')
      .height('100%')
      .backgroundColor(palette(model.dark).bg)

      if (model.toast !== '') {
        Column() {
          Text(Strings.text(model.toast))
            .fontSize(Metrics.rowSettings > 0 ? 13 : 13)
            .fontColor(palette(model.dark).textPrimary)
            .padding({ left: Metrics.gapM, right: Metrics.gapM, top: Metrics.gapS, bottom: Metrics.gapS })
            .backgroundColor(palette(model.dark).bgElevated)
            .borderRadius(Metrics.radiusControl)
            .border({ width: Metrics.hairline, color: palette(model.dark).hairline })
            .maxLines(2)
        }
        .width('100%')
        .height('100%')
        .padding({ left: Metrics.gapM, right: Metrics.gapM, bottom: Metrics.gapXL })
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(palette(model.dark).bg)
  }

  /** S2, S3, S4 and S5 are destinations of this one navigation. */
  @Builder
  destination(name: string) {
    if (name === 'add') {
      AddNodeScreen()
    } else if (name === 'node') {
      NodeAppsScreen()
    } else if (name === 'web') {
      WebScreen()
    } else if (name === 'settings') {
      SettingsScreen()
    }
  }

  aboutToAppear(): void {
    model.attachStack(this.stack);
    model.setDeviceName(defaultDeviceName());
    // A link that launched this app opens the add-node flow with itself filled in.
    const link: string = model.pendingLink;
    if (link !== '') {
      model.openFromLink(model.consumePendingLink());
    }
    model.listenWindowSize(this.getUIContext().getHostContext());
    model.foregroundChanged(true);
    model.startNodesRefresh();
  }

  onPageShow(): void {
    model.foregroundChanged(true);
  }

  onPageHide(): void {
    model.foregroundChanged(false);
  }

  onBackPress(): boolean {
    // On the list itself, back belongs to the platform: the app goes to the background.
    // A destination's own back is handled where it is.
    return false;
  }
}
