// The screens themselves: S0 through S3 and S5. Each one renders what the model says
// and calls the model for what it wants done; none of them talks to a gateway, and
// none of them holds state the model does not have.

import { common } from '@kit.AbilityKit';
import { scanBarcode } from '@kit.ScanKit';
import { AppInfo, AppState, Appearance, Identity, Language, NodeStatus } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';
import { PairingStage } from '../../core/pairing/PairingMachine';
import { UpdateVerdict } from '../../core/api/ReleaseChannel';
import { model, CatalogPhase, NodeRow } from '../AppModel';
import { defaultDeviceName, Strings } from '../i18n/Strings';
import { Metrics, TypeScale, withAlpha, tileAlpha, MONO_FAMILY } from '../theme/Tokens';
import { BusyLine, ChoiceRow, DetailRow, EmptyState, Header, IconTile, Notice, palette, SectionHeader, StateBadge } from './Widgets';

/** The colour a node's state is written in: the path colour when it is up, grey when
 * it is not — offline and stopped are never red (style.md §2). */
function nodeTone(status: NodeStatus, dark: boolean): string {
  const colors = palette(dark);
  if (status === NodeStatus.OnlineLan) {
    return colors.ok;
  }
  if (status === NodeStatus.OnlineTunnel) {
    return colors.accent;
  }
  if (status === NodeStatus.PendingApproval) {
    return colors.warn;
  }
  return colors.offline;
}

function appTone(state: AppState, dark: boolean): string {
  const colors = palette(dark);
  if (state === AppState.Ready) {
    return colors.ok;
  }
  if (state === AppState.Starting || state === AppState.Stopping) {
    return colors.warn;
  }
  return colors.offline;
}

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

/** S2: scan or paste an invitation, look at what it says, pair. */
@ComponentV2
export struct AddNodeScreen {
  @Local link: string = '';
  @Local deviceName: string = defaultDeviceName();

