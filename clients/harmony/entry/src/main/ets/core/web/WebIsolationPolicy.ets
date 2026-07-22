/**
 * Defines the routing cookie applied to an isolated ArkWeb session.
 */
export class WebIsolationPolicy {
  /**
   * The routing cookie set before first navigation.
   */
  static routingCookie(appId: string): RoutingCookie {
    return {
      name: 'RemoteEverythingApp',
      value: appId,
      path: '/',
      secure: true
    };
  }
}

interface RoutingCookie {
  name: string;
  value: string;
  path: string;
  secure: boolean;
}
