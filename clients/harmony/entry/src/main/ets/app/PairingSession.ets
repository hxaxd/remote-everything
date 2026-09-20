// S2's session: the pairing stage machine, and the approval polling around it.
//
// The stages live here, in the app layer, because they are screen states — core's
// PairingService answers only with activated / waiting / failed, and what those mean
// to the person holding the phone is decided here. One rule comes from the shared
// behaviour (behavior/README.md): when the approval-polling window is walked to its
// end, every client only stops polling and keeps the staged pairing exactly where it
// is — the operator may still approve at any moment, and pulling the app up again
// asks about it once more. A timeout is not a verdict, so nothing here turns one
// into a failure.

import { Identity } from '../core/model/Models';
import { MessageKeys } from '../core/model/MessageKeys';
import { PairingStage, PairingState } from './State';
import { SetupUri, parseSetupUri, SetupError } from '../core/setup/SetupUri';
import { PairingResult, PairingService, PairingVerdict } from '../core/pairing/PairingService';
import { StagedSetup, StagedSetupStore } from '../core/pairing/StagedSetup';
import { NodesController } from './NodesController';
import { Cadence } from '../core/model/Cadence';

/** What one step of the pairing flow concluded, in screen terms. */
export class PairingOutcome {
  readonly stage: PairingStage;
  readonly setup: SetupUri | null;
  readonly errorKey: string | null;

  private constructor(stage: PairingStage, setup: SetupUri | null, errorKey: string | null) {
    this.stage = stage;
    this.setup = setup;
    this.errorKey = errorKey;
  }

  static input(errorKey: string | null): PairingOutcome {
    return new PairingOutcome(PairingStage.Input, null, errorKey);
  }

  static confirm(setup: SetupUri): PairingOutcome {
    return new PairingOutcome(PairingStage.Confirm, setup, null);
  }
}

@ObservedV2
export class PairingSession {
  private readonly pairingService: PairingService;
  private readonly transaction: StagedSetupStore;
  private readonly nodesController: NodesController;

  @Trace pairing: PairingState = PairingState.idle();
  @Trace pairingBusy: boolean = false;

  private approvalTimer: number = -1;
  private approvalStartedAt: number = 0;
  /** Which pairing run is the live one; a cancel or a forget turns it over. */
  private pairingRun: number = 0;
  varForeground: boolean = true;

  onFinished?: () => void;

