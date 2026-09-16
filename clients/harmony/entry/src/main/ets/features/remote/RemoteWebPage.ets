import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { cert } from '@kit.DeviceCertificateKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { ConnectionConfig, ConnectionMode } from '../../core/models/ConnectionConfig';
import { CredentialStore, ClientIdentity } from '../../core/security/CredentialStore';
import { WebIsolationPolicy } from '../../core/web/WebIsolationPolicy';
import { ClientSettings } from '../../core/storage/ClientSettings';
import { router } from '@kit.ArkUI';
import { uri } from '@kit.ArkTS';

interface UrlPermissionEntry {
  scheme: string;
  host: string;
  port: number;
  path: string;
}

interface UrlPermissionDocument {
  UrlPermissionList: UrlPermissionEntry[];
}

@Entry
@Component
export struct RemoteWebPage {
  @State config: ConnectionConfig | null = null;
  @State appId: string = '';
  @State appName: string = '';
  @State openUrl: string = '';
  @State webSource: string = '';
  @State appOrientation: string = 'global';
  @State appDisplayMode: string = 'global';
  @State displayMode: string = 'phone';
  @State showControls: boolean = false;
  @State isVerifyingGateway: boolean = false;
  @State webJavaScriptEnabled: boolean = false;
  @State failureMessage: string = '';
  @State downloadMessage: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private pageGeneration: number = 0;
  private controllerAttached: boolean = false;
  private edgeTouchStartX: number = 0;
  private edgeTouchActive: boolean = false;
  private readyIdentity: ClientIdentity | null = null;
  private readyAuthUri: string = '';
  private identityReady: boolean = false;

  private routeString(params: Record<string, Object>, name: string): string {
    const value = params[name];
    return typeof value === 'string' ? value : '';
  }

  aboutToAppear(): void {
    this.config = null;
    this.appId = '';
    this.appName = '';
    this.openUrl = '';
    this.webSource = '';
    this.isVerifyingGateway = false;
    this.webJavaScriptEnabled = false;
    this.showControls = false;
    this.failureMessage = '';
    this.downloadMessage = '';
    this.controllerAttached = false;
    this.readyIdentity = null;
    this.readyAuthUri = '';
    this.identityReady = false;
    const params = router.getParams() as Record<string, Object>;
    if (params !== null) {
      const mode = this.routeString(params, 'connectionMode');
      if (mode === ConnectionMode.LAN || mode === ConnectionMode.PUBLIC) {
        this.config = new ConnectionConfig(
          this.routeString(params, 'installationId'),
          this.routeString(params, 'profileName'),
          mode,
          this.routeString(params, 'gatewayOrigin'),
          this.routeString(params, 'gatewayFingerprint'),
          this.routeString(params, 'gatewayPublicKeyPin')
        );
      }
      this.appId = this.routeString(params, 'appId');
      this.appName = this.routeString(params, 'appName');
      this.openUrl = this.routeString(params, 'openUrl');
    }
    if (this.config !== null && this.appId !== '') {
      this.appOrientation = ClientSettings.appOrientation(this.config!.installationId, this.appId);
      this.appDisplayMode = ClientSettings.appDisplayMode(this.config!.installationId, this.appId);
      this.displayMode = ClientSettings.resolveDisplayMode(this.config!.installationId, this.appId);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ClientSettings.applyOrientation(
        context,
        ClientSettings.resolveOrientation(this.config!.installationId, this.appId)
      );
    }
    this.pageGeneration += 1;
    this.beginRemoteSession(this.pageGeneration);
  }

