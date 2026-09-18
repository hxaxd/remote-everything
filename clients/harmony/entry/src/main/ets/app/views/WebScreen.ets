// S4 — one application, in a WebView.
//
// The application is served on an origin of its own, and the client does nothing
// about that: the gateway answered where it is, this screen loads it, and the browser
// keeps its storage per origin by itself. There is no cookie to inject, no storage to
// partition, and no place to put one (pitfalls §2).
//
// Two things this screen does have to do, because the entrance authenticates every
// request — the WebView's included:
//
//   * present the device certificate. The identity is fetched from the certificate
//     manager *before* the first navigation, and the request is answered synchronously
//     in the challenge callback with `confirm(identity, CredentialType.CREDENTIAL_APP)`.
//     A callback that has to await anything is a callback that times out (pitfalls
//     §1.3), and answering `cancel` for want of an identity would poison the kernel's
//     cache for that host and port.
//   * decide about the gateway's own certificate if it is self-signed, using the pin
//     its invitation carried. A mismatch cancels the navigation; there is no way past
//     it, and the fallback is a failed page with a retry, not a warning the user can
//     click away.
//
// The URL is the Web component's static initial value and nothing else: every
// navigation goes through `controller.loadUrl` (pitfalls §2.4), and a retry builds the
// component again rather than reassigning its source.

import { webview } from '@kit.ArkWeb';
import { ServerPin } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';
import { chainMatchesPin, PinVerdict } from '../../core/identity/Pinning';
import { hostOf, belongsToGateway } from '../../core/api/ProtocolClient';
import { model } from '../AppModel';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale } from '../theme/Tokens';
import { Header, Notice, palette } from './Widgets';

const PORT_OMITTED = 0;
const PORT_UNKNOWN = -1;
const DEFAULT_TLS_PORT = 443;

@ComponentV2
export struct WebScreen {
  @Local private url: string = '';
  @Local private loadFailed: boolean = false;
  @Local private controller: webview.WebviewController = new webview.WebviewController();
  private prepared: boolean = false;

