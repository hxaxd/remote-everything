import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { ConnectionConfig, ConnectionMode } from '../../core/models/ConnectionConfig';
import { CredentialStore } from '../../core/security/CredentialStore';
import { WebIsolationPolicy } from '../../core/web/WebIsolationPolicy';
import { router } from '@kit.ArkUI';

interface WebClientAuthenticationHandler {
  confirm(privateKeyPath: string, certificateChainPath: string): void;
  cancel(): void;
}

interface WebFileSelectorResult {
  handleFileList(files: Array<string>): void;
}

interface WebPermissionRequest {
  getOrigin(): string;
  getAccessibleResource(): Array<string>;
  grant(resources: Array<string>): void;
  deny(): void;
}

@Entry
@Component
export struct RemoteWebPage {
  @State config: ConnectionConfig | null = null;
  @State appId: string = '';
  @State appName: string = '';
  @State openUrl: string = '';
  @State webSource: string = '';
  @State displayMode: string = 'mobile';
  @State failureMessage: string = '';
  @State downloadMessage: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private pageGeneration: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params !== null) {
      this.config = params['config'] as ConnectionConfig;
      this.appId = (params['appId'] as string) ?? '';
      this.appName = (params['appName'] as string) ?? '';
      this.openUrl = (params['openUrl'] as string) ?? '';
    }
    this.pageGeneration += 1;
    this.prepareNavigation(this.pageGeneration);
  }

  aboutToDisappear(): void {
    this.pageGeneration += 1;
    this.controller.stop();
    this.webSource = '';
  }

  prepareNavigation(generation: number): void {
    const config = this.config;
    if (config === null || !config.isGatewayUrl(this.openUrl) || this.appId === '') {
      this.failureMessage = '远程页面地址无效';
      return;
    }
    try {
      const cookie = WebIsolationPolicy.routingCookie(this.appId);
      const serialized = `${cookie.name}=${cookie.value}; Path=${cookie.path}; Secure; ` +
        'HttpOnly; SameSite=Strict; Max-Age=86400';
      webview.WebCookieManager.configCookieSync(config.gatewayOrigin, serialized, true, true);
      if (this.pageGeneration === generation) {
        this.webSource = this.openUrl;
      }
    } catch {
      this.failureMessage = '网页环境初始化失败';
    }
  }

  retry(): void {
    this.failureMessage = '';
    this.webSource = '';
    this.pageGeneration += 1;
    this.prepareNavigation(this.pageGeneration);
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

  private async confirmClientIdentity(
    handler: WebClientAuthenticationHandler,
    host: string,
    port: number
  ): Promise<void> {
    const config = this.config;
    if (config === null || config.mode !== ConnectionMode.PUBLIC ||
        !config.isGatewayEndpoint(host, port)) {
      handler.cancel();
      return;
    }
    try {
      const identity = await CredentialStore.activeClientIdentity(config.installationId);
      handler.confirm(identity.privateKeyPath, identity.certificateChainPath);
    } catch {
      handler.cancel();
      this.failureMessage = '设备身份不可用，请重新初始化';
    }
  }

  private async selectFiles(result: WebFileSelectorResult, maximum: number): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = maximum;
      const files = await new picker.DocumentViewPicker(context).select(options);
      result.handleFileList(files);
    } catch {
      result.handleFileList([]);
    }
  }

  private async grantMediaPermission(request: WebPermissionRequest): Promise<void> {
    const config = this.config;
    const resources = request.getAccessibleResource();
    const supported = resources.filter((resource: string) =>
      resource === ProtectedResourceType.VIDEO_CAPTURE ||
      resource === ProtectedResourceType.AUDIO_CAPTURE
    );
    if (config === null || !config.isGatewayUrl(request.getOrigin()) ||
        supported.length !== resources.length || supported.length === 0) {
      request.deny();
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
      const context = getContext(this) as common.UIAbilityContext;
      const result = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, permissions);
      if (result.authResults.every((status: number) => status === 0)) {
        request.grant(supported);
      } else {
        request.deny();
      }
    } catch {
      request.deny();
    }
  }

  private openExternal(url: string): void {
    try {
      const parsed = new URL(url);
      if (!['https:', 'http:', 'mailto:', 'tel:'].includes(parsed.protocol)) {
        return;
      }
      const context = getContext(this) as common.UIAbilityContext;
      context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: url,
        entities: ['entity.system.browsable']
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
        const path = new URL(url).pathname;
        value = decodeURIComponent(path.substring(path.lastIndexOf('/') + 1));
      } catch {
        value = '';
      }
    }
    value = value.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').trim();
    return value === '' ? 'download' : value.substring(0, Math.min(value.length, 120));
  }

  private async downloadFile(url: string, contentDisposition: string): Promise<void> {
    const config = this.config;
    if (config === null || !config.isGatewayUrl(url)) {
      this.failureMessage = '已阻止连接范围外的下载';
      return;
    }
    this.downloadMessage = '正在下载…';
    const request = http.createHttp();
    try {
      const cookie = webview.WebCookieManager.fetchCookieSync(config.gatewayOrigin, true);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'Accept': '*/*', 'Cookie': cookie },
        connectTimeout: 10000,
        readTimeout: 60000,
        usingCache: false,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxLimit: 100 * 1024 * 1024
      };
      if (config.mode === ConnectionMode.PUBLIC) {
        const identity = await CredentialStore.activeClientIdentity(config.installationId);
        options.clientCert = {
          certPath: identity.certPath,
          certType: http.CertType.P12,
          keyPath: identity.keyPath,
          keyPassword: identity.password
        };
      } else {
        options.certificatePinning = {
          publicKeyHash: config.gatewayPublicKeyPin,
          hashAlgorithm: 'SHA-256'
        };
      }
      const response = await request.request(url, options);
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        throw new Error(`下载服务返回 ${response.responseCode}`);
      }

      const context = getContext(this) as common.UIAbilityContext;
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [this.suggestedFileName(url, contentDisposition)];
      const targets = await new picker.DocumentViewPicker(context).save(saveOptions);
      if (targets.length !== 1) {
        throw new Error('没有选择保存位置');
      }
      const file = fileIo.openSync(targets[0], 0o2 | 0o100 | 0o1000);
      try {
        fileIo.writeSync(file.fd, response.result);
      } finally {
        fileIo.closeSync(file);
      }
      this.downloadMessage = '下载已保存';
    } catch (error) {
      this.downloadMessage = error instanceof Error ? error.message : '下载失败';
    } finally {
      request.destroy();
    }
  }

  build() {
    Column() {
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
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(false)
            .onlineImageAccess(true)
            .mixedMode(MixedMode.None)
            .multiWindowAccess(false)
            .userAgent(this.displayMode === 'desktop'
              ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/150.0.0.0 Safari/537.36'
              : '')
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
                ? 20
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
            .onSslErrorEventReceive((event) => {
              const chain = event.certChainData ?? [];
              const config = this.config;
              if (config !== null && config.mode === ConnectionMode.LAN && chain.length > 0 &&
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
              if (event.error) {
                this.failureMessage = `${event.error.getErrorCode()}: ${event.error.getErrorInfo()}`;
              }
            })
            .onRenderExited(() => {
              this.failureMessage = '网页内核异常退出';
            })

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
        }
        .width('100%').height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .title(this.appName)
    .onBackPress(() => {
      router.back();
      return true;
    })
  }
}
