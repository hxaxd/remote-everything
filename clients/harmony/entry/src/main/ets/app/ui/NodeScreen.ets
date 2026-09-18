// S3: one node's applications.

import { AppInfo } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';
import { model, CatalogPhase } from '../AppModel';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale, withAlpha, tileAlpha } from '../theme/Tokens';
import { appTone, BusyLine, Header, IconTile, Notice, StateBadge, palette } from './Components';

/** S3: one node's applications. */
@ComponentV2
export struct NodeAppsScreen {
  build() {
    NavDestination() {
      Column() {
        Header({
          title: model.nodeTitle(),
          dark: model.dark,
          pathLabel: model.nodePath() === null ? ''
            : Strings.text(model.nodePath()!.isPrivate ? MessageKeys.NODE_LAN : MessageKeys.NODE_TUNNEL),
          pathColor: model.nodePath() === null ? ''
            : (model.nodePath()!.isPrivate ? palette(model.dark).ok : palette(model.dark).accent),
          actionLabel: '',
          onAction: () => {
          }
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
              model.loadCatalog(model.catalogNodeId);
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
          Notice({
            title: Strings.text(model.catalog.errorCode === null ? MessageKeys.PAIR_NETWORK
              : MessageKeys.forError(model.catalog.errorCode)),
            body: '',
            actionLabel: Strings.text(MessageKeys.ACTION_RETRY),
            dark: model.dark,
            onAction: () => {
              model.loadCatalog(model.catalogNodeId);
            }
          })
        } else if (model.catalog.apps.length === 0) {
          Notice({
            title: Strings.text(MessageKeys.APPS_EMPTY_TITLE),
            body: '',
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
            }, (app: AppInfo) => app.id)
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
      if (model.catalog.busyAppId === app.id) {
        LoadingProgress().width(20).height(20).color(palette(model.dark).accent)
      } else {
        Text(Strings.text(app.enabled ? MessageKeys.ACTION_STOP : MessageKeys.ACTION_START))
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
