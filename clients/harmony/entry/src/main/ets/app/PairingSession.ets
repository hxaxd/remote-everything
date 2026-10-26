import { Identity } from '../core/model/Models';
import { MessageKeys } from '../core/model/MessageKeys';
import { PairingStage, PairingState } from './State';
import { SetupUri, parseSetupUri } from '../core/setup/SetupUri';
import { PairingResult, PairingService, PairingVerdict } from '../core/pairing/PairingService';
import { StagedSetup, StagedSetupStore } from '../core/pairing/StagedSetup';
import { NodesController } from './NodesController';
import { Cadence } from '../core/model/Cadence';

export class PairingOutcome {
  readonly stage: PairingStage;
  readonly setup: SetupUri | null;
  readonly errorKey: string | null;
  private constructor(stage: PairingStage, setup: SetupUri | null, errorKey: string | null) {
    this.stage = stage; this.setup = setup; this.errorKey = errorKey;
  }
  static input(error: string | null): PairingOutcome { return new PairingOutcome(PairingStage.Input, null, error); }
  static confirm(setup: SetupUri): PairingOutcome { return new PairingOutcome(PairingStage.Confirm, setup, null); }
}

@ObservedV2
export class PairingSession {
  private readonly pairingService: PairingService;
  private readonly transaction: StagedSetupStore;
  private readonly nodesController: NodesController;
  @Trace pairing: PairingState = PairingState.idle();
  @Trace invitationText: string = '';
  @Trace pairingBusy: boolean = false;
  @Trace pendingSetups: StagedSetup[] = [];
  @Trace nameLocked: boolean = false;
  private approvalTimer: number = -1;
  private approvalStartedAt: number = 0;
  private approvalGeneration: number = 0;
  private pairingRun: number = 0;
  private activeOrigin: string = '';
  private readonly resuming: Set<string> = new Set<string>();
  varForeground: boolean = true;
  onFinished?: () => void;

  constructor(service: PairingService, transaction: StagedSetupStore, nodes: NodesController) {
    this.pairingService = service; this.transaction = transaction; this.nodesController = nodes;
  }

  parseLink(raw: string): PairingOutcome {
    try { return PairingOutcome.confirm(parseSetupUri(raw)); }
    catch (error) { return PairingOutcome.input(MessageKeys.PAIR_BAD_INVITATION); }
  }

  private refreshPending(): void { this.pendingSetups = this.transaction.readAll(); }

  beginPairing(deviceName: string): void {
    this.nameLocked = false;
    this.pairingRun += 1;
    this.activeOrigin = '';
    this.invitationText = '';
    this.pairing = new PairingState(PairingStage.Input, null, deviceName, null);
    this.refreshPending();
  }

  cancelPairing(): void {
    this.pairingRun += 1;
    this.activeOrigin = '';
    this.invitationText = '';
    this.pairing = PairingState.idle();
    this.refreshPending();
    if (this.pendingSetups.length > 0) { this.beginApprovalPolling(); }
  }

  async forget(origin: string): Promise<boolean> {
    if (this.activeOrigin === origin) {
      this.pairingRun += 1; this.activeOrigin = ''; this.invitationText = ''; this.pairing = PairingState.idle();
    }
    const removed: boolean = await this.transaction.discard(origin);
    this.refreshPending();
    if (this.pendingSetups.length === 0) { this.stopApprovalPolling(); }
    else { this.beginApprovalPolling(); }
    return removed;
  }

  submitLink(raw: string): void {
    if (this.pairingBusy) { return; }
    if (raw !== this.invitationText) { this.nameLocked = false; }
    this.invitationText = raw;
    if (raw.trim() === '') { this.editLink(); return; }
    const outcome: PairingOutcome = this.parseLink(raw);
    this.pairing = new PairingState(outcome.stage, outcome.setup, this.pairing.deviceName, outcome.errorKey);
  }

  editDeviceName(name: string): void {
    if (!this.pairingBusy && !this.nameLocked) { this.pairing = new PairingState(this.pairing.stage, this.pairing.setup, name, this.pairing.errorKey); }
  }
  editLink(): void { this.pairing = new PairingState(PairingStage.Input, null, this.pairing.deviceName, null); }

