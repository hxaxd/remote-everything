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

/** The type scale: size and line height, per style.md §3. */
export class TypeScale {
  static readonly title: number = 20;
  static readonly headline: number = 17;
  static readonly body: number = 15;
  static readonly caption: number = 13;
  static readonly footnote: number = 12;

  static line(size: number): number {
    return Math.round(size * 1.4);
  }
}

/** The three radii, the spacing grid and the row heights. */
export class Metrics {
  static readonly radiusCard: number = 14;
  static readonly radiusControl: number = 10;
  static readonly radiusPill: number = 100;
  static readonly radiusIcon: number = 12;

  static readonly gapS: number = 8;
  static readonly gapM: number = 16;
  static readonly gapL: number = 24;
  static readonly gapXL: number = 32;

  static readonly pageMargin: number = 16;
  static readonly contentMaxWidth: number = 720;

  static readonly rowNode: number = 64;
  static readonly rowApp: number = 72;
  static readonly rowSettings: number = 52;

  static readonly hairline: number = 0.5;
  static readonly iconTile: number = 40;
  static readonly iconTileSmall: number = 28;

  /** The one shadow in the app, and only on overlays. */
  static readonly overlayShadow: ShadowOptions = { radius: 24, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 8 };
  static readonly overlayShadowDark: ShadowOptions = { radius: 24, color: 'rgba(0,0,0,0.32)', offsetX: 0, offsetY: 8 };
}

/** Fingerprints and other tabular text: the system's monospace, so digits line up. */
export const MONO_FAMILY: string = 'monospace';
