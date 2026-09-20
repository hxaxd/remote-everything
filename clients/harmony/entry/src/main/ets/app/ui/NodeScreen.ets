// S3: one node's applications.

import { AppInfo, AppState, NodeStatus } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';
import { model, CatalogPhase } from '../AppModel';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale, withAlpha, tileAlpha } from '../theme/Tokens';
import { appTone, BusyLine, Header, IconTile, Notice, SCREEN_FADE, StateBadge, nodeTone, palette } from './Components';

/** S3: one node's applications. */
@ComponentV2
export struct NodeAppsScreen {
  build() {
    NavDestination() {
      Column() {
        Header({
          title: model.nodeTitle(),
          dark: model.dark,
          actionIcon0: $r('sys.symbol.chevron_left'),
          onAction0: () => {
            model.backToList();
          },
          pathLabel: model.nodePath() === null
            ? Strings.text(MessageKeys.forNodeStatus(model.nodeStatus()))
            : Strings.text(model.nodeLinkIsLocal()
              ? MessageKeys.NODE_CURRENT_LAN : MessageKeys.NODE_CURRENT_TUNNEL),
          pathColor: model.nodePath() === null
            ? nodeTone(model.nodeStatus(), model.dark)
            : (model.nodeLinkIsLocal() ? palette(model.dark).ok : palette(model.dark).warn),
        })
        BusyLine({ visible: model.catalog.phase === CatalogPhase.Loading, dark: model.dark })
        if (model.catalog.phase === CatalogPhase.Loading) {
          Column({ space: Metrics.gapM }) {
            LoadingProgress().width(36).height(36).color(palette(model.dark).accent)
          }
          .width('100%')
          .padding(Metrics.gapXL)
          .justifyContent(FlexAlign.Center)
        } else if (model.catalog.phase === CatalogPhase.Offline) {
          Notice({
            title: Strings.text(MessageKeys.NODE_OFFLINE_TITLE),
            body: Strings.text(MessageKeys.NODE_OFFLINE_BODY),
            actionLabel: Strings.text(MessageKeys.ACTION_RETRY),
            dark: model.dark,
            onAction: () => {
              model.retryCatalog(model.catalogNodeId);
            }
          })
        } else if (model.catalog.phase === CatalogPhase.Unauthorized) {
          Notice({
            title: Strings.text(MessageKeys.ERROR_NODE_GONE),
            body: Strings.text(MessageKeys.ERROR_NODE_GONE_BODY),
            actionLabel: Strings.text(MessageKeys.ACTION_BACK_TO_NODES),
            dark: model.dark,
            onAction: () => {
              model.backToList();
            }
          })
        } else if (model.catalog.phase === CatalogPhase.Failed) {
          // Every failure the catalog can hit reads the same way the other clients
          // read it: the gateway is in trouble, ask again.
          Notice({
            title: Strings.text(MessageKeys.PAIR_GATEWAY_TROUBLE),
            body: '',
            actionLabel: Strings.text(MessageKeys.ACTION_RETRY),
            dark: model.dark,
            onAction: () => {
              model.retryCatalog(model.catalogNodeId);
            }
          })
        } else if (model.catalog.apps.length === 0) {
          Notice({
            title: Strings.text(MessageKeys.APPS_EMPTY_TITLE),
            body: Strings.text(MessageKeys.APPS_EMPTY_BODY),
            actionLabel: '',
            dark: model.dark,
            onAction: () => {
            }
          })
        } else {
          List() {
            ForEach(model.catalog.apps, (app: AppInfo) => {
              ListItem() {
                this.AppRowView(app)
              }
            }, (app: AppInfo) =>
              // The key carries what the row draws: a key of the id alone would
              // keep the old row on screen while the state under it moved — a
              // start or stop that looked like it did nothing.
              `${app.id}|${app.code}|${app.enabled ? 1 : 0}`)
          }
          .layoutWeight(1)
          .width('100%')
          .divider({
            strokeWidth: Metrics.hairline,
            color: palette(model.dark).hairline,
            startMargin: Metrics.pageMargin
          })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .transition(SCREEN_FADE)
      .height('100%')
      .backgroundColor(palette(model.dark).bg)
    }
    .hideTitleBar(true)
    .backgroundColor(palette(model.dark).bg)
    .onShown(() => {
      model.startCatalogRefresh();
    })
    .onHidden(() => {
      model.stopCatalogRefresh();
    })
    .onBackPressed(() => {
      return false;
    })
  }

  @Builder
  AppRowView(app: AppInfo) {
    Row({ space: Metrics.gapM }) {
      IconTile({ icon: app.icon, accent: app.accent, dark: model.dark })
      Column({ space: 2 }) {
        Text(app.name)
          .fontSize(TypeScale.headline)
          .fontWeight(FontWeight.Medium)
          .fontColor(palette(model.dark).textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (app.description !== '') {
          Text(app.description)
            .fontSize(TypeScale.caption)
            .fontColor(palette(model.dark).textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      StateBadge({
        label: Strings.appState(app.code),
        color: appTone(app.code, model.dark),
        dark: model.dark
      })
      if (app.code === AppState.Starting || app.code === AppState.Stopping) {
        // A request is in flight: the row shows that rather than a button that
        // would send it a second time.
        LoadingProgress().width(20).height(20).color(palette(model.dark).accent)
      } else {
        Text(Strings.text(app.code === AppState.Stopped ? MessageKeys.ACTION_START : MessageKeys.ACTION_STOP))
          .fontSize(TypeScale.caption)
          .fontColor(palette(model.dark).accent)
          .padding({ left: Metrics.gapS, right: Metrics.gapS, top: 6, bottom: 6 })
          .backgroundColor(withAlpha(palette(model.dark).accent, tileAlpha(model.dark)))
          .borderRadius(Metrics.radiusPill)
          .onClick(() => {
            model.toggleApp(model.catalogNodeId, app);
          })
      }
    }
    .width('100%')
    .height(Metrics.rowApp)
    .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // A stopped application that will not start itself on open is not a door:
      // tapping it does nothing, the way the other clients behave. Start it first.
      if (app.code === AppState.Stopped && !app.enabled) {
        return;
      }
      model.openApp(model.catalogNodeId, app);
    })
  }
}

/** NodeScreen alias matching iOS/Android naming convention. */
@ComponentV2
export struct NodeScreen {
  build() {
    NodeAppsScreen()
  }
}
