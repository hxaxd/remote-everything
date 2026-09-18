import { rcp } from '@kit.RemoteCommunicationKit';

/**
 * Manages the lifecycle of RCP sessions and in-flight requests per gateway origin.
 */
export class RcpPool {
  private readonly sessions: Map<string, rcp.Session> = new Map<string, rcp.Session>();
  private readonly inflight: Map<string, rcp.Request> = new Map<string, rcp.Request>();

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
    this.inflight.delete(origin);
  }

  closeAll(): void {
    for (const origin of Array.from(this.sessions.keys())) {
      this.close(origin);
    }
  }

  setInflight(origin: string, request: rcp.Request): void {
    this.inflight.set(origin, request);
  }

  clearInflight(origin: string): void {
    this.inflight.delete(origin);
  }

  cancelInflight(origin: string): void {
    const session = this.sessions.get(origin);
    const request = this.inflight.get(origin);
    if (session !== undefined && request !== undefined) {
      try {
        session.cancel(request);
      } catch (error) {
        // Request may already have finished
      }
      this.inflight.delete(origin);
    }
  }
}
