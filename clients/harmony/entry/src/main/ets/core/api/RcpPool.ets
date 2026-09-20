import { rcp } from '@kit.RemoteCommunicationKit';

/**
 * Manages the lifecycle of RCP sessions per gateway origin: one session each, and
 * the old one is closed the moment a new one takes its place.
 */
export class RcpPool {
  private readonly sessions: Map<string, rcp.Session> = new Map<string, rcp.Session>();

  has(origin: string): boolean {
    return this.sessions.has(origin);
  }

  get(origin: string): rcp.Session | undefined {
    return this.sessions.get(origin);
  }

  set(origin: string, session: rcp.Session): void {
    this.close(origin);
    this.sessions.set(origin, session);
  }

  close(origin: string): void {
    const session = this.sessions.get(origin);
    if (session === undefined) {
      return;
    }
    try {
      session.close();
    } catch (error) {
      // Ignore release errors
    }
    this.sessions.delete(origin);
  }

  closeAll(): void {
    for (const origin of Array.from(this.sessions.keys())) {
      this.close(origin);
    }
  }
}
