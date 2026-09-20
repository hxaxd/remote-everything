// What the web host remembers for one application, keyed by `nodeId/appId`: the two
// choices on that application's panel, kept across visits.
//
// The values are this client's own words, written by it and read by it, so they are
// stored plainly (one preferences entry per application) rather than as a document:
// there is no second writer whose shape would have to be validated.

/** How one application's web host holds the screen. */
export enum WebOrientation {
  System = 'system',
  Portrait = 'portrait',
  Landscape = 'landscape',
}

/** Which user agent one application's web host introduces itself with. */
export enum WebUserAgent {
  Mobile = 'mobile',
  Desktop = 'desktop',
}

/**
 * What the web host remembers for one application. Defaults are what an application
 * gets until its panel is touched — the system decides the orientation, and the page
 * sees the mobile user agent.
 */
export class WebAppPrefs {
  readonly orientation: WebOrientation;
  readonly userAgent: WebUserAgent;

  constructor(orientation: WebOrientation, userAgent: WebUserAgent) {
    this.orientation = orientation;
    this.userAgent = userAgent;
  }

  static defaults(): WebAppPrefs {
    return new WebAppPrefs(WebOrientation.System, WebUserAgent.Mobile);
  }

  withOrientation(orientation: WebOrientation): WebAppPrefs {
    return new WebAppPrefs(orientation, this.userAgent);
  }

  withUserAgent(userAgent: WebUserAgent): WebAppPrefs {
    return new WebAppPrefs(this.orientation, userAgent);
  }

  /** The orientations a panel offers, in the order it offers them. */
  static orientationValues(): string[] {
    return [WebOrientation.System, WebOrientation.Portrait, WebOrientation.Landscape];
  }

  /** The identities a panel offers, in the order it offers them. */
  static userAgentValues(): string[] {
    return [WebUserAgent.Mobile, WebUserAgent.Desktop];
  }

  /** The stored form: two of this client's own words, and nothing else. */
  encode(): string {
    return `${this.orientation}|${this.userAgent}`;
  }

  /** A stored form this client does not recognise is not acted on. */
  static decode(value: string): WebAppPrefs {
    const parts: string[] = value.split('|');
    if (parts.length !== 2) {
      return WebAppPrefs.defaults();
    }
    return new WebAppPrefs(WebAppPrefs.readOrientation(parts[0]), WebAppPrefs.readUserAgent(parts[1]));
  }

  static readOrientation(value: string): WebOrientation {
    if (value === WebOrientation.Portrait) {
      return WebOrientation.Portrait;
    }
    if (value === WebOrientation.Landscape) {
      return WebOrientation.Landscape;
    }
    return WebOrientation.System;
  }

  static readUserAgent(value: string): WebUserAgent {
    return value === WebUserAgent.Desktop ? WebUserAgent.Desktop : WebUserAgent.Mobile;
  }
}
