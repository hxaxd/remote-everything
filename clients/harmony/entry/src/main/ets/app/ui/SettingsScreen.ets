// S5: display, the gateways this device holds, and what this build is.

import { Appearance, Identity, Language } from '../../core/model/Models';
import { pasteboard } from '@kit.BasicServicesKit';
import { MessageKeys } from '../../core/model/MessageKeys';
import { LinkTrouble, linkKindKey } from '../../core/diag/LinkReport';
import { UpdateVerdict } from '../../core/update/UpdateChecker';
import { model } from '../AppModel';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale } from '../theme/Tokens';
import { ChoiceRow, DetailRow, Header, SectionHeader, SCREEN_FADE, palette } from './Components';

/** S5: display, the gateways this device holds, and what this build is. */
@ComponentV2
export struct SettingsScreen {
  build() {
    NavDestination() {
      Column() {
        Header({
          title: Strings.text(MessageKeys.SETTINGS_TITLE),
          dark: model.dark,
          actionIcon0: $r('sys.symbol.chevron_left'),
          onAction0: () => {
            model.goBack();
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
                .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin })
            }
            ForEach(model.identities, (identity: Identity) => {
              this.IdentityCard(identity)
            }, (identity: Identity) =>
              // The key carries whether the trouble line is showing: the card is a
              // by-value builder, so only a rebuild picks up that line appearing.
              `${identity.origin}|${model.troubleFor(identity.origin) !== null ? 1 : 0}`)
            SectionHeader({ label: Strings.text(MessageKeys.SETTINGS_ABOUT), dark: model.dark })
            // Three plain rows, the way a page about the build reads: what this app is,
            // what it speaks, and what this phone calls itself. Nothing is boxed, because
            // none of it is a list — and the version number is the update check, without
            // a button saying so.
            this.VersionRowView()
            this.AboutRowView(
              Strings.text(MessageKeys.SETTINGS_PROTOCOL_VERSION),
              `${model.protocolVersion()}`,
              null
            )
            this.AboutRowView(
              Strings.text(MessageKeys.SETTINGS_DEVICE_NAME),
              model.deviceName,
              () => {
                this.copy(model.deviceName);
              }
            )
            Blank().height(Metrics.gapXL)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        // Content shorter than the screen reads from the top, where a page of
        // settings lives — not floating in the middle of the viewport.
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .transition(SCREEN_FADE)
      .height('100%')
      .backgroundColor(palette(model.dark).bg)
    }
    .hideTitleBar(true)
    .backgroundColor(palette(model.dark).bg)
  }


  /**
   * One connection: what it is, what it is called, and the way to forget it — the
   * two things a person reads on the left, stacked and the same size, and the one
   * thing a person must not hit by accident at the far right. The card is its own
   * surface with room around it, so two connections never read as one list.
   *
   * A connection that is not answering says so on a line below, with the one thing
   * a person can do about it: copy the report. Both controls have their room
   * planned and their words yield with an ellipsis, so neither can push the address
   * — the thing the reader came to read — off the card.
   */
  @Builder
  IdentityCard(identity: Identity) {
    // The inset is the wrapper's padding, not the card's margin: a card that is
    // 100% of its parent PLUS margins is wider than the screen by exactly those
    // margins, and its right side goes past the glass.
    Column() {
      Column() {
        Row({ space: Metrics.gapS }) {
          Column({ space: 2 }) {
            // A copyable line answers on its own footprint — the words, not the
            // whole window they happen to sit in.
            Text(identity.origin)
              .fontSize(TypeScale.body)
              .fontColor(palette(model.dark).textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => {
                this.copy(identity.origin);
              })
            Text(identity.deviceName)
              .fontSize(TypeScale.body)
              .fontColor(palette(model.dark).textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => {
                this.copy(identity.deviceName);
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          // Natural width, the way a text button reads: the words and their
          // padding, never folded by a cap — a forget control that says only
          // "忘记…" is a control a person cannot trust.
          Text(Strings.text(MessageKeys.SETTINGS_FORGET))
            .fontSize(TypeScale.body)
            .fontColor(palette(model.dark).danger)
            .maxLines(1)
            .padding({ left: Metrics.gapS, right: Metrics.gapS, top: Metrics.gapS, bottom: Metrics.gapS })
            .onClick(() => {
              this.confirmForget(identity);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (model.troubleFor(identity.origin) !== null) {
          Row({ space: Metrics.gapS }) {
            Text(this.troubleReason(identity))
              .fontSize(TypeScale.caption)
              .fontColor(palette(model.dark).danger)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(Strings.text(MessageKeys.SETTINGS_COPY_ERROR))
              .fontSize(TypeScale.caption)
              .fontColor(palette(model.dark).accentOnBg)
              .maxLines(1)
              .padding({ left: Metrics.gapS, right: Metrics.gapS, top: 2, bottom: 2 })
              .onClick(() => {
                this.copyReport(identity);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 2, right: Metrics.gapS })
        }
      }
      .width('100%')
      .padding({ left: Metrics.gapM, right: Metrics.gapS, top: Metrics.gapS, bottom: Metrics.gapS })
      .backgroundColor(palette(model.dark).bgElevated)
      .borderRadius(Metrics.radiusCard)
      .border({ width: 1, color: palette(model.dark).hairline })
    }
    .width('100%')
    .padding({ left: Metrics.gapM, right: Metrics.gapM, top: Metrics.gapS, bottom: Metrics.gapS })
  }

  /** The reason this connection is not answering, in the words this app shows. */
  private troubleReason(identity: Identity): string {
    const trouble: LinkTrouble | null = model.troubleFor(identity.origin);
    return trouble === null ? '' : Strings.text(linkKindKey(trouble.kind));
  }

  /** Copying the report is the whole point of the report existing. */
  private copyReport(identity: Identity): void {
    const report: string = model.troubleReport(identity);
    if (report.length === 0) {
      return;
    }
    this.copy(report);
  }

  /**
   * Copying is what a person does with an address or a name. The clipboard says
   * nothing about whether it took, so this screen says so — and a clipboard that
   * refused kept nothing, which needs no second sentence.
   */
  private copy(value: string): void {
    if (value.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
      pasteboard.getSystemPasteboard().setDataSync(data);
      model.showBriefToast(MessageKeys.ACTION_COPIED);
    } catch (error) {
      // Nothing was copied and nothing was lost: the screen stays as it was.
    }
  }

  /**
   * The version line of "about this build", which is also the update check.
   *
   * Short outcomes ("checking…", "up to date") live on the same line between the
   * label and the version without shifting the rows beneath it. An available update
   * highlights the new version on the right, and detailed store instructions only
   * appear below when there is an update to act on.
   */
  @Builder
  VersionRowView() {
    Column() {
      Row({ space: Metrics.gapM }) {
        Text(Strings.text(MessageKeys.SETTINGS_VERSION))
          .fontSize(TypeScale.body)
          .fontColor(palette(model.dark).textPrimary)
        Text(this.versionValueText())
          .fontSize(TypeScale.caption)
          .fontColor(this.versionValueColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.versionDetailText() !== '') {
        Text(this.versionDetailText())
          .fontSize(TypeScale.caption)
          .fontColor(this.versionDetailColor())
          .width('100%')
          .padding({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin, top: Metrics.gapS, bottom: Metrics.gapS })
    .onClick(() => {
      model.checkUpdate();
    })
  }

  private versionValueText(): string {
    const currentVersion: string = `${model.version()} (${model.build()})`;
    if (model.checkingUpdate) {
      return `${Strings.text(MessageKeys.SETTINGS_UPDATES_CHECKING)} · ${currentVersion}`;
    }
    if (model.update === null) {
      return currentVersion;
    }
    if (model.update.verdict === UpdateVerdict.UpToDate) {
      return `${Strings.text(MessageKeys.SETTINGS_UPDATES_NONE)} · ${currentVersion}`;
    }
    if (model.update.verdict === UpdateVerdict.Available) {
      return Strings.text2(
        MessageKeys.SETTINGS_UPDATES_AVAILABLE,
        model.update.versionName,
        `${model.update.buildNumber}`
      );
    }
    return currentVersion;
  }

  private versionValueColor(): string {
    if (!model.checkingUpdate && model.update !== null) {
      if (model.update.verdict === UpdateVerdict.Available) {
        return palette(model.dark).accent;
      }
      if (model.update.verdict === UpdateVerdict.ProtocolChanged) {
        return palette(model.dark).danger;
      }
    }
    return palette(model.dark).textSecondary;
  }

  private versionDetailText(): string {
    if (model.checkingUpdate || model.update === null) {
      return '';
    }
    if (model.update.verdict === UpdateVerdict.Available) {
      return Strings.text(MessageKeys.SETTINGS_UPDATES_STORE_HINT);
    }
    if (model.update.verdict === UpdateVerdict.ProtocolChanged) {
      return `${Strings.text(MessageKeys.SETTINGS_UPDATES_PROTOCOL)} ${Strings.text(MessageKeys.SETTINGS_UPDATES_STORE_HINT)}`;
    }
    if (model.update.verdict === UpdateVerdict.Unreachable) {
      return Strings.text(MessageKeys.SETTINGS_UPDATES_FAILED);
    }
    return '';
  }

  private versionDetailColor(): string {
    if (model.update !== null) {
      if (model.update.verdict === UpdateVerdict.ProtocolChanged ||
          model.update.verdict === UpdateVerdict.Unreachable) {
        return palette(model.dark).danger;
      }
    }
    return palette(model.dark).textSecondary;
  }

  /**
   * One line of "about this build": what it is on the left, what it is on the right,
   * and — where there is something a person can do with the value — the whole row is
   * what they tap. No button, because the value is the thing.
   */
  @Builder
  AboutRowView(label: string, value: string, onValue: (() => void) | null) {
    Row({ space: Metrics.gapM }) {
      Text(label)
        .fontSize(TypeScale.body)
        .fontColor(palette(model.dark).textPrimary)
      Text(value)
        .fontSize(TypeScale.caption)
        .fontColor(palette(model.dark).textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin, top: Metrics.gapS, bottom: Metrics.gapS })
    .onClick(() => {
      if (onValue !== null && value.length > 0) {
        onValue();
      }
    })
  }

  /** Forgetting asks before it forgets (ui-contract §2/S5). */
  private confirmForget(identity: Identity): void {
    const options: AlertDialogParamWithButtons = {
      title: identity.origin,
      message: `${Strings.text(MessageKeys.SETTINGS_FORGET)}\n` +
        // A question, not a promise: another connection may reach the same
        // machines, so "they will become unreachable" is a claim this screen
        // cannot make.
        Strings.text(MessageKeys.SETTINGS_FORGET_CONFIRM),
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
