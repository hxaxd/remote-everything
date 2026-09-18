// Reusable UI components and style helpers for HarmonyOS screens.

import { Palette, LIGHT, DARK, Metrics, TypeScale, withAlpha, tileAlpha, MONO_FAMILY } from '../theme/Tokens';
import { AppState, NodeStatus } from '../../core/model/Models';

export function palette(dark: boolean): Palette {
  return dark ? DARK : LIGHT;
}

/** The colour a node's state is written in: the path colour when it is up, grey when
 * it is not — offline and stopped are never red (style.md §2). */
export function nodeTone(status: NodeStatus, dark: boolean): string {
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

export function appTone(state: AppState, dark: boolean): string {
  const colors = palette(dark);
  if (state === AppState.Ready) {
    return colors.ok;
  }
  if (state === AppState.Starting || state === AppState.Stopping) {
    return colors.warn;
  }
  return colors.offline;
}

/** A page header: a title, the path a node is reached by, and up to two actions. */
@ComponentV2
export struct Header {
  @Param title: string = '';
  @Param dark: boolean = false;
  @Param pathLabel: string = '';
  @Param pathColor: string = '';
  @Param actionLabel: string = '';
  @Param actionLabel2: string = '';
  @Event onAction: () => void = () => {
  };
  @Event onAction2: () => void = () => {
  };

  build() {
    Row({ space: Metrics.gapS }) {
      Text(this.title)
        .fontSize(TypeScale.title)
        .fontWeight(FontWeight.Medium)
        .fontColor(palette(this.dark).textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.pathLabel !== '') {
        StateBadge({ label: this.pathLabel, color: this.pathColor, dark: this.dark })
      }
      Blank()
      if (this.actionLabel2 !== '') {
        Text(this.actionLabel2)
          .fontSize(TypeScale.headline)
          .fontColor(palette(this.dark).textSecondary)
          .padding({ left: Metrics.gapS, right: Metrics.gapS })
          .onClick(() => {
            this.onAction2();
          })
      }
      if (this.actionLabel !== '') {
        Text(this.actionLabel)
          .fontSize(TypeScale.headline)
          .fontWeight(FontWeight.Medium)
          .fontColor(palette(this.dark).accent)
          .padding({ left: Metrics.gapS, right: Metrics.gapS })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .height(Metrics.rowSettings)
    .alignItems(VerticalAlign.Center)
    .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin })
  }
}

/** A status badge: the words in the semantic colour, the background a wash of it. */
@ComponentV2
export struct StateBadge {
  @Param label: string = '';
  @Param color: string = '';
  @Param dark: boolean = false;

  build() {
    Text(this.label)
      .fontSize(TypeScale.caption)
      .fontColor(this.color)
      .padding({ left: Metrics.gapS, right: Metrics.gapS, top: 3, bottom: 3 })
      .backgroundColor(withAlpha(this.color, tileAlpha(this.dark)))
      .borderRadius(Metrics.radiusPill)
      .maxLines(1)
  }
}

/** An application's icon: its emoji on a wash of its own accent colour. */
@ComponentV2
export struct IconTile {
  @Param icon: string = '';
  @Param accent: string = '#3B6EA5';
  @Param dark: boolean = false;
  @Param small: boolean = false;

  build() {
    Text(this.icon === '' ? '📦' : this.icon)
      .fontSize(this.small ? TypeScale.body : TypeScale.headline)
      .textAlign(TextAlign.Center)
      .width(this.small ? Metrics.iconTileSmall : Metrics.iconTile)
      .height(this.small ? Metrics.iconTileSmall : Metrics.iconTile)
      .backgroundColor(withAlpha(this.accent, tileAlpha(this.dark)))
      .borderRadius(Metrics.radiusIcon)
  }
}

/** The empty state: a line about now, a line about what to do, one way to do it. */
@ComponentV2
export struct EmptyState {
  @Param title: string = '';
  @Param body: string = '';
  @Param actionLabel: string = '';
  @Param dark: boolean = false;
  @Event onAction: () => void = () => {
  };

  build() {
    Column({ space: Metrics.gapM }) {
      Text('📦')
        .fontSize(40)
        .textAlign(TextAlign.Center)
        .width(72)
        .height(72)
        .backgroundColor(withAlpha(palette(this.dark).accent, tileAlpha(this.dark)))
        .borderRadius(Metrics.radiusCard)
      Text(this.title)
        .fontSize(TypeScale.headline)
        .fontWeight(FontWeight.Medium)
        .fontColor(palette(this.dark).textPrimary)
        .textAlign(TextAlign.Center)
      Text(this.body)
        .fontSize(TypeScale.body)
        .fontColor(palette(this.dark).textSecondary)
        .textAlign(TextAlign.Center)
        .lineHeight(TypeScale.line(TypeScale.body))
      if (this.actionLabel !== '') {
        Button(this.actionLabel)
          .fontSize(TypeScale.body)
          .fontColor(palette(this.dark).accentOnBg)
          .backgroundColor(palette(this.dark).accent)
          .borderRadius(Metrics.radiusControl)
          .height(Metrics.rowSettings)
          .padding({ left: Metrics.gapL, right: Metrics.gapL })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding(Metrics.gapXL)
    .justifyContent(FlexAlign.Center)
  }
}

/** A full-width explanation with one way out: the offline and unauthorized pages. */
@ComponentV2
export struct Notice {
  @Param title: string = '';
  @Param body: string = '';
  @Param actionLabel: string = '';
  @Param dark: boolean = false;
  @Param tone: string = '';
  @Event onAction: () => void = () => {
  };

  build() {
    Column({ space: Metrics.gapS }) {
      Text(this.title)
        .fontSize(TypeScale.headline)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.tone === '' ? palette(this.dark).textPrimary : this.tone)
        .textAlign(TextAlign.Center)
      if (this.body !== '') {
        Text(this.body)
          .fontSize(TypeScale.body)
          .fontColor(palette(this.dark).textSecondary)
          .textAlign(TextAlign.Center)
          .lineHeight(TypeScale.line(TypeScale.body))
      }
      if (this.actionLabel !== '') {
        Text(this.actionLabel)
          .fontSize(TypeScale.body)
          .fontColor(palette(this.dark).accent)
          .padding({ top: Metrics.gapS })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding(Metrics.gapXL)
    .justifyContent(FlexAlign.Center)
  }
}

/** One row of a settings group: a label, a value, and whether it is the chosen one. */
@ComponentV2
export struct ChoiceRow {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Param dark: boolean = false;
  @Event onSelect: () => void = () => {
  };
  @Param hairline: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(TypeScale.body)
        .fontColor(palette(this.dark).textPrimary)
        .layoutWeight(1)
      Text('✓')
        .fontSize(TypeScale.body)
        .fontColor(palette(this.dark).accent)
        .visibility(this.selected ? Visibility.Visible : Visibility.Hidden)
    }
    .width('100%')
    .height(Metrics.rowSettings)
    .alignItems(VerticalAlign.Center)
    .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin })
    .border({ width: { bottom: this.hairline ? Metrics.hairline : 0 }, color: palette(this.dark).hairline })
    .onClick(() => {
      this.onSelect();
    })
  }
}

