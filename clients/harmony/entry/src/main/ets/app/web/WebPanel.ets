// The panel one application's back gesture opens: how the screen is held, how the
// page introduces itself, a refresh, and the way out. It replaces the bar that used
// to sit over the page — the screen belongs to the page now, and everything the bar
// carried (a reload and a close, and nothing else) is here, as two settings rows and
// two actions.

import { MessageKeys } from '../../core/model/MessageKeys';
import { WebAppPrefs, WebOrientation, WebUserAgent } from '../../core/store/WebAppPrefs';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale, tileAlpha, withAlpha } from '../theme/Tokens';
import { palette } from '../ui/Components';

@ComponentV2
export struct WebPanel {
  @Param prefs: WebAppPrefs = WebAppPrefs.defaults();
  @Param dark: boolean = false;
  @Event onOrientation: (orientation: WebOrientation) => void = () => {
  };
  @Event onUserAgent: (userAgent: WebUserAgent) => void = () => {
  };
  @Event onRefresh: () => void = () => {
  };
  @Event onExit: () => void = () => {
  };
  @Event onDismiss: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.onDismiss();
        })

      Column({ space: Metrics.gapM }) {
        Row({ space: Metrics.gapM }) {
          Text(Strings.text(MessageKeys.WEB_ORIENTATION))
            .fontSize(TypeScale.caption)
            .fontColor(palette(this.dark).textSecondary)
          Blank()
          Row({ space: 2 }) {
            // The chips read the preference directly, in this build — a @Builder
            // taking `chosen` by value never refreshes on a state change, which is
            // why a tap used to apply the choice but never move the highlight.
            Text(Strings.text(MessageKeys.WEB_ORIENTATION_SYSTEM))
              .fontSize(TypeScale.footnote)
              .fontColor(this.prefs.orientation === WebOrientation.System
                ? palette(this.dark).accent : palette(this.dark).textSecondary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.prefs.orientation === WebOrientation.System
                ? withAlpha(palette(this.dark).accent, tileAlpha(this.dark)) : '#00000000')
              .borderRadius(Metrics.radiusControl)
              .onClick(() => {
                if (this.prefs.orientation !== WebOrientation.System) {
                  this.onOrientation(WebOrientation.System);
                }
              })
            Text(Strings.text(MessageKeys.WEB_ORIENTATION_PORTRAIT))
              .fontSize(TypeScale.footnote)
              .fontColor(this.prefs.orientation === WebOrientation.Portrait
                ? palette(this.dark).accent : palette(this.dark).textSecondary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.prefs.orientation === WebOrientation.Portrait
                ? withAlpha(palette(this.dark).accent, tileAlpha(this.dark)) : '#00000000')
              .borderRadius(Metrics.radiusControl)
              .onClick(() => {
                if (this.prefs.orientation !== WebOrientation.Portrait) {
                  this.onOrientation(WebOrientation.Portrait);
                }
              })
            Text(Strings.text(MessageKeys.WEB_ORIENTATION_LANDSCAPE))
              .fontSize(TypeScale.footnote)
              .fontColor(this.prefs.orientation === WebOrientation.Landscape
                ? palette(this.dark).accent : palette(this.dark).textSecondary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.prefs.orientation === WebOrientation.Landscape
                ? withAlpha(palette(this.dark).accent, tileAlpha(this.dark)) : '#00000000')
              .borderRadius(Metrics.radiusControl)
              .onClick(() => {
                if (this.prefs.orientation !== WebOrientation.Landscape) {
                  this.onOrientation(WebOrientation.Landscape);
                }
              })
          }
          .padding(2)
          .backgroundColor(palette(this.dark).bg)
          .borderRadius(Metrics.radiusControl)
        }
        .width('100%')

        Row({ space: Metrics.gapM }) {
          Text(Strings.text(MessageKeys.WEB_USER_AGENT))
            .fontSize(TypeScale.caption)
            .fontColor(palette(this.dark).textSecondary)
          Blank()
          Row({ space: 2 }) {
            Text(Strings.text(MessageKeys.WEB_USER_AGENT_MOBILE))
              .fontSize(TypeScale.footnote)
              .fontColor(this.prefs.userAgent === WebUserAgent.Mobile
                ? palette(this.dark).accent : palette(this.dark).textSecondary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.prefs.userAgent === WebUserAgent.Mobile
                ? withAlpha(palette(this.dark).accent, tileAlpha(this.dark)) : '#00000000')
              .borderRadius(Metrics.radiusControl)
              .onClick(() => {
                if (this.prefs.userAgent !== WebUserAgent.Mobile) {
                  this.onUserAgent(WebUserAgent.Mobile);
                }
              })
            Text(Strings.text(MessageKeys.WEB_USER_AGENT_DESKTOP))
              .fontSize(TypeScale.footnote)
              .fontColor(this.prefs.userAgent === WebUserAgent.Desktop
                ? palette(this.dark).accent : palette(this.dark).textSecondary)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.prefs.userAgent === WebUserAgent.Desktop
                ? withAlpha(palette(this.dark).accent, tileAlpha(this.dark)) : '#00000000')
              .borderRadius(Metrics.radiusControl)
              .onClick(() => {
                if (this.prefs.userAgent !== WebUserAgent.Desktop) {
                  this.onUserAgent(WebUserAgent.Desktop);
                }
              })
          }
          .padding(2)
          .backgroundColor(palette(this.dark).bg)
          .borderRadius(Metrics.radiusControl)
        }
        .width('100%')

        Divider()
          .strokeWidth(Metrics.hairline)
          .color(palette(this.dark).hairline)
          .margin({ top: Metrics.gapS })

        Row({ space: Metrics.gapS }) {
          Text('⟳')
            .fontSize(TypeScale.headline)
            .fontColor(palette(this.dark).textPrimary)
            .width(28)
          Text(Strings.text(MessageKeys.WEB_REFRESH))
            .fontSize(TypeScale.headline)
            .fontColor(palette(this.dark).textPrimary)
        }
        .width('100%')
        .height(Metrics.rowSettings)
        .onClick(() => {
          this.onRefresh();
        })

        Row({ space: Metrics.gapS }) {
          Text('✕')
            .fontSize(TypeScale.headline)
            .fontColor(palette(this.dark).textPrimary)
            .width(28)
          Text(Strings.text(MessageKeys.WEB_EXIT))
            .fontSize(TypeScale.headline)
            .fontColor(palette(this.dark).textPrimary)
        }
        .width('100%')
        .height(Metrics.rowSettings)
        .onClick(() => {
          this.onExit();
        })
      }
      .alignItems(HorizontalAlign.Start)
      .padding(Metrics.gapM)
      .backgroundColor(palette(this.dark).bgElevated)
      .borderRadius(Metrics.radiusCard)
      .margin({ left: 10, right: 10, bottom: 10 })
    }
    .width('100%')
    .height('100%')
  }
}
