// S2: scan or paste an invitation, inspect what it says, pair.

import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { scanBarcode } from '@kit.ScanKit';
import { MessageKeys } from '../../core/model/MessageKeys';
import { PairingStage } from '../../core/pairing/PairingMachine';
import { model } from '../AppModel';
import { defaultDeviceName, Strings } from '../i18n/Strings';
import { Metrics, TypeScale, withAlpha, tileAlpha } from '../theme/Tokens';
import { DetailRow, Header, palette } from './Components';

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

  /**
   * Scanning uses the platform barcode kit.
   * Runtime camera permission is requested before scanning so the user is prompted.
   */
  private scan(): void {
    const context: common.UIAbilityContext | null = model.abilityContext();
    if (context === null) {
      return;
    }
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const permissions: Permissions[] = ['ohos.permission.CAMERA'];
    atManager.requestPermissionsFromUser(context, permissions)
      .then((data: abilityAccessCtrl.PermissionRequestResult) => {
        let granted: boolean = false;
        for (let i: number = 0; i < data.authResults.length; i += 1) {
          if (data.authResults[i] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            granted = true;
            break;
          }
        }
        if (!granted) {
          model.showToast(MessageKeys.PAIR_SCAN_FAILED);
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
      })
      .catch((error: Object) => {
        model.showToast(MessageKeys.PAIR_SCAN_FAILED);
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
