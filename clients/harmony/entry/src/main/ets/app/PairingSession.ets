// Pairing machine driver and approval polling session for HarmonyOS.

import { Identity } from '../core/model/Models';
import { PairingState } from './State';
import { PairingMachine, PairingOutcome, PairingStage } from '../core/pairing/PairingMachine';
import { PairingTransaction, StagedPairing } from '../core/pairing/PairingTransaction';
import { SetupUri } from '../core/setup/SetupUri';
import { NodesController } from './NodesController';
import { Cadence } from '../core/model/Cadence';

@ObservedV2
export class PairingSession {
  private readonly pairingMachine: PairingMachine;
  private readonly transaction: PairingTransaction;
  private readonly nodesController: NodesController;

  @Trace pairing: PairingState = PairingState.idle();
  @Trace pairingBusy: boolean = false;

  private approvalTimer: number = -1;
  private approvalStartedAt: number = 0;
  varForeground: boolean = true;

  onFinished?: () => void;

  constructor(
    pairingMachine: PairingMachine,
    transaction: PairingTransaction,
    nodesController: NodesController
  ) {
    this.pairingMachine = pairingMachine;
    this.transaction = transaction;
    this.nodesController = nodesController;
  }

  beginPairing(deviceName: string): void {
    this.pairing = new PairingState(PairingStage.Input, null, deviceName, null);
  }

  cancelPairing(): void {
    this.stopApprovalPolling();
    this.pairing = PairingState.idle();
  }

  submitLink(raw: string): void {
    const outcome: PairingOutcome = this.pairingMachine.parseLink(raw);
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
    this.pairingBusy = true;
    try {
      const outcome: PairingOutcome = await this.pairingMachine.pair(setup, this.pairing.deviceName);
      await this.applyPairingOutcome(outcome);
    } finally {
      this.pairingBusy = false;
    }
  }

  async retryPairing(): Promise<void> {
    await this.confirmPairing();
  }

  private async applyPairingOutcome(outcome: PairingOutcome): Promise<void> {
    this.nodesController.reloadIdentities();
    if (outcome.stage === PairingStage.Done) {
      this.stopApprovalPolling();
      this.pairing = PairingState.idle();
      await this.nodesController.refreshNodes();
      this.onFinished?.();
      return;
    }
    if (outcome.stage === PairingStage.WaitingApproval) {
      this.pairing = new PairingState(PairingStage.WaitingApproval, null, this.pairing.deviceName, outcome.errorKey);
      this.beginApprovalPolling();
      await this.nodesController.refreshNodes();
      // Remain in waiting approval UI until administrator approves or timeout
      return;
    }
    this.stopApprovalPolling();
    this.pairing = new PairingState(PairingStage.Failed, null, this.pairing.deviceName, outcome.errorKey);
  }

  beginApprovalPolling(): void {
    this.stopApprovalPolling();
    this.approvalStartedAt = Date.now();
    const step = async (): Promise<void> => {
      if (!this.varForeground) {
        return;
      }
      if (Date.now() - this.approvalStartedAt > Cadence.approvalPollTimeoutMs) {
        this.stopApprovalPolling();
        this.pairing = new PairingState(PairingStage.Failed, null, this.pairing.deviceName, 'pair.approval_timeout');
        return;
      }
      const staged: StagedPairing | null = this.transaction.read();
      if (staged === null) {
        this.stopApprovalPolling();
        return;
      }
      const identity: Identity | null = this.identityFor(staged.origin);
      const effectivePin = staged.serverPin ?? (identity === null ? null : identity.serverPin);
      const outcome: PairingOutcome = await this.pairingMachine.resume(staged, effectivePin);
      if (outcome.stage === PairingStage.Done) {
        this.stopApprovalPolling();
        this.nodesController.reloadIdentities();
        this.pairing = PairingState.idle();
        await this.nodesController.refreshNodes();
        this.onFinished?.();
        return;
      }
      if (outcome.stage === PairingStage.WaitingApproval) {
        this.approvalTimer = setTimeout(step, Cadence.approvalPollMs);
      } else {
        this.stopApprovalPolling();
        this.pairing = new PairingState(PairingStage.Failed, null, staged.deviceName, outcome.errorKey);
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
    const staged: StagedPairing | null = this.transaction.read();
    if (staged === null) {
      return;
    }
    const identity: Identity | null = this.identityFor(staged.origin);
    const effectivePin = staged.serverPin ?? (identity === null ? null : identity.serverPin);
    const outcome: PairingOutcome = await this.pairingMachine.resume(staged, effectivePin);
    if (outcome.stage === PairingStage.Done) {
      this.stopApprovalPolling();
      this.nodesController.reloadIdentities();
      this.pairing = PairingState.idle();
      await this.nodesController.refreshNodes();
      this.onFinished?.();
    } else if (outcome.stage === PairingStage.WaitingApproval) {
      this.pairing = new PairingState(PairingStage.WaitingApproval, null, staged.deviceName, outcome.errorKey);
      this.beginApprovalPolling();
    }
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
