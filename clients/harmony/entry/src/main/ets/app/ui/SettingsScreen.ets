// S5: display, the gateways this device holds, and what this build is.

import { Appearance, Identity, Language } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';
import { UpdateVerdict } from '../../core/update/UpdateChecker';
import { model } from '../AppModel';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale } from '../theme/Tokens';
import { ChoiceRow, DetailRow, Header, SectionHeader, palette } from './Components';

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
      message: `${Strings.text(MessageKeys.SETTINGS_FORGET)}\n` +
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