  build() {
    NavDestination() {
      Column() {
        Header({
          title: model.selectedApp === null ? '' : model.selectedApp.name,
          dark: model.dark,
          pathLabel: model.web === null ? '' : Strings.text(model.web.isPrivate ? MessageKeys.NODE_LAN
            : MessageKeys.NODE_TUNNEL),
          pathColor: model.web === null ? '' : (model.web.isPrivate ? palette(model.dark).ok
            : palette(model.dark).accent),
          actionLabel: Strings.text(MessageKeys.ACTION_BACK),
          onAction: () => {
            model.leaveWeb();
          }
        })
        if (model.webFailed !== '' || this.loadFailed) {
          Notice({
            title: Strings.text(MessageKeys.WEB_LOAD_FAILED),
            body: model.webFailed === '' ? '' : Strings.text(model.webFailed),
            actionLabel: Strings.text(MessageKeys.ACTION_RETRY),
            dark: model.dark,
            onAction: () => {
              this.retry();
            }
          })
        } else if (this.url === '') {
          Column({ space: Metrics.gapM }) {
            LoadingProgress().width(36).height(36).color(palette(model.dark).accent)
            Text(Strings.text(MessageKeys.WEB_LOADING))
              .fontSize(TypeScale.body)
              .fontColor(palette(model.dark).textSecondary)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          // The address is the component's static initial value; every navigation
          // after it goes through the controller (pitfalls §2.4).
          Web({ src: this.url, controller: this.controller })
            .layoutWeight(1)
            .width('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(false)
            .onClientAuthenticationRequest((event: OnClientAuthenticationEvent) => {
              this.presentCertificate(event);
            })
            .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent) => {
              this.decideAboutCertificate(event);
            })
            .onPageEnd(() => {
              this.loadFailed = false;
            })
            .onErrorReceive((event: OnErrorReceiveEvent) => {
              // A resource that failed is not a page that failed: only the main frame
              // turns this screen into its failed state.
              if (event.request.isMainFrame()) {
                this.loadFailed = true;
              }
            })
            .onRenderExited(() => {
              // The renderer is gone; the page is rebuilt from the same address.
              this.loadFailed = true;
            })
            // The page follows the app's own mode, and the background under it too, so
            // the first frame is not a white flash in the dark (pitfalls §2.5). The
            // page's own colours are never inverted.
            .darkMode(WebDarkMode.Auto)
            .forceDarkAccess(false)
            .backgroundColor(palette(model.dark).bg)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(palette(model.dark).bg)
    }
    .hideTitleBar(true)
    .backgroundColor(palette(model.dark).bg)
    .onBackPressed(() => {
      // The platform's back gesture consumes the page's own history first, and leaves
      // the application only when there is nothing left to go back to.
      return this.goBack();
    })
    .onShown(() => {
      this.prepare();
    })
    .onHidden(() => {
      model.closeWeb();
    })
  }

  /** Asks the gateway where the application is, and gets the identity ready first. */
  private async prepare(): Promise<void> {
    if (this.prepared) {
      return;
    }
    this.prepared = true;
    const app = model.selectedApp;
    if (app === null) {
      model.closeWeb();
      return;
    }
    // The identity is fetched before anything navigates: a challenge answered late is
    // a challenge the kernel has already given up on.
    await model.beginWeb(model.catalogNodeId, app);
    const session = model.web;
    if (session === null) {
      return;
    }
    if (this.url === '') {
      // The first address is the component's own source, set once and never changed.
      this.url = session.url;
      return;
    }
    // Everything after that is a navigation, and navigations go through the
    // controller (pitfalls §2.4).
    await this.load(session.url);
  }

  /** Navigates, once the controller is actually bound — never on a guessed delay. */
  private async load(url: string): Promise<void> {
    try {
      if (this.controller.getAttachState() !== webview.ControllerAttachState.ATTACHED) {
        await this.controller.waitForAttached(2000);
      }
      this.controller.loadUrl(url);
    } catch (error) {
      // The component is gone; the next screen will build a new one.
    }
  }

  /** Retrying asks the gateway again, so a changed answer is picked up. */
  private retry(): void {
    if (model.selectedApp === null) {
      return;
    }
    this.prepared = false;
    this.loadFailed = false;
    this.prepare();
  }

  private goBack(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (error) {
      // No controller bound yet: nothing to go back through.
    }
    return false;
  }

  /**
   * The certificate challenge. Everything here is synchronous, and the certificate is
   * only offered to a host that belongs to this gateway.
   */
  private presentCertificate(event: OnClientAuthenticationEvent): void {
    const session = model.web;
    if (session === null) {
      // Nothing to present: the navigation was already refused a moment ago, and
      // cancelling here would only teach the kernel not to ask again.
      return;
    }
    if (!this.isKnownApplicationHost(event.host) || !this.portMatches(event.port, session.gatewayOrigin)) {
      return;
    }
    try {
      event.handler.confirm(session.keyUri, CredentialType.CREDENTIAL_APP);
    } catch (error) {
      // A handler that has already been answered cannot be answered again.
    }
  }

  /**
   * Whether the host is one this gateway serves: its own, the application origin it
   * answered with, or a host inside its domain — which is how a gateway with a domain
   * serves each application on `<appid>.<node>.<domain>`.
   */
  private isKnownApplicationHost(host: string): boolean {
    const session = model.web;
    if (session === null) {
      return false;
    }
    if (host === hostOf(session.gatewayOrigin) || host === hostOf(session.url)) {
      return true;
    }
    if (model.isKnownApplicationHost(session.gatewayOrigin, host)) {
      return true;
    }
    return belongsToGateway(session.gatewayOrigin, `https://${host}`);
  }

  /**
   * The port a challenge names, compared the only way it can be: a port the platform
   * omitted, one it reports as unknown, and the default one are the same thing
   * (pitfalls §1.3).
   */
  private portMatches(port: number, origin: string): boolean {
    const gatewayPort: number = portOf(origin);
    if (gatewayPort === DEFAULT_TLS_PORT) {
      return true;
    }
    if (port === PORT_UNKNOWN || port === PORT_OMITTED) {
      return true;
    }
    return port === gatewayPort;
  }

  /** Whether the gateway's own certificate may be used. */
  private decideAboutCertificate(event: OnSslErrorEventReceiveEvent): void {
    const session = model.web;
    const pin: ServerPin | null = session === null ? null : session.serverPin;
    if (pin === null) {
      // A gateway with a domain is verified by the platform; anything it refuses is
      // refused here too.
      this.refuse(event);
      return;
    }
    const chain: Uint8Array[] = event.certChainData === undefined ? [] : event.certChainData;
    if (chain.length === 0 || chainMatchesPin(chain, pin) === PinVerdict.Refused) {
      this.refuse(event);
      return;
    }
    try {
      event.handler.handleConfirm();
    } catch (error) {
      // The decision was already made for this navigation.
    }
  }

  private refuse(event: OnSslErrorEventReceiveEvent): void {
    try {
      event.handler.handleCancel();
    } catch (error) {
      // The decision was already made for this navigation.
    }
    model.webFailed = MessageKeys.PAIR_NETWORK;
    this.loadFailed = true;
  }
}

/** The port an origin carries, or the default one when it carries none. */
function portOf(origin: string): number {
  const scheme: number = origin.indexOf('://');
  const authority: string = scheme < 0 ? origin : origin.substring(scheme + 3);
  const stop: number = authority.indexOf('/');
  const host: string = stop < 0 ? authority : authority.substring(0, stop);
  const colon: number = host.lastIndexOf(':');
  if (colon < 0 || colon < host.indexOf(']')) {
    return DEFAULT_TLS_PORT;
  }
  const parsed: number = Number.parseInt(host.substring(colon + 1), 10);
  return Number.isNaN(parsed) ? DEFAULT_TLS_PORT : parsed;
}
