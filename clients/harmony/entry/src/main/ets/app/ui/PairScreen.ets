// S2: scan or paste an invitation, inspect what it says, pair.

import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { scanBarcode } from '@kit.ScanKit';
import { MessageKeys } from '../../core/model/MessageKeys';
import { model, PairingStage } from '../AppModel';
import { defaultDeviceName, Strings } from '../i18n/Strings';
import { Metrics, TypeScale, withAlpha, tileAlpha } from '../theme/Tokens';
import { DetailRow, Header, SCREEN_FADE, palette } from './Components';
import { PairingState } from '../State';

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
          actionIcon0: $r('sys.symbol.chevron_left'),
          onAction0: () => {
            model.goBack();
          }
        })
        if (model.pairing.stage === PairingStage.Input) {
          this.InputStage()
        } else if (model.pairing.stage === PairingStage.Confirm) {
          this.ConfirmStage()
        } else if (model.pairing.stage === PairingStage.WaitingApproval) {
          this.WaitingStage()
        } else {
          this.WorkingStage()
        }
      }
      .width('100%')
      .transition(SCREEN_FADE)
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
      // A pasted invitation is a long line: the field shows a few lines of it and
      // scrolls, and a line that does not parse is said so as it is typed — the
      // moment it does parse, the screen moves on to confirming it.
      TextArea({ placeholder: Strings.text(MessageKeys.PAIR_INPUT_HINT), text: this.link })
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textPrimary)
        .backgroundColor(palette(model.dark).bgElevated)
        .borderRadius(Metrics.radiusControl)
        .height(96)
        .width('100%')
        .onChange((value: string) => {
          this.link = value;
          model.clearPairingError();
          if (value.trim().length > 0 && model.linkIsValid(value)) {
            model.submitLink(value);
          }
        })
      if (this.link.trim().length > 0 && !model.linkIsValid(this.link)) {
        Text(Strings.text(MessageKeys.PAIR_BAD_INVITATION))
          .fontSize(TypeScale.caption)
          .fontColor(palette(model.dark).danger)
          .width('100%')
      }
      if (model.pairing.errorKey !== null) {
        Text(Strings.text(model.pairing.errorKey))
          .fontSize(TypeScale.caption)
          .fontColor(palette(model.dark).danger)
          .width('100%')
      }
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
      if (model.pairing.errorKey !== null) {
        Text(Strings.text(model.pairing.errorKey))
          .fontSize(TypeScale.caption)
          .fontColor(palette(model.dark).danger)
          .width('100%')
      }
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
      if (this.workingNodeName() !== '') {
        Text(this.workingNodeName())
          .fontSize(TypeScale.caption)
          .fontColor(palette(model.dark).textTertiary)
      }
      Button(Strings.text(MessageKeys.ACTION_CANCEL))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textPrimary)
        .backgroundColor(palette(model.dark).bgElevated)
        .borderRadius(Metrics.radiusControl)
        .height(Metrics.rowSettings)
        .padding({ left: Metrics.gapL, right: Metrics.gapL })
        .margin({ top: Metrics.gapS })
        .onClick(() => {
          model.cancelPairing();
        })
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
        .fontSize(TypeScale.headline)
        .fontWeight(FontWeight.Medium)
        .fontColor(palette(model.dark).textPrimary)
        .textAlign(TextAlign.Center)
      if (this.workingNodeName() !== '') {
        Text(this.workingNodeName())
          .fontSize(TypeScale.body)
          .fontColor(palette(model.dark).textSecondary)
      }
      Button(Strings.text(MessageKeys.ACTION_RETRY))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).accentOnBg)
        .backgroundColor(palette(model.dark).accent)
        .borderRadius(Metrics.radiusControl)
        .height(Metrics.rowSettings)
        .padding({ left: Metrics.gapL, right: Metrics.gapL })
        .margin({ top: Metrics.gapS })
        .onClick(() => {
          model.retryStaged();
        })
      Text(Strings.text(MessageKeys.ACTION_BACK))
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).accent)
        .padding({ top: Metrics.gapS })
        .onClick(() => {
          model.backToList();
        })
    }
    .width('100%')
    .padding(Metrics.gapXL)
    .justifyContent(FlexAlign.Center)
  }

  /** The machine this pairing is working on or waiting for, if the state kept it. */
  private workingNodeName(): string {
    const pairing: PairingState = model.pairing;
    if (pairing.setup !== null) {
      return pairing.setup.nodeName;
    }
    return pairing.nodeName;
  }

  /**
   * Scanning uses the platform barcode kit. Runtime camera permission is requested
   * before scanning so the user is prompted; a denial is named for what it is. A
   * code that is not an invitation is refused here, with a word and no field
   * filled — it is not handed down as a puzzle for the confirm step.
   */
  private scan(): void {
    const context: common.UIAbilityContext | null = model.abilityContext();
    if (context === null) {
      return;
    }
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const permissions: Permissions[] = ['ohos.permission.CAMERA'];
    atManager.requestPermissionsFromUser(context, permissions)
      .then((data: PermissionRequestResult) => {
        let granted: boolean = false;
        for (let i: number = 0; i < data.authResults.length; i += 1) {
          if (data.authResults[i] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            granted = true;
            break;
          }
        }
        if (!granted) {
          model.showToast(MessageKeys.PAIR_SCAN_DENIED);
          return;
        }
        scanBarcode.startScanForResult(context)
          .then((result: scanBarcode.ScanResult) => {
            const code: string = result.originalValue === undefined ? '' : result.originalValue;
            if (code === '') {
              return;
            }
            if (!model.linkIsValid(code)) {
              model.showToast(MessageKeys.PAIR_SCAN_FAILED);
              return;
            }
            this.link = code;
            model.submitLink(code);
          })
          .catch((error: Object) => {
            model.showToast(MessageKeys.PAIR_SCAN_FAILED);
          });
      })
      .catch((error: Object) => {
        model.showToast(MessageKeys.PAIR_SCAN_DENIED);
      });
  }
}

/** PairScreen alias matching iOS/Android naming convention. */
@ComponentV2
export struct PairScreen {
  build() {
    AddNodeScreen()
  }
}
