// What a page's "download" becomes here.
//
// The download runs through the web kernel's own download manager, which is also
// what answers the gateway's client-certificate challenge on the way: a file behind
// an authenticated origin is fetched by the same stack that fetched the page, so
// there is nothing to hand over and nothing to re-authenticate.
//
// It lands in this app's own sandbox first — the one directory it may write to
// without asking — and is then offered to the system's save dialog, where the person
// decides where it really goes. A download that cannot be offered still exists in the
// sandbox, and the toast says so rather than the file vanishing.

import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { MessageKeys } from '../../core/model/MessageKeys';
import { Strings } from '../i18n/Strings';
import { model } from '../AppModel';

export class WebDownloads {
  private static delegate: webview.WebDownloadDelegate | null = null;
  private static context: common.UIAbilityContext | null = null;
  private static installed: boolean = false;
  /** Where each download in flight was told to write, by its guid. */
  private static targets: Map<string, string> = new Map();
  private static items: Map<string, webview.WebDownloadItem> = new Map();
  private static accepting: boolean = false;
  private static generation: number = 0;
  private static sessionDelegate: webview.WebDownloadDelegate | null = null;

  static allowSession(): void {
    WebDownloads.generation += 1;
    WebDownloads.accepting = true;
  }

  static stopSession(): void {
    WebDownloads.accepting = false;
    WebDownloads.generation += 1;
    for (const item of WebDownloads.items.values()) {
      item.cancel();
    }
    WebDownloads.items.clear();
    WebDownloads.targets.clear();
  }

  /** Called once, from the ability, with the engine already initialised. */
  static install(context: common.UIAbilityContext): void {
    WebDownloads.context = context;
    if (WebDownloads.installed) {
      return;
    }
    WebDownloads.installed = true;
    const delegate: webview.WebDownloadDelegate = new webview.WebDownloadDelegate();
    delegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      item.cancel();
    });
    try {
      webview.WebDownloadManager.setDownloadDelegate(delegate);
      WebDownloads.delegate = delegate;
    } catch (error) {
      WebDownloads.installed = false;
    }
  }

  /** Each controller captures its lease, so late callbacks cannot join the next application. */
  static bind(controller: webview.WebviewController): void {
    const generation: number = WebDownloads.generation;
    const delegate: webview.WebDownloadDelegate = new webview.WebDownloadDelegate();
    delegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      if (!WebDownloads.accepting || generation !== WebDownloads.generation) {
        item.cancel();
        return;
      }
      WebDownloads.begin(item);
    });
    delegate.onDownloadFinish((item: webview.WebDownloadItem) => {
      if (generation === WebDownloads.generation) { WebDownloads.finish(item); }
    });
    delegate.onDownloadFailed((item: webview.WebDownloadItem) => {
      if (generation !== WebDownloads.generation) { return; }
      WebDownloads.items.delete(item.getGuid());
      WebDownloads.targets.delete(item.getGuid());
      if (WebDownloads.accepting) { model.showToast(MessageKeys.WEB_DOWNLOAD_FAILED); }
    });
    controller.setDownloadDelegate(delegate);
    WebDownloads.sessionDelegate = delegate;
  }

  /** A download may start only into a file this client has made room for. */
  private static begin(item: webview.WebDownloadItem): void {
    const context: common.UIAbilityContext | null = WebDownloads.context;
    if (context === null || !WebDownloads.accepting) {
      item.cancel();
      return;
    }
    try {
      const directory: string = `${context.filesDir}/downloads`;
      if (!fs.accessSync(directory)) {
        fs.mkdirSync(directory, true);
      }
      const path: string = `${directory}/${WebDownloads.sanitise(item.getSuggestedFileName())}`;
      WebDownloads.targets.set(item.getGuid(), path);
      WebDownloads.items.set(item.getGuid(), item);
      item.start(path);
    } catch (error) {
      item.cancel();
      model.showToast(MessageKeys.WEB_DOWNLOAD_FAILED);
    }
  }

  private static finish(item: webview.WebDownloadItem): void {
    WebDownloads.items.delete(item.getGuid());
    const path: string | undefined = WebDownloads.targets.get(item.getGuid());
    const name: string = WebDownloads.sanitise(item.getSuggestedFileName());
    WebDownloads.targets.delete(item.getGuid());
    // The file has a name and a place, and a toast that says only "done" is a
    // toast that leaves the person to go looking for both.
    if (path === undefined) {
      return;
    }
    model.showToastText(Strings.text1(MessageKeys.WEB_DOWNLOAD_SAVED,
      `${Strings.text(MessageKeys.WEB_DOWNLOADS)}/${name}`));
    WebDownloads.offer(path, name);
  }

  /**
   * The system's save dialog, so the file can leave the sandbox. A person who
   * cancels it keeps the copy that is already there.
   */
  private static offer(path: string, name: string): void {
    const context: common.UIAbilityContext | null = WebDownloads.context;
    if (context === null) {
      return;
    }
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [name];
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    documentPicker.save(options).then((uris: string[]) => {
      if (uris.length === 0) {
        return;
      }
      WebDownloads.copy(path, uris[0]);
    }).catch((error: Object) => {
      // Cancelling the dialog is not a failure: the download itself is done.
    });
  }

  private static copy(from: string, to: string): void {
    let source: fs.File | null = null;
    let target: fs.File | null = null;
    try {
      source = fs.openSync(from, fs.OpenMode.READ_ONLY);
      target = fs.openSync(to, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.copyFileSync(source.fd, target.fd);
    } catch (error) {
      model.showToast(MessageKeys.WEB_DOWNLOAD_FAILED);
    } finally {
      WebDownloads.closeQuietly(source);
      WebDownloads.closeQuietly(target);
    }
  }

  private static closeQuietly(file: fs.File | null): void {
    if (file === null) {
      return;
    }
    try {
      fs.closeSync(file);
    } catch (error) {
      // A descriptor that cannot be closed is one the system has already taken back.
    }
  }

  /** A name is a name, not a path: nothing the page says may climb out of the directory. */
  private static sanitise(name: string): string {
    let cleaned: string = '';
    for (let index: number = 0; index < name.length; index += 1) {
      const character: string = name.charAt(index);
      cleaned += (character === '/' || character === '\\' || character === ':' || character === '*'
        || character === '?' || character === '"' || character === '<' || character === '>'
        || character === '|') ? '_' : character;
    }
    cleaned = cleaned.trim();
    if (cleaned === '') {
      return 'download';
    }
    return cleaned.length > 120 ? cleaned.substring(cleaned.length - 120) : cleaned;
  }
}