  private async beginRemoteSession(generation: number): Promise<void> {
    const config = this.config;
    if (config === null || this.appId === '') {
      this.failureMessage = '远程页面地址无效';
      return;
    }
    // Whatever the mode, the device answers with the certificate it was issued:
    // the catalog already proved the PKCS#12 works with NetworkKit, and ArkWeb
    // needs a certificate-manager authUri when possible; PEM paths remain a sync
    // fallback.
    {
      try {
        this.readyIdentity = await CredentialStore.activeClientIdentity(config.installationId);
      } catch {
        if (generation !== this.pageGeneration) {
          return;
        }
        this.failureMessage = '设备身份不可用，请重新初始化';
        return;
      }
      try {
        this.readyAuthUri = await CredentialStore.webClientAuthUri(config.installationId);
      } catch {
        this.readyAuthUri = '';
      }
    } else {
      this.readyIdentity = null;
      this.readyAuthUri = '';
    }
    if (generation !== this.pageGeneration) {
      return;
    }
    this.identityReady = true;
    this.prepareNavigation(generation);
    if (this.controllerAttached && this.failureMessage === '') {
      this.startInitialNavigation();
    }
  }

  aboutToDisappear(): void {
    this.pageGeneration += 1;
    if (this.controllerAttached) {
      try {
        this.controller.stop();
      } catch {
        // The component can detach before aboutToDisappear is delivered.
      }
    }
    this.controllerAttached = false;
    this.webSource = '';
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ClientSettings.applyOrientation(context);
  }

  onBackPress(): boolean {
    this.showControls = !this.showControls;
    return true;
  }

  private handleEdgeTouch(event: TouchEvent): void {
    const points = event.changedTouches.length > 0 ? event.changedTouches : event.touches;
    if (points.length === 0) return;
    const x = points[0].displayX;
    if (event.type === TouchType.Down) {
      this.edgeTouchStartX = x;
      this.edgeTouchActive = true;
      return;
    }
    if (event.type === TouchType.Move && this.edgeTouchActive && x - this.edgeTouchStartX < -40) {
      this.edgeTouchActive = false;
      this.showControls = true;
      event.stopPropagation();
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.edgeTouchActive = false;
    }
  }

  private desktopUserAgent(): string {
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
      'Chrome/150.0.0.0 Safari/537.36';
  }

  private applyUserAgent(): void {
    try {
      this.controller.setCustomUserAgent(this.displayMode === 'desktop' ? this.desktopUserAgent() : '');
    } catch {
      // The controller is attached asynchronously; onControllerAttached applies it again.
    }
  }

  private setAppOrientation(value: string): void {
    const config = this.config;
    if (config === null) return;
    this.appOrientation = value;
    ClientSettings.setAppOrientation(config.installationId, this.appId, value);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ClientSettings.applyOrientation(context, ClientSettings.resolveOrientation(config.installationId, this.appId));
  }

  private setAppDisplayMode(value: string): void {
    const config = this.config;
    if (config === null) return;
    this.appDisplayMode = value;
    ClientSettings.setAppDisplayMode(config.installationId, this.appId, value);
    this.displayMode = ClientSettings.resolveDisplayMode(config.installationId, this.appId);
    this.applyUserAgent();
    this.showControls = false;
    this.refreshController();
  }

  private reloadPage(): void {
    this.showControls = false;
    this.failureMessage = '';
    if (!this.refreshController()) {
      this.failureMessage = '远程页面加载失败';
    }
  }

  private refreshController(): boolean {
    if (!this.controllerAttached) return false;
    try {
      this.controller.refresh(true);
      return true;
    } catch {
      return false;
    }
  }

  private configureRoutingCookie(config: ConnectionConfig): void {
    const cookie = WebIsolationPolicy.routingCookie(this.appId);
    const serialized = `${cookie.name}=${cookie.value}; Path=${cookie.path}; Secure; ` +
      'HttpOnly; SameSite=Strict; Max-Age=86400';
    webview.WebCookieManager.configCookieSync(config.gatewayOrigin, serialized, true, true);
  }

  private configureWebTrust(config: ConnectionConfig): void {
    const entry: UrlPermissionEntry = {
      scheme: 'https',
      host: config.gatewayHost,
      port: config.gatewayPort,
      path: ''
    };
    const entries: UrlPermissionEntry[] = [entry];
    const document: UrlPermissionDocument = { UrlPermissionList: entries };
    const trustList = JSON.stringify(document);
    this.controller.setUrlTrustList(trustList, false, false);
  }

