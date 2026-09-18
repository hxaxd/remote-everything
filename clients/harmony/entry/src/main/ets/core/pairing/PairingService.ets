// The add-node flow, as ui-contract §2/S2 states it: input → confirm → pairing →
// done, with failed wherever it can be reached.
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
import { Identity, ServerPin } from '../model/Models';
import { ClientError, ErrorCode } from '../api/Errors';
import { MessageKeys } from '../model/MessageKeys';
import { Activation, credentialFailure, ProtocolClient } from '../api/ProtocolClient';
import { PairingAnswer } from '../api/Dto';
import { IdentityStore } from '../store/IdentityStore';
import { randomBytes } from '../model/Digest';
import { CredentialError } from '../identity/CredentialError';
import { IdentityVault, StoredCredential } from '../identity/IdentityVault';
import { parseSetupUri, SetupError, SetupUri } from '../setup/SetupUri';
import { PairingTransaction, StagedPairing, StagedSetupStore } from './StagedSetup';

export enum PairingStage {
  Input = 'input',
  Confirm = 'confirm',
  Pairing = 'pairing',
  WaitingApproval = 'waitingApproval',
  Done = 'done',
  Failed = 'failed'
}

export class PairingOutcome {
  readonly stage: PairingStage;
  readonly setup: SetupUri | null;
  readonly identity: Identity | null;
  readonly staged: StagedPairing | null;
  readonly errorKey: string | null;
  readonly retryAfterMs: number;

  constructor(stage: PairingStage, setup: SetupUri | null, identity: Identity | null, staged: StagedPairing | null,
    errorKey: string | null, retryAfterMs: number) {
    this.stage = stage;
    this.setup = setup;
    this.identity = identity;
    this.staged = staged;
    this.errorKey = errorKey;
    this.retryAfterMs = retryAfterMs;
  }

  static input(errorKey: string | null): PairingOutcome {
    return new PairingOutcome(PairingStage.Input, null, null, null, errorKey, 0);
  }

  static confirm(setup: SetupUri): PairingOutcome {
    return new PairingOutcome(PairingStage.Confirm, setup, null, null, null, 0);
  }

  static failed(errorKey: string): PairingOutcome {
    return new PairingOutcome(PairingStage.Failed, null, null, null, errorKey, 0);
  }

  static done(identity: Identity): PairingOutcome {
    return new PairingOutcome(PairingStage.Done, null, identity, null, null, 0);
  }

