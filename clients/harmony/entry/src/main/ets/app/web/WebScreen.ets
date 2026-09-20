// S4 — one application, in a WebView, with nothing of this app over it.
//
// Each visit owns the private browser context until cookies are saved and teardown completes.
// Only encrypted cookies persist between visits; other website storage is ephemeral.
//
// The screen belongs to the page: no header, no system bars, and everything a chrome
// would carry waits behind the back gesture in `WebPanel` — how the screen is held,
// how the page introduces itself, a reload, and the way out. Those two choices are per
// application and outlive the visit.
//
// What this screen does have to do, because the entrance authenticates every request
// — the WebView's included:
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

import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { webview } from '@kit.ArkWeb';
import { ServerPin } from '../../core/model/Models';
import { MessageKeys } from '../../core/model/MessageKeys';
import { chainMatchesPin, PinVerdict } from '../../core/api/Pinning';
import { ClientAuthPolicy } from '../../core/api/ClientAuthPolicy';
import { hostOf } from '../../core/api/Origins';
import { WebAppPrefs, WebOrientation, WebUserAgent } from '../../core/store/WebAppPrefs';
import { model } from '../AppModel';
import { Strings } from '../i18n/Strings';
import { Metrics, TypeScale } from '../theme/Tokens';
import { Notice, SCREEN_FADE, palette } from '../ui/Components';
import { WindowLayout } from '../WindowLayout';
import { WebPanel } from './WebPanel';
import { WebSessions } from './WebSessions';
import { WebDownloads } from './WebDownloads';

const MAX_PICKED_FILES = 9;

/** How many renderer crashes one visit rebuilds from before the page gives up. */
const MAX_RENDER_REBUILDS = 2;