  private startInitialNavigation(): void {
    const config = this.config;
    if (config === null || !this.controllerAttached || !this.identityReady ||
        this.failureMessage !== '') {
      return;
    }
    try {
      // Do not clearClientAuthenticationCache here: wiping it right before
      // navigation races ArkWeb's client-cert prompt and surfaces -110
      // ERR_SSL_CLIENT_AUTH_CERT_NEEDED when confirm is late.
      this.controller.clearSslCache();
      this.configureWebTrust(config);
      this.applyUserAgent();
      this.controller.loadUrl(config.mode === ConnectionMode.LAN ? config.appsUrl : this.openUrl);
    } catch {
      this.failureMessage = '远程页面加载失败';
    }
  }

  private async completeLanGatewayVerification(url: string, generation: number): Promise<void> {
    const config = this.config;
    if (config === null || config.mode !== ConnectionMode.LAN || !this.isVerifyingGateway ||
        url !== config.appsUrl || generation !== this.pageGeneration) {
      return;
    }
    try {
      const chain = await this.controller.getCertificate();
      if (chain.length === 0) {
        throw new Error('服务器没有提供证书');
      }
      const encoded = await chain[0].getEncoded();
      if (this.certificateFingerprint(encoded.data) !== config.gatewayFingerprint) {
        throw new Error('服务器证书指纹不匹配');
      }
      await cert.createX509CertChain(chain).validate({
        trustAnchors: [{ CACert: chain[chain.length - 1] }],
        policy: cert.ValidationPolicyType.VALIDATION_POLICY_TYPE_SSL,
        sslHostname: config.gatewayHost
      });
      if (generation !== this.pageGeneration || !this.isVerifyingGateway) return;
      this.configureRoutingCookie(config);
      this.isVerifyingGateway = false;
      this.webJavaScriptEnabled = true;
      // Updating Web.src after the component is attached does not reliably
      // navigate ArkWeb. Let the state update enable JavaScript first, then
      // explicitly navigate the already attached controller on the next turn.
      setTimeout(() => {
        if (generation !== this.pageGeneration || !this.controllerAttached ||
            this.failureMessage !== '') {
          return;
        }
        try {
          this.controller.loadUrl(this.openUrl);
        } catch {
          this.failureMessage = '远程页面加载失败';
        }
      }, 0);
    } catch {
      if (generation !== this.pageGeneration || !this.isVerifyingGateway) return;
      this.isVerifyingGateway = false;
      this.failureMessage = '服务器证书验证失败，已阻止连接';
      try {
        this.controller.stop();
      } catch {
        // The failure state may detach the Web component immediately.
      }
    }
  }

  prepareNavigation(generation: number): void {
    const config = this.config;
    if (config === null || !config.isGatewayUrl(this.openUrl) || this.appId === '') {
      this.failureMessage = '远程页面地址无效';
      return;
    }
    try {
      // ArkWeb exposes one normal and one incognito data store for the whole app,
      // not a per-Web profile. Clear the incognito store before changing apps so
      // one remote application cannot inherit another application's web data.
      webview.WebCookieManager.clearAllCookiesSync(true);
      webview.WebStorage.deleteAllData(true);
      if (this.pageGeneration === generation) {
        if (config.mode === ConnectionMode.LAN) {
          // ArkWeb only reports certificates that fail system trust. Probe the
          // gateway without cookies or JavaScript first so a system-trusted but
          // unpinned certificate never receives app routing state.
          this.isVerifyingGateway = true;
          this.webJavaScriptEnabled = false;
          this.webSource = '';
        } else {
          this.configureRoutingCookie(config);
          this.isVerifyingGateway = false;
          this.webJavaScriptEnabled = true;
          this.webSource = '';
        }
      }
    } catch {
      this.failureMessage = '网页环境初始化失败';
    }
  }