  async confirmPairing(): Promise<void> {
    const setup: SetupUri | null = this.pairing.setup;
    if (setup === null || this.pairingBusy || this.pairing.deviceName.trim() === '') { return; }
    const run: number = ++this.pairingRun;
    this.activeOrigin = setup.origin;
    this.pairing = new PairingState(PairingStage.Confirm, setup, this.pairing.deviceName, null);
    this.pairingBusy = true;
    this.nameLocked = true;
    try {
      const result: PairingResult = await this.pairingService.pair(setup, this.pairing.deviceName);
      this.refreshPending();
      this.nodesController.reloadIdentities();
      if (run !== this.pairingRun) {
        if (result.verdict === PairingVerdict.Activated) { await this.nodesController.refreshNodes(true); }
        return;
      }
      if (result.verdict === PairingVerdict.Activated) {
        this.invitationText = ''; this.pairing = PairingState.idle();
        await this.nodesController.refreshNodes(true);
        if (run === this.pairingRun) { this.onFinished?.(); }
      } else if (result.verdict === PairingVerdict.WaitingApproval) {
        this.invitationText = '';
        this.pairing = new PairingState(PairingStage.WaitingApproval, null, this.pairing.deviceName,
          result.errorKey, setup.nodeName);
        this.beginApprovalPolling();
      } else {
        this.pairing = new PairingState(PairingStage.Confirm, setup, this.pairing.deviceName,
          result.errorKey ?? MessageKeys.PAIR_GATEWAY_TROUBLE);
      }
    } finally { this.pairingBusy = false; }
  }

  async retryPairing(): Promise<void> { await this.confirmPairing(); }

  beginApprovalPolling(): void {
    this.refreshPending();
    if (this.approvalTimer >= 0 || this.pendingSetups.length === 0) { return; }
    this.approvalStartedAt = Date.now();
    const generation: number = ++this.approvalGeneration;
    const step = async (): Promise<void> => {
      this.approvalTimer = -1;
      if (generation !== this.approvalGeneration || !this.varForeground || Date.now() - this.approvalStartedAt >= Cadence.approvalPollTimeoutMs) { return; }
      await this.resumeRecords();
      if (generation === this.approvalGeneration && this.varForeground && this.pendingSetups.length > 0) { this.approvalTimer = setTimeout(step, Cadence.approvalPollMs); }
    };
    this.approvalTimer = setTimeout(step, Cadence.approvalPollMs);
  }

  stopApprovalPolling(): void {
    this.approvalGeneration += 1;
    if (this.approvalTimer >= 0) { clearTimeout(this.approvalTimer); this.approvalTimer = -1; }
  }

  private async resumeRecords(origin?: string): Promise<void> {
    for (const staged of this.transaction.readAll()) {
      if ((origin !== undefined && origin !== staged.origin) || this.resuming.has(staged.origin)) { continue; }
      this.resuming.add(staged.origin);
      try {
        const identity: Identity | null = this.nodesController.identitiesSnapshot()
          .find((record: Identity) => record.origin === staged.origin) ?? null;
        const result: PairingResult = await this.pairingService.resume(staged, staged.serverPin ?? identity?.serverPin ?? null);
        this.nodesController.reloadIdentities();
        this.refreshPending();
        if (result.verdict === PairingVerdict.Activated) { await this.nodesController.refreshNodes(true); }
        if (this.activeOrigin !== staged.origin || this.pairingBusy) { continue; }
        if (result.verdict === PairingVerdict.Activated) {
          this.invitationText = ''; this.pairing = PairingState.idle(); this.onFinished?.();
        } else if (result.verdict === PairingVerdict.WaitingApproval) {
          this.pairing = new PairingState(PairingStage.WaitingApproval, null, staged.deviceName, result.errorKey, staged.nodeName);
        } else {
          this.pairing = new PairingState(PairingStage.Input, null, staged.deviceName, result.errorKey);
        }
      } finally { this.resuming.delete(staged.origin); }
    }
    this.refreshPending();
  }

  async retryStaged(origin?: string): Promise<void> {
    if (origin !== undefined && !this.pairingBusy) { this.activeOrigin = origin; }
    await this.resumeRecords(origin);
    this.beginApprovalPolling();
  }

  clearError(): void {
    this.pairing = new PairingState(this.pairing.stage, this.pairing.setup, this.pairing.deviceName, null, this.pairing.nodeName);
  }
}
