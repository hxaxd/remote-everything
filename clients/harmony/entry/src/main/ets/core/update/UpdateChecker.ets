// Checking for a new version of this client.
//
// The manifest is clients/release.json in the repository, served from the release
// channel's fixed address. It is deliberately not read from a gateway: a device that
// has never paired has no gateway, and a device whose gateway is gone still has to be
// told that the protocol it speaks has changed. Two questions are answered from it
// (ui-contract §5):
//
//   * is there a newer build — a note, with the app store as the way to get it;
//   * does the manifest speak a different protocol — which is not a note but a stop
//     sign, because there is no negotiation and no compatibility path: an upgrade
//     means pairing again.
//
// The manifest is read strictly, like everything else: it is a document from the
// network, and a substituted document must not be able to talk this client into
// anything.

import { JsonReader, isVersionName } from '../json/Strict';

/**
 * Where the release manifest lives: the repository's own channel, the same address
 * the other clients read. Fixed on purpose — it has to work before anything is paired.
 */
export const RELEASE_URL = 'https://raw.githubusercontent.com/hxaxd/remote-everything/main/clients/release.json';

export class ReleaseManifest {
  readonly versionName: string;
  readonly buildNumber: number;
  readonly protocolVersion: number;

  constructor(versionName: string, buildNumber: number, protocolVersion: number) {
    this.versionName = versionName;
    this.buildNumber = buildNumber;
    this.protocolVersion = protocolVersion;
  }
}

/** What a check concluded. `unreachable` is not an error the user has to act on. */
export enum UpdateVerdict {
  UpToDate = 'upToDate',
  Available = 'available',
  ProtocolChanged = 'protocolChanged',
  Unreachable = 'unreachable'
}

export class UpdateCheck {
  readonly verdict: UpdateVerdict;
  readonly versionName: string;
  readonly buildNumber: number;

  constructor(verdict: UpdateVerdict, versionName: string, buildNumber: number) {
    this.verdict = verdict;
    this.versionName = versionName;
    this.buildNumber = buildNumber;
  }

  static unreachable(): UpdateCheck {
    return new UpdateCheck(UpdateVerdict.Unreachable, '', 0);
  }
}

/** Reads the manifest strictly. An unreadable one is no manifest at all. */
export function decodeRelease(text: string): ReleaseManifest {
  const reader: JsonReader = JsonReader.parse(text, 'the release manifest');
  reader.rejectUnknown(['schema', 'versionName', 'buildNumber', 'protocolVersion', 'minimumPlatforms']);
  if (reader.number('schema') !== 1) {
    throw new Error('the release manifest is not the one this client reads');
  }
  const versionName: string = reader.string('versionName');
  if (!isVersionName(versionName)) {
    throw new Error('the release manifest does not name a version');
  }
  const buildNumber: number = reader.number('buildNumber');
  const protocolVersion: number = reader.number('protocolVersion');
  if (buildNumber < 1 || protocolVersion < 1) {
    throw new Error('the release manifest is not a monotone build');
  }
  // The three platforms are all required, exactly as the other two clients decode
  // them: an SDK number, and the two version strings.
  const platforms: JsonReader = reader.object('minimumPlatforms');
  platforms.rejectUnknown(['androidSdk', 'ios', 'harmonyApi']);
  const androidSdk: number = platforms.number('androidSdk');
  if (!Number.isInteger(androidSdk)) {
    throw new Error('the release manifest names a fractional Android SDK');
  }
  platforms.string('ios');
  platforms.string('harmonyApi');
  return new ReleaseManifest(versionName, buildNumber, protocolVersion);
}

/** What one check says, given what this build is. */
export function verdictFor(manifest: ReleaseManifest, buildNumber: number, protocolVersion: number): UpdateCheck {
  if (manifest.protocolVersion !== protocolVersion) {
    return new UpdateCheck(UpdateVerdict.ProtocolChanged, manifest.versionName, manifest.buildNumber);
  }
  if (manifest.buildNumber > buildNumber) {
    return new UpdateCheck(UpdateVerdict.Available, manifest.versionName, manifest.buildNumber);
  }
  return new UpdateCheck(UpdateVerdict.UpToDate, manifest.versionName, manifest.buildNumber);
}
