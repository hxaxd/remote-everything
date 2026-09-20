// Parsing and normalising gateway origins according to RFC 3986.

export const DEFAULT_TLS_PORT: number = 443;

function authorityOf(urlOrOrigin: string): string {
  const scheme: number = urlOrOrigin.indexOf('://');
  let authority: string = scheme < 0 ? urlOrOrigin : urlOrOrigin.substring(scheme + 3);
  const stop: number = firstIndexOf(authority, ['/', '?', '#']);
  if (stop >= 0) {
    authority = authority.substring(0, stop);
  }
  if (authority.includes('@')) {
    authority = authority.substring(authority.indexOf('@') + 1);
  }
  return authority;
}

function firstIndexOf(text: string, needles: string[]): number {
  let found: number = -1;
  for (const needle of needles) {
    const at: number = text.indexOf(needle);
    if (at >= 0 && (found < 0 || at < found)) {
      found = at;
    }
  }
  return found;
}

/** The host with brackets intact for IPv6 (e.g. "[::1]" or "gw.example.com"). */
export function hostOf(urlOrOrigin: string): string {
  const authority: string = authorityOf(urlOrOrigin);
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    return close < 0 ? '' : authority.substring(0, close + 1);
  }
  const colon: number = authority.lastIndexOf(':');
  return colon < 0 ? authority : authority.substring(0, colon);
}

/** The hostname without brackets for IPv6 (e.g. "::1" or "gw.example.com"). */
export function hostnameOf(urlOrOrigin: string): string {
  const authority: string = authorityOf(urlOrOrigin);
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    return close < 0 ? authority : authority.substring(1, close);
  }
  const colon: number = authority.lastIndexOf(':');
  return colon < 0 ? authority : authority.substring(0, colon);
}

/** The port an origin carries, or DEFAULT_TLS_PORT (443) when none is specified. */
export function portOf(origin: string): number {
  const authority: string = authorityOf(origin);
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    if (close >= 0 && close + 1 < authority.length && authority.charAt(close + 1) === ':') {
      const parsed: number = Number.parseInt(authority.substring(close + 2), 10);
      return Number.isNaN(parsed) ? DEFAULT_TLS_PORT : parsed;
    }
    return DEFAULT_TLS_PORT;
  }
  const colon: number = authority.lastIndexOf(':');
  if (colon >= 0) {
    const parsed: number = Number.parseInt(authority.substring(colon + 1), 10);
    return Number.isNaN(parsed) ? DEFAULT_TLS_PORT : parsed;
  }
  return DEFAULT_TLS_PORT;
}