@ComponentV2
export struct WebScreen {
  @Local private url: string = '';
  @Local private loadFailed: boolean = false;
  @Local private prefs: WebAppPrefs = WebAppPrefs.defaults();
  @Local private panelShown: boolean = false;
  @Local private controller: webview.WebviewController = new webview.WebviewController();
  private prepared: boolean = false;
  private disposed: boolean = false;
  private closing: boolean = false;
  private scope: string = '';
  private sessionUrl: string = '';
  private preparation: Promise<void> = Promise.resolve();
  private releaseTask: Promise<void> | null = null;
  private rendererDead: boolean = false;
  private rendererStopped: (() => void) | null = null;
  private defaultUserAgent: string = '';
  /** Renderer crashes this visit has rebuilt from, before the page gives up. */
  private renderCrashes: number = 0;
  private videoFullscreen: FullScreenExitHandler | null = null;

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          if (this.url === '' && (model.webFailed !== '' || this.loadFailed)) {
            // The failed page has the two things a person can do about it: ask
            // again, and leave — the same pair the other clients offer.
            Notice({
              title: Strings.text(MessageKeys.WEB_LOAD_FAILED),
              body: model.webFailed === '' ? '' : Strings.text(model.webFailed),
              actionLabel: Strings.text(MessageKeys.ACTION_RETRY),
              actionLabel2: Strings.text(MessageKeys.ACTION_BACK),
              dark: model.dark,
              onAction: () => {
                this.retry();
              },
              onAction2: () => {
                this.exit();
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
            Web({ src: this.url, controller: this.controller, incognitoMode: true })
              .multiWindowAccess(false)
              .layoutWeight(1)
              .width('100%')
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .fileAccess(false)
              // Applications such as video conferences and music players run on their
              // own; requiring a gesture is what made them look broken.
              .mediaPlayGestureAccess(false)
              .onControllerAttached(() => {
                try {
                  WebDownloads.bind(this.controller);
                } catch (error) {
                  model.showToast(MessageKeys.WEB_DOWNLOAD_FAILED);
                }
                // The one moment a custom user agent can be set before this
                // component's first request goes out.
                this.applyUserAgent(this.prefs.userAgent, false);
              })
              .onClientAuthenticationRequest((event: OnClientAuthenticationEvent) => {
                this.presentCertificate(event);
              })
              .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent) => {
                this.decideAboutCertificate(event);
              })
              .onShowFileSelector((event: OnShowFileSelectorEvent) => {
                this.pickFiles(event);
                return true;
              })
              .onPermissionRequest((event: OnPermissionRequestEvent) => {
                this.decideAboutPermission(event);
              })
              .onGeolocationShow((event: OnGeolocationShowEvent) => {
                this.decideAboutLocation(event);
              })
              .onFullScreenEnter((event: FullScreenEnterEvent) => {
                // A video that has gone full screen has the screen: the panel is gone,
                // and the way back leaves the full screen before anything else.
                this.panelShown = false;
                this.videoFullscreen = event.handler;
              })
              .onFullScreenExit(() => {
                this.videoFullscreen = null;
              })
              .onLoadIntercept((event: OnLoadInterceptEvent) => {
                return this.interceptLoad(event);
              })
              .onPageEnd(() => {
                this.loadFailed = false;
              })
              .onErrorReceive((event: OnErrorReceiveEvent) => {
                // A resource that failed is not a page that failed: only the main frame
                // turns this screen into its failed state.
                if (!this.closing && event.request.isMainFrame()) {
                  this.loadFailed = true;
                }
              })
              .onRenderExited(() => {
                this.rendererDead = true;
                const stopped: (() => void) | null = this.rendererStopped;
                if (stopped !== null) { stopped(); }
                if (this.closing || this.disposed) { return; }
                this.renderCrashes += 1;
                if (this.renderCrashes > MAX_RENDER_REBUILDS) {
                  this.loadFailed = true;
                } else {
                  this.retry();
                }
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
        .transition(SCREEN_FADE)
        .backgroundColor(palette(model.dark).bg)

          if (this.url !== '' && (model.webFailed !== '' || this.loadFailed)) {
            // The failed page has the two things a person can do about it: ask
            // again, and leave — the same pair the other clients offer.
            Notice({
              title: Strings.text(MessageKeys.WEB_LOAD_FAILED),
              body: model.webFailed === '' ? '' : Strings.text(model.webFailed),
              actionLabel: Strings.text(MessageKeys.ACTION_RETRY),
              actionLabel2: Strings.text(MessageKeys.ACTION_BACK),
              dark: model.dark,
              onAction: () => {
                this.retry();
              },
              onAction2: () => {
                this.exit();
              }
            })

          }

        if (this.panelShown) {
          WebPanel({
            prefs: this.prefs,
            dark: model.dark,
            onOrientation: (orientation: WebOrientation) => {
              this.chooseOrientation(orientation);
            },
            onUserAgent: (userAgent: WebUserAgent) => {
              this.chooseUserAgent(userAgent);
            },
            onRefresh: () => {
              this.panelShown = false;
              this.reload();
            },
            onExit: () => {
              this.exit();
            },
            onDismiss: () => {
              this.panelShown = false;
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(palette(model.dark).bg)
    .onBackPressed(() => {
      // The way back opens this application's panel: the same gesture in every other
      // app is a menu, and leaving is the panel's decision, not the gesture's.
      return this.handleBack();
    })
    .onShown(() => {
      // Coming back — from the background, from a system dialog, from anywhere the
      // screen was merely covered: the session and the page are exactly as they
      // were left, which is what a surviving WebView means. Only a session that
      // already ended in a failure asks the gateway again on its retry.
      if (model.web === null && model.webFailed === '' && model.selectedApp !== null) {
        this.prepared = false;
      }
      this.startPreparation();
    })
    .onHidden(() => {
      // Covered, not left: the session stays, the page keeps its state. The screen
      // is given back when the visit actually ends, in onWillDisappear.
    })
    .onWillDisappear(() => {
      this.leaveScreen();
    })
  }

  /** Asks the gateway where the application is, and gets the identity ready first. */
  private startPreparation(): void {
    if (this.prepared || this.closing || this.disposed) { return; }
    this.preparation = this.prepare();
  }

  private async prepare(): Promise<void> {
    if (this.prepared || this.disposed) {
      return;
    }
    this.prepared = true;
    const app = model.selectedApp;
    if (app === null) {
      model.closeWeb();
      return;
    }
    this.prefs = model.webAppPrefs(this.appKey(app.id));
    WindowLayout.applyFullscreen(this.hostContext(), true);
    WindowLayout.applyOrientation(this.hostContext(), this.prefs.orientation);
    // The identity is fetched before anything navigates: a challenge answered late is
    // a challenge the kernel has already given up on.
    await model.beginWeb(model.catalogNodeId, app);
    model.openAppSettled();
    const session = model.web;
    if (session === null) {
      return;
    }
    if (this.disposed) { return; }
    try {
      this.sessionUrl = session.url;
      this.scope = await WebSessions.enter(session.gatewayOrigin, `${session.nodeId}/${session.appId}`, session.url);
      if (!this.disposed) {
        this.rendererDead = false;
        this.url = session.url;
      }
    } catch (error) {
      model.failWeb(MessageKeys.WEB_SESSION_FAILED);
      this.loadFailed = true;
    }
  }

  private async retry(): Promise<void> {
    if (this.closing || this.disposed || model.selectedApp === null) { return; }
    try {
      await this.release();
      this.releaseTask = null;
      this.closing = false;
      this.controller = new webview.WebviewController();
      this.defaultUserAgent = '';
      this.prepared = false;
      this.loadFailed = false;
      this.startPreparation();
    } catch (error) {
      model.failWeb(MessageKeys.WEB_SESSION_FAILED);
    }
  }

  private async exit(): Promise<void> {
    if (this.disposed) { return; }
    this.disposed = true;
    try {
      await this.release();
    } catch (error) {
      model.showToast(MessageKeys.WEB_SESSION_FAILED);
    }
    model.leaveWeb();
  }

  private release(): Promise<void> {
    if (this.releaseTask !== null) { return this.releaseTask; }
    this.closing = true;
    this.panelShown = false;
    this.releaseTask = this.finishSession();
    return this.releaseTask;
  }

  private async finishSession(): Promise<void> {
    await this.preparation;
    if (this.scope === '') { return; }
    await WebSessions.leave(this.scope, this.sessionUrl,
      () => this.freezeRenderer(), () => this.destroyPage());
    this.scope = '';
  }

  private async freezeRenderer(): Promise<void> {
    if (this.rendererDead || this.controller.getAttachState() !== webview.ControllerAttachState.ATTACHED) { return; }
    try {
      this.controller.stop();
    } catch (error) {
      throw new Error('renderer could not be stopped');
    }
    await new Promise<void>((resolve, reject) => {
      const timeout: number = setTimeout(() => {
        this.rendererStopped = null;
        reject(new Error('renderer termination timed out'));
      }, 3000);
      this.rendererStopped = () => {
        clearTimeout(timeout);
        this.rendererStopped = null;
        resolve();
      };
      try {
        if (!this.controller.terminateRenderProcess()) {
          clearTimeout(timeout);
          this.rendererStopped = null;
          reject(new Error('renderer could not be terminated'));
        }
      } catch (error) {
        clearTimeout(timeout);
        this.rendererStopped = null;
        reject(new Error('renderer termination failed'));
      }
    });
  }

  private async destroyPage(): Promise<void> {
    if (this.controller.getAttachState() !== webview.ControllerAttachState.ATTACHED) {
      this.url = '';
      return;
    }
    await new Promise<void>((resolve, reject) => {
      const changed = (state: webview.ControllerAttachState): void => {
        if (state !== webview.ControllerAttachState.UNATTACHED) { return; }
        clearTimeout(timeout);
        this.controller.off('controllerAttachStateChange', changed);
        resolve();
      };
      const timeout: number = setTimeout(() => {
        this.controller.off('controllerAttachStateChange', changed);
        reject(new Error('browser context teardown timed out'));
      }, 3000);
      this.controller.on('controllerAttachStateChange', changed);
      this.url = '';
    });
  }

  /** The page again, on purpose: what the panel's refresh means. */
  private reload(): void {
    try {
      this.controller.refresh();
    } catch (error) {
      // No controller bound yet: nothing to refresh.
    }
  }

  /** The back gesture: out of full screen, then the panel, and only then nothing. */
  private handleBack(): boolean {
    if (this.closing) { return true; }
    const fullscreen: FullScreenExitHandler | null = this.videoFullscreen;
    if (fullscreen !== null) {
      this.videoFullscreen = null;
      try {
        fullscreen.exitFullScreen();
      } catch (error) {
        // The page left full screen on its own.
      }
      return true;
    }
    if (this.panelShown) {
      this.panelShown = false;
      return true;
    }
    this.panelShown = true;
    return true;
  }

  /** Leaving the screen gives the screen back: the bars, and the orientation. */
  private leaveScreen(): void {
    this.disposed = true;
    this.release().catch(() => { model.showToast(MessageKeys.WEB_SESSION_FAILED); });
    this.panelShown = false;
    this.videoFullscreen = null;
    WindowLayout.applyFullscreen(this.hostContext(), false);
    WindowLayout.applyOrientation(this.hostContext(), WebOrientation.System);
    model.closeWeb();
  }

  // The setting changes; the panel stays. Refresh and Exit are the two that finish
  // something — a choice here is a choice a person may want to follow with another
  // one, and a menu that closes under the hand is a menu that has to be reopened.
  private chooseOrientation(orientation: WebOrientation): void {
    this.prefs = this.prefs.withOrientation(orientation);
    model.saveWebAppPrefs(this.currentAppKey(), this.prefs);
    WindowLayout.applyOrientation(this.hostContext(), orientation);
  }

  private chooseUserAgent(userAgent: WebUserAgent): void {
    this.prefs = this.prefs.withUserAgent(userAgent);
    model.saveWebAppPrefs(this.currentAppKey(), this.prefs);
    this.applyUserAgent(userAgent, true);
  }

  /** A page that asks for a desktop is asking for a desktop. */
  private applyUserAgent(userAgent: WebUserAgent, reload: boolean): void {
    try {
      if (this.defaultUserAgent === '') {
        this.defaultUserAgent = this.controller.getUserAgent();
      }
      const agent: string = userAgent === WebUserAgent.Desktop
        ? WebScreen.desktopUserAgent(this.defaultUserAgent)
        : this.defaultUserAgent;
      this.controller.setCustomUserAgent(agent);
      if (reload) {
        // The page is loaded again rather than refreshed: a refresh re-issues the
        // request the page was fetched with, headers and all, so the identity just
        // chosen would only appear on the load after next.
        this.loadCurrentPage();
      }
    } catch (error) {
      // A controller that is not bound yet: the agent is applied on the next visit.
    }
  }

  /** The address the page is on now, read again — the same page, this time as asked. */
  private loadCurrentPage(): void {
    try {
      const current: string = this.controller.getUrl();
      if (current === '') {
        this.reload();
        return;
      }
      this.controller.loadUrl(current);
    } catch (error) {
      this.reload();
    }
  }

  /**
   * The mobile token goes and the phone becomes a desktop: the engine and its version
   * stay, because they are the truth about what is rendering.
   */
  private static desktopUserAgent(mobile: string): string {
    const webkit: string = WebScreen.match(mobile, 'AppleWebKit/[0-9.]+', 'AppleWebKit/537.36');
    const chrome: string = WebScreen.match(mobile, 'Chrome/[0-9.]+', '');
    if (chrome === '') {
      // The token and its separating space go, or the remains carry a stray gap.
      return mobile.replace('Mobile ', '');
    }
    return `Mozilla/5.0 (X11; Linux x86_64) ${webkit} (KHTML, like Gecko) ${chrome} Safari/537.36`;
  }

  private static match(value: string, pattern: string, fallback: string): string {
    const found: string[] = value.match(new RegExp(pattern)) ?? [];
    return found.length > 0 ? found[0] : fallback;
  }

  private appKey(appId: string): string {
    return `${model.catalogNodeId}/${appId}`;
  }

  /** The key this visit's preferences live under — the node and the app it opened. */
  private currentAppKey(): string {
    const app = model.selectedApp;
    return this.appKey(app === null ? '' : app.id);
  }

  private hostContext(): Context | undefined {
    try {
      return this.getUIContext().getHostContext();
    } catch (error) {
      return undefined;
    }
  }

  // --- what the page may ask the device for ------------------------------------

  /**
   * A file to upload, through the platform's own picker: pictures and videos from the
   * photo picker, and everything else from the document picker.
   */
  private pickFiles(event: OnShowFileSelectorEvent): void {
    const context: common.UIAbilityContext | null = model.abilityContext();
    if (context === null) {
      event.result.handleFileList([]);
      return;
    }
    const accepts: string[] = event.fileSelector.getAcceptType();
    const multiple: boolean = event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode;
    let mediaOnly: boolean = accepts.length > 0;
    for (const accept of accepts) {
      if (!accept.startsWith('image/') && !accept.startsWith('video/')) {
        mediaOnly = false;
      }
    }
    if (mediaOnly) {
      this.pickPhotos(event, multiple);
      return;
    }
    this.pickDocuments(context, event, multiple);
  }

  private pickPhotos(event: OnShowFileSelectorEvent, multiple: boolean): void {
    const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
    options.maxSelectNumber = multiple ? MAX_PICKED_FILES : 1;
    const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    photoPicker.select(options).then((result: photoAccessHelper.PhotoSelectResult) => {
      event.result.handleFileList(result.photoUris);
    }).catch((error: Object) => {
      event.result.handleFileList([]);
    });
  }

  private pickDocuments(context: common.UIAbilityContext, event: OnShowFileSelectorEvent, multiple: boolean): void {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    if (multiple) {
      options.maxSelectNumber = MAX_PICKED_FILES;
    }
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    documentPicker.select(options).then((uris: string[]) => {
      event.result.handleFileList(uris);
    }).catch((error: Object) => {
      event.result.handleFileList([]);
    });
  }

  /**
   * The camera and the microphone, for the gateway's own pages only, and only after
   * the platform has actually granted them.
   */
  private decideAboutPermission(event: OnPermissionRequestEvent): void {
    const host: string = hostOf(event.request.getOrigin());
    if (!this.isKnownApplicationHost(host)) {
      event.request.deny();
      return;
    }
    const wanted: string[] = event.request.getAccessibleResource();
    const needed: Permissions[] = [];
    for (const resource of wanted) {
      if (resource === 'ohos.permission.CAMERA') {
        needed.push('ohos.permission.CAMERA');
      } else if (resource === 'ohos.permission.MICROPHONE') {
        needed.push('ohos.permission.MICROPHONE');
      }
    }
    const context: common.UIAbilityContext | null = model.abilityContext();
    if (needed.length === 0 || context === null) {
      event.request.deny();
      return;
    }
    abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, needed)
      .then((result: PermissionRequestResult) => {
        let granted: boolean = true;
        for (const answer of result.authResults) {
          if (answer !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            granted = false;
          }
        }
        if (granted) {
          event.request.grant(wanted);
        } else {
          event.request.deny();
        }
      })
      .catch((error: Object) => {
        event.request.deny();
      });
  }

  /** A page that asks where it is, for the gateway's own pages only. */
  private decideAboutLocation(event: OnGeolocationShowEvent): void {
    const host: string = hostOf(event.origin);
    const context: common.UIAbilityContext | null = model.abilityContext();
    if (!this.isKnownApplicationHost(host) || context === null) {
      event.geolocation.invoke(event.origin, false, false);
      return;
    }
    const permissions: Permissions[] = ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION'];
    abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions)
      .then((result: PermissionRequestResult) => {
        let granted: boolean = false;
        for (const answer of result.authResults) {
          if (answer === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            granted = true;
          }
        }
        event.geolocation.invoke(event.origin, granted, false);
      })
      .catch((error: Object) => {
        event.geolocation.invoke(event.origin, false, false);
      });
  }

  /**
   * A link that leaves the gateway goes to the system: this WebView carries a device
   * certificate, and it is not for other sites. Everything inside the gateway's own
   * hosts — including the popups a page opens for itself — stays in the page.
   */
  private interceptLoad(event: OnLoadInterceptEvent): boolean {
    if (!event.data.isMainFrame()) {
      return false;
    }
    if (this.closing || this.disposed) { return true; }
    const url: string = event.data.getRequestUrl();
    if (url.startsWith('about:') || url.startsWith('data:') || url.startsWith('blob:')) {
      return false;
    }
    if (!url.startsWith('https://')) {
      this.openExternally(url);
      return true;
    }
    if (this.isKnownApplicationHost(hostOf(url))) {
      return false;
    }
    this.openExternally(url);
    return true;
  }

  private openExternally(url: string): void {
    const context: common.UIAbilityContext | null = model.abilityContext();
    if (context === null) {
      return;
    }
    try {
      context.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      }).catch((error: Object) => {
        // Nothing on this device handles that address.
      });
    } catch (error) {
      // Same.
    }
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
    if (!this.isKnownApplicationHost(event.host) ||
      !ClientAuthPolicy.portMatches(event.port, session.gatewayOrigin, session.url)) {
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
   * answered with, or a host inside its domain.
   */
  private isKnownApplicationHost(host: string): boolean {
    const session = model.web;
    if (session === null) {
      return false;
    }
    if (ClientAuthPolicy.isKnownApplicationHost(session.gatewayOrigin, session.url, host)) {
      return true;
    }
    return model.isKnownApplicationHost(session.gatewayOrigin, host);
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
    model.failWeb(MessageKeys.PAIR_NETWORK);
    this.loadFailed = true;
  }
}
