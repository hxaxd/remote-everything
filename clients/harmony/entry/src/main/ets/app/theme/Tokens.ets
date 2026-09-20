// The visual tokens all three clients share, as values ArkUI can use.
//
// Nothing in the app picks a colour, a radius, a size or a gap that is not named
// here: three radii, five type steps, one spacing grid. Palettes are complete in both
// modes — dark mode is not a filter over light mode, it is the other column.

export class Palette {
  readonly bg: string;
  readonly bgElevated: string;
  readonly textPrimary: string;
  readonly textSecondary: string;
  readonly textTertiary: string;
  readonly hairline: string;
  readonly accent: string;
  readonly accentOnBg: string;
  readonly ok: string;
  readonly warn: string;
  readonly danger: string;
  readonly offline: string;

  constructor(bg: string, bgElevated: string, textPrimary: string, textSecondary: string, textTertiary: string,
    hairline: string, accent: string, accentOnBg: string, ok: string, warn: string, danger: string, offline: string) {
    this.bg = bg;
    this.bgElevated = bgElevated;
    this.textPrimary = textPrimary;
    this.textSecondary = textSecondary;
    this.textTertiary = textTertiary;
    this.hairline = hairline;
    this.accent = accent;
    this.accentOnBg = accentOnBg;
    this.ok = ok;
    this.warn = warn;
    this.danger = danger;
    this.offline = offline;
  }
}

export const LIGHT: Palette = new Palette(
  '#FAFAFA', '#FFFFFF', '#1A1A1A', '#6B6B6B', '#9C9C9C', '#E5E5E5',
  '#3B6EA5', '#FFFFFF', '#3D8B6D', '#B08A3E', '#B05454', '#9C9C9C');

export const DARK: Palette = new Palette(
  '#141414', '#1E1E1E', '#E8E8E8', '#A0A0A0', '#6E6E6E', '#2E2E2E',
  '#6E97C4', '#0F1B28', '#63A98B', '#C9A55C', '#C47A7A', '#6E6E6E');

/** The share of a colour that a badge or an icon tile is filled with. */
export function tileAlpha(dark: boolean): number {
  return dark ? 0.20 : 0.12;
}

/** A colour with an alpha, as ArkUI's `#AARRGGBB` string. */
export function withAlpha(color: string, alpha: number): string {
  const value: number = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
  const hex: string = value < 16 ? `0${value.toString(16)}` : value.toString(16);
  return `#${hex.toUpperCase()}${color.startsWith('#') ? color.substring(1) : color}`;
}

/**
 * The type scale: size and line height, per style.md §3.
 *
 * Every size grows with the screen: a phone reads these at one times, a tablet at up
 * to one and a half, so the words and the rows they sit in keep the same share of
 * the screen instead of shrinking into a corner of it. `applyScale` is applied before
 * the first frame (from the window measure) and whenever the window size changes.
 */
export class TypeScale {
  private static readonly BASE_TITLE: number = 20;
  private static readonly BASE_HEADLINE: number = 17;
  private static readonly BASE_BODY: number = 15;
  private static readonly BASE_CAPTION: number = 13;
  private static readonly BASE_FOOTNOTE: number = 12;

  static title: number = TypeScale.BASE_TITLE;
  static headline: number = TypeScale.BASE_HEADLINE;
  static body: number = TypeScale.BASE_BODY;
  static caption: number = TypeScale.BASE_CAPTION;
  static footnote: number = TypeScale.BASE_FOOTNOTE;

  /** One times on a phone-sized short side, up to 1.25 on a tablet. */
  static uiScale(shortSideVp: number): number {
    if (shortSideVp <= 0) {
      return 1;
    }
    const factor: number = shortSideVp / 420;
    return Math.max(1, Math.min(1.25, factor));
  }

