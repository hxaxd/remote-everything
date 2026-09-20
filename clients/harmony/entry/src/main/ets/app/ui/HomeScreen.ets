// S0 (Empty) and S1 (Node list) — one screen, the way the other clients draw it:
// a top bar with refresh, add and settings; a banner for a pairing that is waiting
// for its approval; the node list, or the three-line empty state.

import { GatewayPath, LinkKind, NodeStatus } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';
import { model, NodeRow } from '../AppModel';
import { PairingStage, PairingState } from '../State';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale, withAlpha, tileAlpha } from '../theme/Tokens';
import { BusyLine, EmptyState, Header, StateBadge, nodeTone, palette } from './Components';

/** The home screen: the bar, the banners, and the list — or the empty state. */
@ComponentV2
export struct HomeScreen {
  build() {
    Column() {
      Header({
        title: Strings.text(MessageKeys.APP_NAME),
        dark: model.dark,
        actionIcon: $r('sys.symbol.gearshape'),
        actionIcon2: $r('sys.symbol.plus'),
        actionIcon3: $r('sys.symbol.arrow_clockwise'),
        onAction: () => {
          model.pushSettings();
        },
        onAction2: () => {
          model.beginPairing();
          model.pushAddNode();
        },
        onAction3: () => {
          model.refreshNodes();
        }
      })
      // The list's pull-refresh indicator is the one spinner; the header's arrow
      // stays a quiet icon, the way the other clients draw it.
      if (model.pairing.stage === PairingStage.WaitingApproval) {
        // A device that paired but is not approved yet: saying so is the difference
        // between "it did not work" and "it is waiting" — with the one thing a
        // person can do about it right on the banner.
        Row({ space: Metrics.gapS }) {
          StateBadge({
            label: Strings.text(MessageKeys.NODE_PENDING),
            color: palette(model.dark).warn,
            dark: model.dark
          })
          Text(this.pendingNodeName())
            .fontSize(TypeScale.body)
            .fontColor(palette(model.dark).textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Button(Strings.text(MessageKeys.ACTION_RETRY))
            .fontSize(TypeScale.caption)
            .fontColor(palette(model.dark).accentOnBg)
            .backgroundColor(palette(model.dark).accent)
            .borderRadius(Metrics.radiusControl)
            .height(Metrics.rowSettings)
            .padding({ left: Metrics.gapM, right: Metrics.gapM })
            .onClick(() => {
              model.retryStaged();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin, top: Metrics.gapS, bottom: Metrics.gapS })
      }
      // The gesture is the pull; the progress is the Refresh's own spinner
      // (pitfalls §5). An empty list is a list: the empty state pulls the same way,
      // so both live inside the one Refresh.
      Refresh({ refreshing: model.refreshing }) {
        if (model.nodes.length === 0) {
          Scroll() {
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
            .height('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        } else {
          List() {
            ForEach(model.nodes, (row: NodeRow) => {
              ListItem() {
                this.NodeRowView(row)
              }
              .padding({ left: Metrics.gapM, right: Metrics.gapM })
            }, (row: NodeRow) =>
              // The key carries what the row draws — state and the way in — so a
              // refresh that changes them redraws the row instead of keeping the
              // old one on screen under an unchanged id.
              `${row.node.id}|${row.status}|${row.chosen === null ? '' : row.chosen.origin}`)
          }
          .width('100%')
          .scrollBar(BarState.Off)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        model.refreshNodes();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(palette(model.dark).bg)
  }

  /** The machine a pending pairing is waiting on, from wherever the state kept it. */
  private pendingNodeName(): string {
    const pairing: PairingState = model.pairing;
    if (pairing.setup !== null) {
      return pairing.setup.nodeName;
    }
    return pairing.nodeName;
  }

  /** One dot and one word per way in that exists, the one in use standing out. */
  @Builder
  LinkDotsView(row: NodeRow) {
    Row({ space: Metrics.gapM }) {
      ForEach([LinkKind.Local, LinkKind.Tunnel], (kind: LinkKind) => {
        if (row.node.paths.some((path: GatewayPath) => path.link === kind)) {
          Row({ space: 4 }) {
            Circle()
              .width(7)
              .height(7)
              .fill(row.linkTone(kind, model.dark))
            Text(Strings.text(kind === LinkKind.Local ? MessageKeys.NODE_LAN : MessageKeys.NODE_TUNNEL))
              .fontSize(TypeScale.caption)
              .fontColor(row.linkTone(kind, model.dark))
              .maxLines(1)
          }
        }
      }, (kind: LinkKind) => `${kind}`)
    }
  }

  @Builder
  NodeRowView(row: NodeRow) {
    Row({ space: Metrics.gapM }) {
      Text(row.node.name)
        .fontSize(TypeScale.headline)
        .fontWeight(FontWeight.Medium)
        .fontColor(row.status === NodeStatus.Offline
          ? palette(model.dark).textTertiary : palette(model.dark).textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      // Which ways in this device has, and which one it would take. A node nobody
      // has answered for yet, and one waiting for its approval, wear their state
      // instead — there are no roads to describe.
      if (row.status === NodeStatus.PendingApproval || row.status === NodeStatus.Unknown) {
        StateBadge({
          label: Strings.text(MessageKeys.forNodeStatus(row.status)),
          color: nodeTone(row.status, model.dark),
          dark: model.dark
        })
      } else {
        this.LinkDotsView(row)
      }
    }
    .width('100%')
    .height(Metrics.rowNode)
    .padding({ left: Metrics.gapM, right: Metrics.gapM })
    .alignItems(VerticalAlign.Center)
    // One machine is one card, the same one the settings give a connection: a
    // list of flat rows is a list a person cannot tell apart at a glance. The
    // horizontal inset is the ListItem's padding — a 100% card plus its own
    // margins is wider than the screen, and its right side goes past the glass.
    // The machine whose page is open wears the accent, the way the other
    // clients mark the row in use.
    .backgroundColor(model.catalogNodeId === row.node.id
      ? withAlpha(palette(model.dark).accent, tileAlpha(model.dark))
      : palette(model.dark).bgElevated)
    .borderRadius(Metrics.radiusCard)
    .border({ width: 1, color: palette(model.dark).hairline })
    .margin({
      top: Metrics.gapS / 2,
      bottom: Metrics.gapS / 2
    })
    .onClick(() => {
      model.selectNode(row.node.id);
    })
  }
}