  static waiting(staged: StagedPairing, errorKey: string | null, retryAfterMs: number): PairingOutcome {
    return new PairingOutcome(PairingStage.WaitingApproval, null, null, staged, errorKey, retryAfterMs);
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
  private readonly identities: IdentityStore;

  constructor(client: ProtocolClient, vault: IdentityVault, transaction: StagedSetupStore,
    identities: IdentityStore) {
    this.client = client;
    this.vault = vault;
    this.transaction = transaction;
    this.identities = identities;
  }

  /** One pasted or scanned link becomes the confirmation step, or an inline refusal. */
  parseLink(raw: string): PairingOutcome {
    try {
      return PairingOutcome.confirm(parseSetupUri(raw));
    } catch (error) {
      if (error instanceof SetupError) {
        return PairingOutcome.input(MessageKeys.PAIR_BAD_INVITATION);
      }
      return PairingOutcome.input(MessageKeys.PAIR_BAD_INVITATION);
    }
  }

  /**
   * Redeems an invitation and asks to be admitted for its node. A 202 is not a
   * failure: it means the credential is real and the operator has not approved this
   * device yet, and the caller keeps asking.
   */
  async pair(setup: SetupUri, deviceName: string): Promise<PairingOutcome> {
    const trimmedName: string = deviceName.trim();
    if (trimmedName.length === 0) {
      return PairingOutcome.failed(MessageKeys.PAIR_DEVICE_NAME_REQUIRED);
    }
    const credentialPassword: string = newCredentialPassword();
    let answer: PairingAnswer;
    try {
      answer = await this.client.pair(setup.origin, setup.invitation, trimmedName, credentialPassword, setup.serverPin);
    } catch (error) {
      return PairingOutcome.failed(this.keyFor(error));
    }
    let stored: StoredCredential;
    try {
      stored = await this.vault.adopt(setup.origin, answer.credentialPkcs12, credentialPassword,
        answer.certificateFingerprint);
    } catch (error) {
      return PairingOutcome.failed(this.keyFor(error));
    }
    const staged: StagedPairing = new StagedPairing(setup.origin, setup.node, setup.nodeName, answer.deviceName,
      stored.fingerprint, stored.keyUri, answer.pendingExpiresAt, Date.now(), setup.serverPin);
    this.transaction.stage(staged);
    try {
      await this.client.connect(setup.origin, setup.serverPin);
    } catch (error) {
      await this.transaction.discard(setup.origin);
      return PairingOutcome.failed(this.keyFor(error));
    }
    return await this.activate(setup.origin, setup.node, setup.nodeName, setup.serverPin, staged);
  }

  /** Asks again for the activation a staged pairing is waiting on. */
  async resume(staged: StagedPairing, serverPin: ServerPin | null): Promise<PairingOutcome> {
    const effectivePin: ServerPin | null = serverPin ?? staged.serverPin;
    try {
      await this.client.connect(staged.origin, effectivePin);
    } catch (error) {
      return PairingOutcome.waiting(staged, this.keyFor(error), 0);
    }
    return await this.activate(staged.origin, staged.node, staged.nodeName, effectivePin, staged);
  }

  private async activate(origin: string, nodeId: string, nodeName: string, serverPin: ServerPin | null,
    staged: StagedPairing): Promise<PairingOutcome> {
    let activation: Activation;
    try {
      activation = await this.client.activate(origin, nodeId);
    } catch (error) {
      return PairingOutcome.waiting(staged, this.keyFor(error), 0);
    }
    if (activation.pending) {
      return PairingOutcome.waiting(staged, null, 0);
    }
    const failure: ClientError | null = activation.failure;
    if (failure !== null) {
      if (failure.code === ErrorCode.RateLimited || failure.code === ErrorCode.ServerBusy) {
        return PairingOutcome.waiting(staged, MessageKeys.forError(failure.code), failure.retryAfterMs);
      }
      // The invitation is spent and the activation was refused: nothing was
      // promoted, so nothing stays behind.
      await this.transaction.discard(origin);
      return PairingOutcome.failed(MessageKeys.forError(failure.code));
    }
    return PairingOutcome.done(this.promote(staged, nodeName, serverPin));
  }

  /**
   * Promotion: the identity is written and the stage is cleared. What is written is
   * what pairing established and nothing more: the origin, the name this device was
   * paired under, the certificate's fingerprint, the reference to it, and the pin of a
   * gateway that signs its own certificate.
   */
  private promote(staged: StagedPairing, nodeName: string, serverPin: ServerPin | null): Identity {
    const identity: Identity = new Identity(staged.origin, staged.deviceName,
      staged.certificateFingerprint, staged.credentialRef, serverPin, Date.now());
    const known: Identity[] = this.identities.read();
    const kept: Identity[] = known.filter((entry: Identity) => entry.origin !== staged.origin);
    kept.push(identity);
    this.identities.write(kept);
    this.transaction.clear();
    return identity;
  }

  private keyFor(error: Object): string {
    if (error instanceof CredentialError) {
      return MessageKeys.forError(credentialFailure(error).code);
    }
    if (error instanceof ClientError) {
      return MessageKeys.forError(error.code);
    }
    return MessageKeys.forError(ErrorCode.Network);
  }
}

export type PairingMachine = PairingService;
export const PairingMachine = PairingService;
