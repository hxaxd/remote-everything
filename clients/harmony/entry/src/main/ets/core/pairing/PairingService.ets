// The two round trips of pairing, and nothing else: redeem the invitation, then be
// activated with the credential it yielded. How a waiting or a refusal looks on a
// screen is the app layer's business — no stage machine lives here.
//
// The rules this file enforces, and where they come from:
//
//   * `credential_password` is generated here, 32 random bytes in base64url, and
//     lives in this method's local variable. It is never returned, never stored and
//     never shown; what survives a pairing is the archive this device re-encoded
//     under its own password (IdentityVault.adopt).
//   * Pairing uses the same origin a second time rather than adding a second entry:
//     an origin names one gateway, and a gateway this device is paired with is one
//     identity, whatever happened to its certificate.
//   * Once the pairing request is out it cannot be cancelled: the invitation may
//     already be spent, so the answer is what counts.
//   * Every failure becomes a resource key. Nothing here knows any user-facing words.

import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Identity, ServerPin } from '../model/Models';
import { ClientError, CredentialError, ErrorCode } from '../model/Errors';
import { MessageKeys } from '../model/MessageKeys';
import { Activation, ProtocolClient } from '../api/ProtocolClient';
import { PairingAnswer } from '../api/Dto';
import { SettingsStore } from '../store/SettingsStore';
import { randomBytes } from '../model/Digest';
import { rfc3339EpochMs } from '../json/Strict';
import { IdentityVault, StoredCredential } from '../identity/IdentityVault';
import { SetupUri } from '../setup/SetupUri';
import { StagedSetup, StagedSetupStore } from './StagedSetup';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'RemoteEverything';

/**
 * Every pairing failure becomes a resource key for a screen, and the reason it
 * happened goes no further — so the reason goes to the log, where a diagnosis of
 * "the client's own error" can be answered with the actual failing step and its
 * detail.
 */
function noteFailure(step: string, error: Object): void {
  let detail: string = '';
  if (error instanceof CredentialError) {
    detail = `credential: ${error.detail}`;
  } else if (error instanceof ClientError) {
    detail = `transport: ${error.message}`;
  } else {
    const named: Error = error as Error;
    detail = `${named.name ?? 'Error'}: ${named.message ?? ''}`;
  }
  hilog.error(LOG_DOMAIN, LOG_TAG, `pairing failed at ${step}: ${detail}`);
}

/** How a pairing attempt concluded, before any screen state is made of it. */
export enum PairingVerdict {
  Activated = 'activated',
  WaitingApproval = 'waitingApproval',
  Failed = 'failed'
}

export class PairingResult {
  readonly verdict: PairingVerdict;
  readonly errorKey: string | null;

  private constructor(verdict: PairingVerdict, errorKey: string | null) {
    this.verdict = verdict;
    this.errorKey = errorKey;
  }

  static activated(): PairingResult {
    return new PairingResult(PairingVerdict.Activated, null);
  }

  static waiting(errorKey: string | null): PairingResult {
    return new PairingResult(PairingVerdict.WaitingApproval, errorKey);
  }

  static failed(errorKey: string): PairingResult {
    return new PairingResult(PairingVerdict.Failed, errorKey);
  }
}

/** The one-time credential password: 32 random bytes, base64url, 43 characters. */
function newCredentialPassword(): string {
  const bytes: Uint8Array = randomBytes(32);
  let text: string = '';
  try {
    text = new util.Base64Helper().encodeToStringSync(bytes, util.Type.BASIC_URL_SAFE);
  } finally {
    bytes.fill(0);
  }
  // The server's own pattern is `[A-Za-z0-9_-]{20,64}`, and base64url never carries
  // padding, so this is exactly what it expects.
  return text.replace(/=+$/, '');
}

export class PairingService {
  private readonly client: ProtocolClient;
  private readonly vault: IdentityVault;
  private readonly transaction: StagedSetupStore;
  private readonly identities: SettingsStore;

  constructor(client: ProtocolClient, vault: IdentityVault, transaction: StagedSetupStore,
    identities: SettingsStore) {
    this.client = client;
    this.vault = vault;
    this.transaction = transaction;
    this.identities = identities;
  }