  build() {
    NavDestination() {
      Column() {
        Header({
          title: Strings.text(MessageKeys.PAIR_TITLE),
          dark: model.dark,
          actionLabel: '',
          onAction: () => {
          }
        })
        if (model.pairing.stage === PairingStage.Input) {
          this.InputStage()
        } else if (model.pairing.stage === PairingStage.Confirm) {
          this.ConfirmStage()
        } else if (model.pairing.stage === PairingStage.WaitingApproval) {
          this.WaitingStage()
        } else if (model.pairing.stage === PairingStage.Failed) {
          this.FailedStage()
        } else {
          this.WorkingStage()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(palette(model.dark).bg)
    }
    .hideTitleBar(true)
    .backgroundColor(palette(model.dark).bg)
  }

  @Builder
  InputStage() {
    Column({ space: Metrics.gapM }) {
      Button(Strings.text(MessageKeys.PAIR_SCAN))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).accent)
        .backgroundColor(withAlpha(palette(model.dark).accent, tileAlpha(model.dark)))
        .borderRadius(Metrics.radiusControl)
        .height(Metrics.rowSettings)
        .width('100%')
        .onClick(() => {
          this.scan();
        })
      TextArea({ placeholder: Strings.text(MessageKeys.PAIR_INPUT_HINT), text: this.link })
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textPrimary)
        .backgroundColor(palette(model.dark).bgElevated)
        .borderRadius(Metrics.radiusControl)
        .height(96)
        .width('100%')
        .onChange((value: string) => {
          this.link = value;
        })
      if (model.pairing.errorKey !== null) {
        Text(Strings.text(model.pairing.errorKey))
          .fontSize(TypeScale.caption)
          .fontColor(palette(model.dark).danger)
          .width('100%')
      }
      Button(Strings.text(MessageKeys.ACTION_CONFIRM))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).accentOnBg)
        .backgroundColor(palette(model.dark).accent)
        .borderRadius(Metrics.radiusControl)
        .height(Metrics.rowSettings)
        .width('100%')
        .enabled(this.link.trim().length > 0)
        .onClick(() => {
          model.submitLink(this.link);
        })
    }
    .width('100%')
    .padding(Metrics.pageMargin)
  }

  @Builder
  ConfirmStage() {
    Column({ space: Metrics.gapM }) {
      DetailRow({
        label: Strings.text(MessageKeys.PAIR_NODE_LABEL),
        value: model.pairing.setup === null ? '' : model.pairing.setup.nodeName,
        dark: model.dark
      })
      DetailRow({
        label: Strings.text(MessageKeys.PAIR_GATEWAY_LABEL),
        value: model.pairing.setup === null ? '' : model.pairing.setup.origin,
        dark: model.dark,
        mono: true
      })
      Text(Strings.text(MessageKeys.PAIR_DEVICE_NAME))
        .fontSize(TypeScale.caption)
        .fontColor(palette(model.dark).textSecondary)
        .width('100%')
      TextInput({ text: this.deviceName })
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textPrimary)
        .backgroundColor(palette(model.dark).bgElevated)
        .borderRadius(Metrics.radiusControl)
        .height(Metrics.rowSettings)
        .width('100%')
        .onChange((value: string) => {
          this.deviceName = value;
        })
      Text(Strings.text(MessageKeys.PAIR_DEVICE_NAME_HINT))
        .fontSize(TypeScale.footnote)
        .fontColor(palette(model.dark).textTertiary)
        .width('100%')
      Row({ space: Metrics.gapM }) {
        Button(Strings.text(MessageKeys.ACTION_BACK))
          .fontSize(TypeScale.body)
          .fontColor(palette(model.dark).textPrimary)
          .backgroundColor(palette(model.dark).bgElevated)
          .borderRadius(Metrics.radiusControl)
          .height(Metrics.rowSettings)
          .layoutWeight(1)
          .onClick(() => {
            model.editLink();
          })
        Button(model.pairingBusy ? Strings.text(MessageKeys.PAIR_WORKING) : Strings.text(MessageKeys.PAIR_ACTION_JOIN))
          .fontSize(TypeScale.body)
          .fontColor(palette(model.dark).accentOnBg)
          .backgroundColor(palette(model.dark).accent)
          .borderRadius(Metrics.radiusControl)
          .height(Metrics.rowSettings)
          .layoutWeight(1)
          .enabled(!model.pairingBusy)
          .onClick(() => {
            model.editDeviceNameForPairing(this.deviceName);
            model.confirmPairing();
          })
      }
      .width('100%')
      if (model.pairingBusy) {
        Progress({ value: 40, total: 100, type: ProgressType.Linear })
          .color(palette(model.dark).accent)
          .width('100%')
          .height(2)
      }
    }
    .width('100%')
    .padding(Metrics.pageMargin)
  }

  @Builder
  WorkingStage() {
    Column({ space: Metrics.gapM }) {
      LoadingProgress().width(40).height(40).color(palette(model.dark).accent)
      Text(Strings.text(MessageKeys.PAIR_WORKING))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textSecondary)
    }
    .width('100%')
    .padding(Metrics.gapXL)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  WaitingStage() {
    Column({ space: Metrics.gapM }) {
      LoadingProgress().width(40).height(40).color(palette(model.dark).warn)
      Text(Strings.text(MessageKeys.PAIR_WAITING_APPROVAL))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textSecondary)
        .textAlign(TextAlign.Center)
      Button(Strings.text(MessageKeys.ACTION_BACK))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textPrimary)
        .backgroundColor(palette(model.dark).bgElevated)
        .borderRadius(Metrics.radiusControl)
        .height(Metrics.rowSettings)
        .onClick(() => {
          model.backToList();
        })
    }
    .width('100%')
    .padding(Metrics.gapXL)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  FailedStage() {
    Column({ space: Metrics.gapM }) {
      Text(Strings.text(model.pairing.errorKey === null ? MessageKeys.PAIR_NETWORK : model.pairing.errorKey))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textPrimary)
        .textAlign(TextAlign.Center)
      Row({ space: Metrics.gapM }) {
        Button(Strings.text(MessageKeys.ACTION_BACK))
          .fontSize(TypeScale.body)
          .fontColor(palette(model.dark).textPrimary)
          .backgroundColor(palette(model.dark).bgElevated)
          .borderRadius(Metrics.radiusControl)
          .height(Metrics.rowSettings)
          .layoutWeight(1)
          .onClick(() => {
            model.editLink();
          })
        Button(Strings.text(MessageKeys.ACTION_RETRY))
          .fontSize(TypeScale.body)
          .fontColor(palette(model.dark).accentOnBg)
          .backgroundColor(palette(model.dark).accent)
          .borderRadius(Metrics.radiusControl)
          .height(Metrics.rowSettings)
          .layoutWeight(1)
          .onClick(() => {
            model.editLink();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Metrics.gapXL)
  }

  /** Scanning is the platform's own scan view; the code comes back as text. */
  private scan(): void {
    const context: common.UIAbilityContext | null = model.abilityContext();
    if (context === null) {
      return;
    }
    scanBarcode.startScanForResult(context)
      .then((result: scanBarcode.ScanResult) => {
        if (result.originalValue !== undefined && result.originalValue !== '') {
          this.link = result.originalValue;
          model.submitLink(result.originalValue);
        }
      })
      .catch((error: Object) => {
        model.showToast(MessageKeys.PAIR_SCAN_FAILED);
      });
  }
}

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
      // Not consumed: the platform pops this page, which is what going back means here.
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

/** S5: display, the gateways this device holds, and what this build is. */
@ComponentV2
export struct SettingsScreen {
  build() {
    NavDestination() {
      Column() {
        Header({
          title: Strings.text(MessageKeys.SETTINGS_TITLE),
          dark: model.dark,
          actionLabel: '',
          onAction: () => {
          }
        })
        Scroll() {
          Column() {
            SectionHeader({ label: Strings.text(MessageKeys.SETTINGS_LANGUAGE), dark: model.dark })
            ChoiceRow({
              label: Strings.text(MessageKeys.SETTINGS_LANGUAGE_SYSTEM),
              selected: model.settings.language === Language.System,
              dark: model.dark,
              onSelect: () => {
                model.setLanguage(Language.System);
              }
            })
            ChoiceRow({
              label: Strings.text(MessageKeys.LANGUAGE_ZH),
              selected: model.settings.language === Language.Chinese,
              dark: model.dark,
              hairline: true,
              onSelect: () => {
                model.setLanguage(Language.Chinese);
              }
            })
            ChoiceRow({
              label: Strings.text(MessageKeys.LANGUAGE_EN),
              selected: model.settings.language === Language.English,
              dark: model.dark,
              onSelect: () => {
                model.setLanguage(Language.English);
              }
            })
            SectionHeader({ label: Strings.text(MessageKeys.SETTINGS_APPEARANCE), dark: model.dark })
            ChoiceRow({
              label: Strings.text(MessageKeys.SETTINGS_APPEARANCE_SYSTEM),
              selected: model.settings.appearance === Appearance.System,
              dark: model.dark,
              onSelect: () => {
                model.setAppearance(Appearance.System);
              }
            })
            ChoiceRow({
              label: Strings.text(MessageKeys.SETTINGS_APPEARANCE_LIGHT),
              selected: model.settings.appearance === Appearance.Light,
              dark: model.dark,
              hairline: true,
              onSelect: () => {
                model.setAppearance(Appearance.Light);
              }
            })
            ChoiceRow({
              label: Strings.text(MessageKeys.SETTINGS_APPEARANCE_DARK),
              selected: model.settings.appearance === Appearance.Dark,
              dark: model.dark,
              onSelect: () => {
                model.setAppearance(Appearance.Dark);
              }
            })
            SectionHeader({ label: Strings.text(MessageKeys.SETTINGS_IDENTITIES), dark: model.dark })
            if (model.identities.length === 0) {
              DetailRow({ label: Strings.text(MessageKeys.SETTINGS_NO_IDENTITIES), value: '', dark: model.dark })
            }
            ForEach(model.identities, (identity: Identity) => {
              this.IdentityCard(identity)
            }, (identity: Identity) => identity.origin)
            SectionHeader({ label: Strings.text(MessageKeys.SETTINGS_UPDATES), dark: model.dark })
            ChoiceRow({
              label: model.checkingUpdate ? Strings.text(MessageKeys.SETTINGS_UPDATES_CHECKING)
                : Strings.text(MessageKeys.SETTINGS_UPDATES),
              selected: false,
              dark: model.dark,
              onSelect: () => {
                model.checkUpdate();
              }
            })
            DetailRow({ label: '', value: this.updateLine(), dark: model.dark })
            SectionHeader({ label: Strings.text(MessageKeys.SETTINGS_ABOUT), dark: model.dark })
            DetailRow({
              label: '',
              value: Strings.text2(MessageKeys.SETTINGS_UPDATES_CURRENT, model.version(), `${model.build()}`),
              dark: model.dark
            })
            DetailRow({
              label: '',
              value: Strings.text1(MessageKeys.SETTINGS_PROTOCOL_VERSION, `${model.protocolVersion()}`),
              dark: model.dark
            })
            DetailRow({
              label: Strings.text(MessageKeys.SETTINGS_DEVICE_NAME),
              value: model.deviceName,
              dark: model.dark
            })
            Blank().height(Metrics.gapXL)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(palette(model.dark).bg)
    }
    .hideTitleBar(true)
    .backgroundColor(palette(model.dark).bg)
  }

  private updateLine(): string {
    if (model.update === null) {
      return Strings.text2(MessageKeys.SETTINGS_UPDATES_CURRENT, model.version(), `${model.build()}`);
    }
    if (model.update.verdict === UpdateVerdict.ProtocolChanged) {
      return Strings.text(MessageKeys.SETTINGS_UPDATES_PROTOCOL);
    }
    if (model.update.verdict === UpdateVerdict.Available) {
      return Strings.text2(MessageKeys.SETTINGS_UPDATES_AVAILABLE, model.update.versionName,
        `${model.update.buildNumber}`) + ' ' + Strings.text(MessageKeys.SETTINGS_UPDATES_STORE_HINT);
    }
    if (model.update.verdict === UpdateVerdict.Unreachable) {
      return Strings.text(MessageKeys.SETTINGS_UPDATES_FAILED);
    }
    return Strings.text(MessageKeys.SETTINGS_UPDATES_NONE);
  }

  @Builder
  IdentityCard(identity: Identity) {
    Column({ space: 2 }) {
      Text(identity.origin)
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(identity.deviceName)
        .fontSize(TypeScale.caption)
        .fontColor(palette(model.dark).textSecondary)
        .width('100%')
      DetailRow({
        label: Strings.text(MessageKeys.SETTINGS_NODES_COUNT),
        value: `${model.nodesForOrigin(identity.origin)}`,
        dark: model.dark
      })
      DetailRow({
        label: Strings.text(MessageKeys.SETTINGS_CERTIFICATE_FINGERPRINT),
        value: groupFingerprint(identity.certFingerprint),
        dark: model.dark,
        mono: true,
        multiline: true
      })
      Text(Strings.text(MessageKeys.SETTINGS_FORGET))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).danger)
        .padding({ top: Metrics.gapS, bottom: Metrics.gapS })
        .onClick(() => {
          this.confirmForget(identity);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin, top: Metrics.gapS, bottom: Metrics.gapM })
    .border({ width: { bottom: Metrics.hairline }, color: palette(model.dark).hairline })
  }

  /** Forgetting says what it costs before it costs it (ui-contract §2/S5). */
  private confirmForget(identity: Identity): void {
    const count: string = `${model.nodesForOrigin(identity.origin)}`;
    const options: AlertDialogParamWithButtons = {
      title: identity.origin,
      message: `${Strings.text(MessageKeys.SETTINGS_FORGET)}
` +
        Strings.text1(MessageKeys.SETTINGS_FORGET_CONFIRM, count),
      primaryButton: {
        value: Strings.text(MessageKeys.ACTION_CANCEL),
        fontColor: palette(model.dark).textSecondary,
        action: () => {
        }
      },
      secondaryButton: {
        value: Strings.text(MessageKeys.SETTINGS_FORGET),
        fontColor: palette(model.dark).danger,
        action: () => {
          model.removeIdentity(identity.origin);
        }
      }
    };
    try {
      this.getUIContext().showAlertDialog(options);
    } catch (error) {
      // A dialog that could not be shown forgot nothing, which is the safe outcome.
    }
  }
}

/** A fingerprint is shown in groups of eight, the way the gateway side shows it. */
export function groupFingerprint(fingerprint: string): string {
  let grouped: string = '';
  for (let index: number = 0; index < fingerprint.length; index += 8) {
    if (grouped !== '') {
      grouped += ' ';
    }
    grouped += fingerprint.substring(index, index + 8);
  }
  return grouped;
}