  retry(): void {
    this.failureMessage = '';
    this.webSource = '';
    this.readyIdentity = null;
    this.readyAuthUri = '';
    this.identityReady = false;
    this.pageGeneration += 1;
    this.beginRemoteSession(this.pageGeneration);
  }

  private certificateFingerprint(encoded: Uint8Array): string {
    const digest = cryptoFramework.createMd('SHA256');
    digest.updateSync({ data: encoded });
    const output = digest.digestSync();
    let value = '';
    for (let index = 0; index < output.data.length; index++) {
      value += output.data[index].toString(16).padStart(2, '0');
    }
    return value;
  }

  private isCurrentConnection(generation: number, config: ConnectionConfig): boolean {
    const current = this.config;
    return generation === this.pageGeneration && this.controllerAttached && current !== null &&
      current.installationId === config.installationId &&
      current.gatewayOrigin === config.gatewayOrigin && current.mode === config.mode;
  }

  private confirmClientIdentity(
    handler: ClientAuthenticationHandler,
    host: string,
    port: number
  ): void {
    const config = this.config;
    if (config === null || !this.isGatewayClientAuthEndpoint(config, host, port)) {
      handler.cancel();
      return;
    }
    // Must confirm synchronously. Awaiting certificate-manager install here
    // races ArkWeb and surfaces -110 ERR_SSL_CLIENT_AUTH_CERT_NEEDED.
    const authUri = this.readyAuthUri;
    if (authUri !== '') {
      try {
        handler.confirm(authUri, CredentialType.CREDENTIAL_APP);
        return;
      } catch {
        try {
          handler.confirm(authUri);
          return;
        } catch {
          // Fall through to PEM paths.
        }
      }
    }
    const identity = this.readyIdentity;
    if (identity !== null) {
      try {
        handler.confirm(identity.privateKeyPath, identity.certificateChainPath);
        return;
      } catch {
        try {
          handler.ignore();
        } catch {
          // Handler may already be expired.
        }
        this.failureMessage = '无法向网页内核提供客户端证书';
        return;
      }
    }
    try {
      handler.ignore();
    } catch {
      // Handler may already be expired.
    }
    this.failureMessage = this.readyAuthUri === '' && this.readyIdentity === null
      ? '客户端证书尚未就绪'
      : `无法匹配网关客户端证书请求（${host}:${port}）`;
  }

  private isGatewayClientAuthEndpoint(
    config: ConnectionConfig, host: string, port: number
  ): boolean {
    if (config.isGatewayEndpoint(host, port)) {
      return true;
    }
    // Some ArkWeb builds report default HTTPS as 0/-1 instead of 443.
    return host.toLowerCase() === config.gatewayHost.toLowerCase() &&
      (port === config.gatewayPort ||
        (config.gatewayPort === 443 && (port === 0 || port === -1 || port === 443)));
  }

