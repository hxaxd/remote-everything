import { ConnectionConfig } from './ConnectionConfig';

/**
 * Parsed setup URI payload. Mirrors Android's `SetupPayload`.
 */
export class SetupPayload {
  readonly profile: ConnectionConfig;
  readonly invitation: string;

  constructor(profile: ConnectionConfig, invitation: string) {
    this.profile = profile;
    this.invitation = invitation;
  }
}