/** A label and a value, for the settings that only report something. */
@ComponentV2
export struct DetailRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param dark: boolean = false;
  @Param mono: boolean = false;
  @Param multiline: boolean = false;

  build() {
    Column({ space: 2 }) {
      Text(this.label)
        .fontSize(TypeScale.caption)
        .fontColor(palette(this.dark).textSecondary)
      Text(this.value)
        .fontSize(this.mono ? TypeScale.footnote : TypeScale.body)
        .fontColor(palette(this.dark).textPrimary)
        .fontFamily(this.mono ? MONO_FAMILY : '')
        .maxLines(this.multiline ? 6 : 1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: Metrics.gapS, bottom: Metrics.gapS })
  }
}

/** A group heading: a quiet line above a group of rows. */
@ComponentV2
export struct SectionHeader {
  @Param label: string = '';
  @Param dark: boolean = false;

  build() {
    Text(this.label)
      .fontSize(TypeScale.caption)
      .fontColor(palette(this.dark).textSecondary)
      .padding({ left: Metrics.pageMargin, right: Metrics.pageMargin, top: Metrics.gapL, bottom: Metrics.gapS })
      .width('100%')
  }
}

/** A thin progress line. The loading indicator is never the pull gesture's spinner. */
@ComponentV2
export struct BusyLine {
  @Param visible: boolean = false;
  @Param dark: boolean = false;

  build() {
    Row() {
      if (this.visible) {
        Progress({ value: 30, total: 100, type: ProgressType.Linear })
          .color(palette(this.dark).accent)
          .width('100%')
          .height(2)
      }
    }
    .width('100%')
    .height(2)
  }
}
