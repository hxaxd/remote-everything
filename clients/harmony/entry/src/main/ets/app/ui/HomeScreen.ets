// S0 (Empty) and S1 (Node list) screens.

import { NodeStatus } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';
import { model, NodeRow } from '../AppModel';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale, withAlpha, tileAlpha } from '../theme/Tokens';
import { BusyLine, EmptyState, Header, StateBadge, nodeTone, palette } from './Components';

/** S0: nothing has been added yet, or everything was taken away. */
@ComponentV2
export struct EmptyScreen {
  build() {
    Column() {
      EmptyState({
        title: Strings.text(MessageKeys.EMPTY_TITLE),
        body: Strings.text(MessageKeys.EMPTY_BODY),
        actionLabel: Strings.text(MessageKeys.ACTION_ADD_NODE),
        dark: model.dark,
        onAction: () => {
          model.beginPairing();
          model.pushAddNode();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(palette(model.dark).bg)
  }
}

/** S1: every node this device may reach, through every gateway it holds. */
@ComponentV2
export struct NodesScreen {
  build() {
    Column() {
      Header({
        title: Strings.text(MessageKeys.APP_NAME),
        dark: model.dark,
        actionLabel: '+',
        actionLabel2: '⚙',
        onAction: () => {
          model.beginPairing();
          model.pushAddNode();
        },
        onAction2: () => {
          model.pushSettings();
        }
      })
      BusyLine({ visible: model.refreshing, dark: model.dark })
      if (model.needsPairing.length > 0) {
        Column({ space: 2 }) {
          Text(Strings.text(MessageKeys.IDENTITY_NEEDS_PAIRING_TITLE))
            .fontSize(TypeScale.body)
            .fontColor(palette(model.dark).warn)
          Text(Strings.text(MessageKeys.IDENTITY_NEEDS_PAIRING_BODY))
            .fontSize(TypeScale.caption)
            .fontColor(palette(model.dark).textSecondary)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(Metrics.gapM)
        .backgroundColor(withAlpha(palette(model.dark).warn, tileAlpha(model.dark)))
        .borderRadius(Metrics.radiusCard)
        .margin({ left: Metrics.pageMargin, right: Metrics.pageMargin, bottom: Metrics.gapS })
        .onClick(() => {
          model.beginPairing();
          model.pushAddNode();
        })
      }
      if (model.nodes.length === 0) {
        EmptyState({
          title: Strings.text(MessageKeys.EMPTY_TITLE),
          body: Strings.text(MessageKeys.EMPTY_BODY),
          actionLabel: Strings.text(MessageKeys.ACTION_ADD_NODE),
          dark: model.dark,
          onAction: () => {
            model.beginPairing();
            model.pushAddNode();
          }
        })
      } else {
        // The gesture is the pull; the progress is the line above, which is never the
        // gesture's own spinner (pitfalls §5).
        Refresh({ refreshing: false }) {
          List() {
            ForEach(model.nodes, (row: NodeRow) => {
              ListItem() {
                this.NodeRowView(row)
              }
            }, (row: NodeRow) => row.node.id)
          }
          .width('100%')
          .divider({
            strokeWidth: Metrics.hairline,
            color: palette(model.dark).hairline,
            startMargin: Metrics.pageMargin
          })
          .scrollBar(BarState.Off)
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          model.refreshNodes();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(palette(model.dark).bg)
  }

  @Builder
  NodeRowView(row: NodeRow) {
    Row({ space: Metrics.gapM }) {
      Column({ space: 2 }) {
        Text(row.node.name)
          .fontSize(TypeScale.headline)
          .fontWeight(FontWeight.Medium)
          .fontColor(palette(model.dark).textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(Strings.text(MessageKeys.forNodeStatus(row.status)))
          .fontSize(TypeScale.caption)
          .fontColor(nodeTone(row.status, model.dark))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (row.isOnline) {
        StateBadge({
          label: Strings.text(MessageKeys.forNodeStatus(row.status)),
          color: nodeTone(row.status, model.dark),
          dark: model.dark
        })
      }
    }
    .width('100%')
    .height(Metrics.rowNode)
    .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin })
    .alignItems(VerticalAlign.Center)
    .opacity(row.status === NodeStatus.Offline ? 0.55 : 1)
    .onClick(() => {
      model.selectNode(row.node.id);
    })
  }
}

/** HomeScreen root component matching iOS/Android naming. */
@ComponentV2
export struct HomeScreen {
  build() {
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
}