  private async selectFiles(result: FileSelectorResult, maximum: number): Promise<void> {
    const generation = this.pageGeneration;
    let completed = false;
    const complete = (files: string[]): void => {
      if (completed || generation !== this.pageGeneration) return;
      completed = true;
      try {
        result.handleFileList(files);
      } catch {
        // The Web callback can expire while the system picker is open.
      }
    };
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = maximum;
      const files = await new picker.DocumentViewPicker(context).select(options);
      complete(files);
    } catch {
      complete([]);
    }
  }

  private async grantMediaPermission(request: PermissionRequest): Promise<void> {
    const config = this.config;
    const generation = this.pageGeneration;
    const resources = request.getAccessibleResource();
    const supported = resources.filter((resource: string) =>
      resource === ProtectedResourceType.VIDEO_CAPTURE ||
      resource === ProtectedResourceType.AUDIO_CAPTURE
    );
    if (config === null || !config.isGatewayUrl(request.getOrigin()) ||
        supported.length !== resources.length || supported.length === 0) {
      this.denyMediaPermission(request);
      return;
    }

    const permissions: Permissions[] = [];
    if (supported.includes(ProtectedResourceType.VIDEO_CAPTURE)) {
      permissions.push('ohos.permission.CAMERA');
    }
    if (supported.includes(ProtectedResourceType.AUDIO_CAPTURE)) {
      permissions.push('ohos.permission.MICROPHONE');
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, permissions);
      if (!this.isCurrentConnection(generation, config)) {
        this.denyMediaPermission(request);
      } else if (result.authResults.every((status: number) => status === 0)) {
        try {
          request.grant(supported);
        } catch {
          this.denyMediaPermission(request);
        }
      } else {
        this.denyMediaPermission(request);
      }
    } catch {
      this.denyMediaPermission(request);
    }
  }

  private denyMediaPermission(request: PermissionRequest): void {
    try {
      request.deny();
    } catch {
      // The Web callback can expire while the system permission dialog is open.
    }
  }

  private openExternal(url: string): void {
    try {
      const parsed = new uri.URI(url);
      if (!['https', 'http', 'mailto', 'tel'].includes(parsed.scheme)) {
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: url,
        entities: ['entity.system.browsable']
      }).catch((): void => {
        this.getUIContext().getPromptAction().showToast({ message: '无法打开外部链接' });
      });
    } catch {
      // Invalid external links stay blocked.
    }
  }

  private suggestedFileName(url: string, contentDisposition: string): string {
    const match = /filename\*?=(?:UTF-8'')?["']?([^"';]+)["']?/i.exec(contentDisposition);
    let value = match !== null ? decodeURIComponent(match[1]) : '';
    if (value === '') {
      try {
        const path = new uri.URI(url).path;
        value = decodeURIComponent(path.substring(path.lastIndexOf('/') + 1));
      } catch {
        value = '';
      }
    }
    value = value.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').trim();
    return value === '' || value === '.' || value === '..'
      ? 'download'
      : value.substring(0, Math.min(value.length, 120));
  }

  private async downloadFile(url: string, contentDisposition: string): Promise<void> {
    const config = this.config;
    const generation = this.pageGeneration;
    if (config === null || !config.isGatewayUrl(url)) {
      this.downloadMessage = '已阻止连接范围外的下载';
      return;
    }
    if (!this.isCurrentConnection(generation, config)) return;
    this.downloadMessage = '正在下载…';
    const request = http.createHttp();
    try {
      const cookie = webview.WebCookieManager.fetchCookieSync(config.gatewayOrigin, true);
      const headers: Record<string, string> = { 'Accept': '*/*', 'Cookie': cookie };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 60000,
        usingCache: false,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxLimit: 100 * 1024 * 1024,
        maxRedirects: 0
      };
      const identity = await CredentialStore.activeClientIdentity(config.installationId);
      options.clientCert = {
        certPath: identity.certPath,
        certType: http.CertType.P12,
        keyPath: identity.keyPath,
        keyPassword: identity.password
      };
      if (config.mode === ConnectionMode.LAN) {
        options.certificatePinning = {
          publicKeyHash: config.gatewayPublicKeyPin,
          hashAlgorithm: 'SHA-256'
        };
      }
      if (!this.isCurrentConnection(generation, config)) return;
      const response = await request.request(url, options);
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        throw new Error(`下载服务返回 ${response.responseCode}`);
      }
      if (!this.isCurrentConnection(generation, config)) return;

      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [this.suggestedFileName(url, contentDisposition)];
      const targets = await new picker.DocumentViewPicker(context).save(saveOptions);
      if (targets.length !== 1) {
        throw new Error('没有选择保存位置');
      }
      if (!this.isCurrentConnection(generation, config)) return;
      const file = fileIo.openSync(targets[0], 0o2 | 0o100 | 0o1000);
      try {
        fileIo.writeSync(file.fd, response.result);
      } finally {
        fileIo.closeSync(file);
      }
      if (this.isCurrentConnection(generation, config)) {
        this.downloadMessage = '下载已保存';
      }
    } catch (error) {
      if (this.isCurrentConnection(generation, config)) {
        this.downloadMessage = error instanceof Error ? error.message : '下载失败';
      }
    } finally {
      request.destroy();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.failureMessage !== '') {
        Column() {
          Text('⚠').fontSize(40)
          Text('远程页面没有成功打开').fontSize(18).fontWeight(FontWeight.Bold).margin({ top: 16 })
          Text(this.failureMessage).fontSize(14).fontColor('#999999').margin({ top: 8 })
          Row() {
            Button('重试').onClick(() => this.retry())
            Button('返回目录').onClick(() => router.back())
          }
          .margin({ top: 24 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else {
        Stack({ alignContent: Alignment.Top }) {
          Web({ src: this.webSource, controller: this.controller, incognitoMode: true })
            .width('100%')
            .height('100%')
            .javaScriptAccess(this.webJavaScriptEnabled)
            .domStorageAccess(this.webJavaScriptEnabled)
            .cacheMode(CacheMode.Online)
            .fileAccess(false)
            .onlineImageAccess(true)
            .mixedMode(MixedMode.None)
            .multiWindowAccess(false)
            .onControllerAttached(() => {
              this.controllerAttached = true;
              this.startInitialNavigation();
            })
            .onPageEnd((event) => {
              this.completeLanGatewayVerification(event.url, this.pageGeneration);
            })
            .onOverrideUrlLoading((request) => {
              const target = request.getRequestUrl();
              if (this.config?.isGatewayUrl(target) === true) {
                return false;
              }
              if (request.isMainFrame() && request.isRequestGesture()) {
                this.openExternal(target);
              }
              return true;
            })
            .onShowFileSelector((event) => {
              const maximum = event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode
                ? 100
                : 1;
              this.selectFiles(event.result, maximum);
              return true;
            })
            .onPermissionRequest((event) => {
              this.grantMediaPermission(event.request);
            })
            .onClientAuthenticationRequest((event) => {
              this.confirmClientIdentity(event.handler, event.host, event.port);
            })
            .onSslErrorEvent((event) => {
              const chain = event.certChainData ?? [];
              const config = this.config;
              if (config !== null && config.mode === ConnectionMode.LAN &&
                  event.error === SslError.Untrusted && config.isGatewayUrl(event.url) && chain.length > 0 &&
                  this.certificateFingerprint(chain[0]) === config.gatewayFingerprint) {
                event.handler.handleConfirm();
              } else {
                event.handler.handleCancel();
                this.failureMessage = '服务器证书验证失败，已阻止连接';
              }
            })
            .onDownloadStart((event) => {
              this.downloadFile(event.url, event.contentDisposition);
            })
            .onErrorReceive((event) => {
              if (event.request.isMainFrame() && event.error) {
                const code = event.error.getErrorCode();
                const info = event.error.getErrorInfo();
                this.failureMessage = code === -110 || info.indexOf('CLIENT_AUTH') >= 0
                  ? `${code}: 需要客户端证书（mTLS），请重试或重新初始化`
                  : `${code}: ${info}`;
              }
            })
            .onHttpErrorReceive((event) => {
              if (event.request.isMainFrame()) {
                this.failureMessage = `网页服务返回 ${event.response.getResponseCode()}`;
              }
            })
            .onRenderExited(() => {
              this.failureMessage = '网页内核异常退出';
            })

          if (this.isVerifyingGateway) {
            Column() {
              LoadingProgress().width(32).height(32).color($r('app.color.primary'))
              Text('正在验证服务器…')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 10 })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.page_background'))
          }

          if (this.downloadMessage !== '') {
            Text(this.downloadMessage)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .backgroundColor('#99000000')
              .borderRadius(12)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ top: 12 })
              .onClick(() => { this.downloadMessage = ''; })
          }

          if (!this.showControls) {
            Row() {
              Blank().hitTestBehavior(HitTestMode.Transparent)
              Column()
                .width(24)
                .height('100%')
                .hitTestBehavior(HitTestMode.Block)
                .onTouch((event: TouchEvent) => { this.handleEdgeTouch(event); })
            }
            .width('100%')
            .height('100%')
            .hitTestBehavior(HitTestMode.Transparent)
          }

        }
        .width('100%').height('100%')
      }

      if (this.showControls) {
        Column() {
          Blank().hitTestBehavior(HitTestMode.Transparent)
          Column() {
            Row() {
              Text(this.appName).fontSize(18).fontWeight(FontWeight.Medium).layoutWeight(1)
              Button('完成').type(ButtonType.Capsule).onClick(() => { this.showControls = false; })
            }
            .width('100%')

            Text('屏幕方向').fontSize(13).fontColor($r('app.color.text_secondary'))
              .width('100%').margin({ top: 14, bottom: 6 })
            Row() {
              Button('跟随全局')
                .fontSize(12)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .fontColor(this.appOrientation === 'global'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.appOrientation === 'global'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.appOrientation === 'global'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => this.setAppOrientation('global'))
              Button('跟随系统')
                .fontSize(12)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .margin({ left: 6 })
                .fontColor(this.appOrientation === 'system'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.appOrientation === 'system'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.appOrientation === 'system'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => this.setAppOrientation('system'))
            }
            .width('100%')

            Row() {
              Button('竖屏')
                .fontSize(12)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .fontColor(this.appOrientation === 'portrait'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.appOrientation === 'portrait'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.appOrientation === 'portrait'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => this.setAppOrientation('portrait'))
              Button('横屏')
                .fontSize(12)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .margin({ left: 6 })
                .fontColor(this.appOrientation === 'landscape'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.appOrientation === 'landscape'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.appOrientation === 'landscape'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => this.setAppOrientation('landscape'))
            }
            .width('100%').margin({ top: 6 })

            Text('显示模式').fontSize(13).fontColor($r('app.color.text_secondary'))
              .width('100%').margin({ top: 14, bottom: 6 })
            Row() {
              Button('跟随全局')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .fontColor(this.appDisplayMode === 'global'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.appDisplayMode === 'global'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.appDisplayMode === 'global'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => this.setAppDisplayMode('global'))
              Button('手机')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .margin({ left: 6 })
                .fontColor(this.appDisplayMode === 'phone'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.appDisplayMode === 'phone'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.appDisplayMode === 'phone'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => this.setAppDisplayMode('phone'))
              Button('电脑')
                .fontSize(13)
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(42)
                .margin({ left: 6 })
                .fontColor(this.appDisplayMode === 'desktop'
                  ? $r('app.color.on_primary_container') : $r('app.color.text_primary'))
                .backgroundColor(this.appDisplayMode === 'desktop'
                  ? $r('app.color.primary_container') : $r('app.color.surface_card'))
                .border({ width: 1, color: this.appDisplayMode === 'desktop'
                  ? $r('app.color.primary') : $r('app.color.outline') })
                .borderRadius(10)
                .onClick(() => this.setAppDisplayMode('desktop'))
            }
            .width('100%')

            Row() {
              Button('重新加载页面').layoutWeight(1).onClick(() => {
                if (this.failureMessage !== '') {
                  this.showControls = false;
                  this.retry();
                } else {
                  this.reloadPage();
                }
              })
              Button('返回目录').layoutWeight(1).onClick(() => router.back())
            }
            .width('100%').margin({ top: 18 })
          }
          .width('100%')
          .padding(18)
          .backgroundColor($r('app.color.surface_card'))
          .borderRadius({ topLeft: 22, topRight: 22 })
          .shadow({ radius: 24, color: '#44000000', offsetY: -4 })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
  }
}