  constructor(
    pairingService: PairingService,
    transaction: StagedSetupStore,
    nodesController: NodesController
  ) {
    this.pairingService = pairingService;
    this.transaction = transaction;
    this.nodesController = nodesController;
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

  beginPairing(deviceName: string): void {
    this.pairing = new PairingState(PairingStage.Input, null, deviceName, null);
  }

  cancelPairing(): void {
    // Leaving mid-flight is a verdict of its own: the run in progress is marked
    // gone, so its answer, whenever it arrives, lands nowhere.
    this.pairingRun += 1;
    this.stopApprovalPolling();
    this.pairing = PairingState.idle();
  }

  /** Forgetting a gateway takes its half-finished pairing with it. */
  forget(origin: string): void {
    const staged: StagedSetup | null = this.transaction.read();
    if (staged === null || staged.origin !== origin) {
      return;
    }
    this.pairingRun += 1;
    this.stopApprovalPolling();
    this.transaction.discard(origin);
    this.pairing = PairingState.idle();
  }

  submitLink(raw: string): void {
    const outcome: PairingOutcome = this.parseLink(raw);
    if (outcome.stage === PairingStage.Confirm && outcome.setup !== null) {
      this.pairing = new PairingState(PairingStage.Confirm, outcome.setup, this.pairing.deviceName, null);
      return;
    }
    this.pairing = new PairingState(PairingStage.Input, null, this.pairing.deviceName, outcome.errorKey);
  }

  editDeviceName(name: string): void {
    this.pairing = new PairingState(this.pairing.stage, this.pairing.setup, name, this.pairing.errorKey);
  }

  editLink(): void {
    this.pairing = new PairingState(PairingStage.Input, null, this.pairing.deviceName, null);
  }

  async confirmPairing(): Promise<void> {
    const setup: SetupUri | null = this.pairing.setup;
    if (setup === null || this.pairingBusy) {
      return;
    }
    const run: number = this.pairingRun;
    // A fresh attempt clears the verdict of the last one before it asks.
    this.pairing = new PairingState(PairingStage.Confirm, setup, this.pairing.deviceName, null);
    this.pairingBusy = true;
    try {
      const result: PairingResult = await this.pairingService.pair(setup, this.pairing.deviceName);
      if (run !== this.pairingRun) {
        // The person left while the request was in the air: the answer is real,
        // but nobody is waiting for it on this screen any more.
        return;
      }
      await this.applyPairingResult(result);
    } finally {
      this.pairingBusy = false;
    }
  }

  async retryPairing(): Promise<void> {
    await this.confirmPairing();
  }

  private async applyPairingResult(result: PairingResult): Promise<void> {
    this.nodesController.reloadIdentities();
    if (result.verdict === PairingVerdict.Activated) {
      this.stopApprovalPolling();
      this.pairing = PairingState.idle();
      await this.nodesController.refreshNodes();
      this.onFinished?.();
      return;
    }
    if (result.verdict === PairingVerdict.WaitingApproval) {
      const waitingOn: string = this.pairing.setup === null ? this.pairing.nodeName : this.pairing.setup.nodeName;
      this.pairing = new PairingState(PairingStage.WaitingApproval, null, this.pairing.deviceName,
        result.errorKey, waitingOn);
      this.beginApprovalPolling();
      await this.nodesController.refreshNodes();
      // Remain in waiting approval UI until the operator approves; the polling
      // window only ever stops the asking, never the staged pairing itself.
      return;
    }
    this.stopApprovalPolling();
    // A refused attempt keeps the confirmation on screen — the card and its join
    // button stay, the reason is named inline, and joining again is the retry.
    this.pairing = new PairingState(PairingStage.Confirm, this.pairing.setup, this.pairing.deviceName,
      result.errorKey ?? MessageKeys.PAIR_GATEWAY_TROUBLE);
  }

  beginApprovalPolling(): void {
    this.stopApprovalPolling();
    this.approvalStartedAt = Date.now();
    // A staged pairing being polled is a pairing that is waiting, wherever the
    // screen happens to be — the home banner reads this state.
    const stagedNow: StagedSetup | null = this.transaction.read();
    if (stagedNow !== null) {
      this.pairing = new PairingState(PairingStage.WaitingApproval, null, stagedNow.deviceName, null,
        stagedNow.nodeName);
    }
    const step = async (): Promise<void> => {
      if (!this.varForeground) {
        return;
      }
      if (Date.now() - this.approvalStartedAt > Cadence.approvalPollTimeoutMs) {
        // The window is walked to its end: the asking stops, and the staged
        // pairing stays exactly as it is. The operator may still approve; the next
        // foreground asks about it again.
        this.stopApprovalPolling();
        return;
      }
      const staged: StagedSetup | null = this.transaction.read();
      if (staged === null) {
        this.stopApprovalPolling();
        return;
      }
      const identity: Identity | null = this.identityFor(staged.origin);
      const effectivePin = staged.serverPin ?? (identity === null ? null : identity.serverPin);
      const result: PairingResult = await this.pairingService.resume(staged, effectivePin);
      if (result.verdict === PairingVerdict.Activated) {
        this.stopApprovalPolling();
        this.nodesController.reloadIdentities();
        this.pairing = PairingState.idle();
        await this.nodesController.refreshNodes();
        this.onFinished?.();
        return;
      }
      if (result.verdict === PairingVerdict.WaitingApproval) {
        this.approvalTimer = setTimeout(step, Cadence.approvalPollMs);
      } else {
        this.stopApprovalPolling();
        // A resume that fails below the protocol lands back on the input screen
        // with the reason named inline — the same place a fresh paste would.
        this.pairing = new PairingState(PairingStage.Input, null, staged.deviceName,
          result.errorKey ?? MessageKeys.PAIR_GATEWAY_TROUBLE);
      }
    };
    this.approvalTimer = setTimeout(step, Cadence.approvalPollMs);
  }

  stopApprovalPolling(): void {
    if (this.approvalTimer >= 0) {
      clearTimeout(this.approvalTimer);
      this.approvalTimer = -1;
    }
  }

  async retryStaged(): Promise<void> {
    const staged: StagedSetup | null = this.transaction.read();
    if (staged === null) {
      return;
    }
    const identity: Identity | null = this.identityFor(staged.origin);
    const effectivePin = staged.serverPin ?? (identity === null ? null : identity.serverPin);
    const result: PairingResult = await this.pairingService.resume(staged, effectivePin);
    if (result.verdict === PairingVerdict.Activated) {
      this.stopApprovalPolling();
      this.nodesController.reloadIdentities();
      this.pairing = PairingState.idle();
      await this.nodesController.refreshNodes();
      this.onFinished?.();
    } else if (result.verdict === PairingVerdict.WaitingApproval) {
      this.pairing = new PairingState(PairingStage.WaitingApproval, null, staged.deviceName,
        result.errorKey, staged.nodeName);
      this.beginApprovalPolling();
    } else {
      this.stopApprovalPolling();
      this.pairing = new PairingState(PairingStage.Input, null, staged.deviceName,
        result.errorKey ?? MessageKeys.PAIR_GATEWAY_TROUBLE);
    }
  }

  /** Editing the link field clears the last verdict, like Android's resetPairing. */
  clearError(): void {
    if (this.pairing.errorKey === null) {
      return;
    }
    this.pairing = new PairingState(this.pairing.stage, this.pairing.setup, this.pairing.deviceName,
      null, this.pairing.nodeName);
  }

  private identityFor(origin: string): Identity | null {
    for (const identity of this.nodesController.identitiesSnapshot()) {
      if (identity.origin === origin) {
        return identity;
      }
    }
    return null;
  }
}