  /**
   * Redeems an invitation and asks to be admitted for its node. A 202 is not a
   * failure: it means the credential is real and the operator has not approved this
   * device yet, and the caller keeps asking.
   */
  async pair(setup: SetupUri, deviceName: string): Promise<PairingResult> {
    const trimmedName: string = deviceName.trim();
    if (trimmedName.length === 0) {
      return PairingResult.failed(MessageKeys.PAIR_DEVICE_NAME_REQUIRED);
    }
    // A pairing whose redeem succeeded but whose activation did not is not
    // redeemed again: the invitation is spent, and finishing what the vault
    // already holds is what resume does. A staged setup for this origin is
    // therefore resumed, not paired over — unless its pending window has
    // closed, in which case it is dropped and the gateway's own answer to a
    // spent invitation is what the user sees.
    const stagedBefore: StagedSetup | null = this.transaction.read();
    if (stagedBefore !== null && stagedBefore.origin === setup.origin) {
      if (!stagedBefore.expired) {
        return await this.resume(stagedBefore, setup.serverPin);
      }
      await this.transaction.discard(setup.origin);
    }
    const credentialPassword: string = newCredentialPassword();
    let answer: PairingAnswer;
    try {
      answer = await this.client.pair(setup.origin, setup.invitation, trimmedName, credentialPassword, setup.serverPin);
    } catch (error) {
      noteFailure('redeem', error);
      return PairingResult.failed(MessageKeys.forFailure(error));
    }
    let stored: StoredCredential;
    try {
      stored = await this.vault.adopt(setup.origin, answer.credentialPkcs12, credentialPassword,
        answer.certificateFingerprint);
    } catch (error) {
      noteFailure('adopt', error);
      return PairingResult.failed(MessageKeys.forFailure(error));
    }
    // The window is the gateway's own, resolved once: the answer was accepted only
    // because its expiry was an RFC 3339 instant, and here it becomes the epoch
    // the staged file compares against.
    const staged: StagedSetup = new StagedSetup(setup.origin, setup.node, setup.nodeName, answer.deviceName,
      stored.fingerprint, stored.keyUri, rfc3339EpochMs(answer.pendingExpiresAt), setup.serverPin);
    this.transaction.stage(staged);
    try {
      await this.client.connect(setup.origin, setup.serverPin);
    } catch (error) {
      noteFailure('connect', error);
      // A network that is down is not a verdict: the invitation is spent but the
      // staged pairing is not, and a later resume (a relaunch or the retry button)
      // asks again with the same credential.
      return PairingResult.failed(MessageKeys.forFailure(error));
    }
    return await this.activate(setup.origin, setup.node, setup.nodeName, setup.serverPin, staged);
  }

  /** Asks again for the activation a staged pairing is waiting on. */
  async resume(staged: StagedSetup, serverPin: ServerPin | null): Promise<PairingResult> {
    const effectivePin: ServerPin | null = serverPin ?? staged.serverPin;
    try {
      await this.client.connect(staged.origin, effectivePin);
    } catch (error) {
      return PairingResult.waiting(MessageKeys.forFailure(error));
    }
    return await this.activate(staged.origin, staged.node, staged.nodeName, effectivePin, staged);
  }

  private async activate(origin: string, nodeId: string, nodeName: string, serverPin: ServerPin | null,
    staged: StagedSetup): Promise<PairingResult> {
    let activation: Activation;
    try {
      activation = await this.client.activate(origin, nodeId);
    } catch (error) {
      return PairingResult.waiting(MessageKeys.forFailure(error));
    }
    if (activation.pending) {
      return PairingResult.waiting(null);
    }
    const failure: ClientError | null = activation.failure;
    if (failure !== null) {
      if (failure.code === ErrorCode.RateLimited || failure.code === ErrorCode.ServerBusy) {
        return PairingResult.waiting(MessageKeys.forError(failure.code));
      }
      if (failure.code === ErrorCode.InvitationDenied || failure.code === ErrorCode.InvitationExpired ||
        failure.code === ErrorCode.Unauthorized) {
        // The invitation is spent and the activation is refused for good: nothing
        // was promoted, so nothing stays behind.
        await this.transaction.discard(origin);
      }
      // Any other refusal is not a verdict — a gateway that was not ready, a node
      // not added yet — so the staged pairing stays for the retry that a later
      // resume makes.
      return PairingResult.failed(failure.code === null
        ? MessageKeys.ERROR_NETWORK : MessageKeys.forError(failure.code));
    }
    this.promote(staged, nodeName, serverPin);
    return PairingResult.activated();
  }

  /**
   * Promotion: the identity is written and the stage is cleared. What is written is
   * what pairing established and nothing more: the origin, the name this device was
   * paired under, the certificate's fingerprint, the reference to it, and the pin of a
   * gateway that signs its own certificate.
   */
  private promote(staged: StagedSetup, nodeName: string, serverPin: ServerPin | null): Identity {
    const identity: Identity = new Identity(staged.origin, staged.deviceName,
      staged.certificateFingerprint, staged.credentialRef, serverPin, Date.now());
    const known: Identity[] = this.identities.readIdentities();
    const kept: Identity[] = known.filter((entry: Identity) => entry.origin !== staged.origin);
    kept.push(identity);
    this.identities.writeIdentities(kept);
    this.transaction.clear();
    return identity;
  }
}
