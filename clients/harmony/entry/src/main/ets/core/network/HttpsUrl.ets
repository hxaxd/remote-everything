/**
 * Small, deterministic HTTPS URL parser for security decisions.
 * It deliberately accepts only DNS names, IPv4 addresses, and bracketed IPv6 literals.
 */
export class HttpsUrlParts {
  readonly host: string;
  readonly port: number;
  readonly authority: string;
  readonly suffix: string;

  constructor(host: string, port: number, authority: string, suffix: string) {
    this.host = host;
    this.port = port;
    this.authority = authority;
    this.suffix = suffix;
  }
}

export class HttpsUrl {
  private static readonly URL_PATTERN =
    /^https:\/\/(\[[^\]]+\]|[^\/?#:]+)(?::([0-9]{1,5}))?([\/?#].*)?$/i;
  private static readonly DNS_LABEL_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i;
  private static readonly IPV6_GROUP_PATTERN = /^[0-9a-f]{1,4}$/i;

  static parse(value: string, originOnly: boolean = false): HttpsUrlParts | null {
    if (HttpsUrl.hasUnsafeCharacter(value)) {
      return null;
    }
    const match = HttpsUrl.URL_PATTERN.exec(value);
    if (match === null) {
      return null;
    }

    const rawHost = match[1];
    const portText = match[2] ?? '';
    const suffix = match[3] ?? '';
    if (originOnly && suffix !== '' && suffix !== '/') {
      return null;
    }

    let host = '';
    let authorityHost = '';
    if (rawHost.startsWith('[') && rawHost.endsWith(']')) {
      host = rawHost.substring(1, rawHost.length - 1).toLowerCase();
      if (!HttpsUrl.isValidIpv6(host)) {
        return null;
      }
      authorityHost = `[${host}]`;
    } else {
      host = rawHost.toLowerCase();
      if (!HttpsUrl.isValidHost(host)) {
        return null;
      }
      authorityHost = host;
    }

    const port = portText === '' ? 443 : parseInt(portText, 10);
    if (isNaN(port) || port < 1 || port > 65535) {
      return null;
    }
    const authority = port === 443 ? authorityHost : `${authorityHost}:${port}`;
    return new HttpsUrlParts(host, port, authority, suffix);
  }

  private static hasUnsafeCharacter(value: string): boolean {
    if (value.includes('\\')) {
      return true;
    }
    for (const character of value) {
      const codePoint = character.codePointAt(0) ?? 0;
      if (codePoint <= 32 || codePoint === 127) {
        return true;
      }
    }
    return false;
  }

  private static isValidHost(host: string): boolean {
    if (host.length === 0 || host.length > 253 || host.endsWith('.')) {
      return false;
    }
    if (/^[0-9.]+$/.test(host)) {
      return HttpsUrl.isValidIpv4(host);
    }
    const labels = host.split('.');
    for (const label of labels) {
      if (!HttpsUrl.DNS_LABEL_PATTERN.test(label)) {
        return false;
      }
    }
    return true;
  }

  private static isValidIpv4(value: string): boolean {
    const parts = value.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const part of parts) {
      if (!/^(0|[1-9][0-9]{0,2})$/.test(part)) {
        return false;
      }
      const octet = parseInt(part, 10);
      if (octet > 255) {
        return false;
      }
    }
    return true;
  }

  private static isValidIpv6(value: string): boolean {
    if (!value.includes(':') || !/^[0-9a-f:.]+$/i.test(value)) {
      return false;
    }
    const compression = value.indexOf('::');
    if (compression >= 0 && compression !== value.lastIndexOf('::')) {
      return false;
    }

    const groups = value.split(':');
    let units = 0;
    for (let index = 0; index < groups.length; index++) {
      const group = groups[index];
      if (group === '') {
        continue;
      }
      if (group.includes('.')) {
        if (index !== groups.length - 1 || !HttpsUrl.isValidIpv4(group)) {
          return false;
        }
        units += 2;
      } else if (HttpsUrl.IPV6_GROUP_PATTERN.test(group)) {
        units += 1;
      } else {
        return false;
      }
    }
    return compression >= 0 ? units < 8 : units === 8;
  }
}