  static applyScale(factor: number): void {
    TypeScale.title = Math.round(TypeScale.BASE_TITLE * factor);
    TypeScale.headline = Math.round(TypeScale.BASE_HEADLINE * factor);
    TypeScale.body = Math.round(TypeScale.BASE_BODY * factor);
    // The small words grow less than the big ones, so a status line keeps a
    // status line's proportions instead of becoming a headline on a big screen.
    const quiet: number = 1 + (factor - 1) * 0.6;
    TypeScale.caption = Math.round(TypeScale.BASE_CAPTION * quiet);
    TypeScale.footnote = Math.round(TypeScale.BASE_FOOTNOTE * quiet);
  }

  static line(size: number): number {
    return Math.round(size * 1.4);
  }
}

/** The three radii, the spacing grid and the row heights — all scaled with the type
 * they sit beside, so a tablet gets bigger rows and not just bigger words. */
export class Metrics {
  private static readonly BASE_RADIUS_CARD: number = 14;
  private static readonly BASE_RADIUS_CONTROL: number = 10;
  private static readonly BASE_RADIUS_ICON: number = 12;
  private static readonly BASE_GAP_S: number = 8;
  private static readonly BASE_GAP_M: number = 16;
  private static readonly BASE_GAP_L: number = 24;
  private static readonly BASE_GAP_XL: number = 32;
  private static readonly BASE_PAGE_MARGIN: number = 16;
  private static readonly BASE_ROW_NODE: number = 64;
  private static readonly BASE_ROW_APP: number = 72;
  private static readonly BASE_ROW_SETTINGS: number = 52;
  private static readonly BASE_ICON_TILE: number = 40;
  private static readonly BASE_ICON_TILE_SMALL: number = 28;

  static radiusCard: number = Metrics.BASE_RADIUS_CARD;
  static radiusControl: number = Metrics.BASE_RADIUS_CONTROL;
  static radiusPill: number = 100;
  static radiusIcon: number = Metrics.BASE_RADIUS_ICON;

  static gapS: number = Metrics.BASE_GAP_S;
  static gapM: number = Metrics.BASE_GAP_M;
  static gapL: number = Metrics.BASE_GAP_L;
  static gapXL: number = Metrics.BASE_GAP_XL;

  static pageMargin: number = Metrics.BASE_PAGE_MARGIN;
  static contentMaxWidth: number = 720;

  static rowNode: number = Metrics.BASE_ROW_NODE;
  static rowApp: number = Metrics.BASE_ROW_APP;
  static rowSettings: number = Metrics.BASE_ROW_SETTINGS;

  static hairline: number = 0.5;
  static iconTile: number = Metrics.BASE_ICON_TILE;
  static iconTileSmall: number = Metrics.BASE_ICON_TILE_SMALL;

  static applyScale(factor: number): void {
    const grown: (base: number) => number = (base: number): number => Math.round(base * factor);
    Metrics.radiusCard = grown(Metrics.BASE_RADIUS_CARD);
    Metrics.radiusControl = grown(Metrics.BASE_RADIUS_CONTROL);
    Metrics.radiusIcon = grown(Metrics.BASE_RADIUS_ICON);
    Metrics.gapS = grown(Metrics.BASE_GAP_S);
    Metrics.gapM = grown(Metrics.BASE_GAP_M);
    Metrics.gapL = grown(Metrics.BASE_GAP_L);
    Metrics.gapXL = grown(Metrics.BASE_GAP_XL);
    Metrics.pageMargin = grown(Metrics.BASE_PAGE_MARGIN);
    Metrics.rowNode = grown(Metrics.BASE_ROW_NODE);
    Metrics.rowApp = grown(Metrics.BASE_ROW_APP);
    Metrics.rowSettings = grown(Metrics.BASE_ROW_SETTINGS);
    Metrics.iconTile = grown(Metrics.BASE_ICON_TILE);
    Metrics.iconTileSmall = grown(Metrics.BASE_ICON_TILE_SMALL);
  }

  /** The one shadow in the app, and only on overlays. */
  static readonly overlayShadow: ShadowOptions = { radius: 24, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 8 };
  static readonly overlayShadowDark: ShadowOptions = { radius: 24, color: 'rgba(0,0,0,0.32)', offsetX: 0, offsetY: 8 };
}

/** Fingerprints and other tabular text: the system's monospace, so digits line up. */
export const MONO_FAMILY: string = 'monospace';
