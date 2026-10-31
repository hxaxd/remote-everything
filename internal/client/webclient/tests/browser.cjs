// Run with PLAYWRIGHT_MODULE pointing to an installed Playwright package.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const root = path.resolve(__dirname, '../embedded');
const output = path.resolve(process.env.WEB_TEST_OUTPUT || 'dist/web-redesign');
const nodeA = 'a'.repeat(64), nodeB = 'b'.repeat(64);
const invitation = 'a'.repeat(43);
const apps = [
  { id:'dsh', name:'DSH', description:'DeepSeek Harness 网页控制台', icon:'DS', accent:'#4d6bfe', launch_fragment:'', computer_connected:true, enabled:true, running:true, code:'ready' },
  { id:'sillytavern', name:'SillyTavern', description:'角色对话与故事创作', icon:'ST', accent:'#a0795b', launch_fragment:'#/home', computer_connected:true, enabled:false, running:false, code:'stopped' },
];
let browser, server;
(async () => {
  await fs.mkdir(output, {recursive:true});
  server = http.createServer(async (req, res) => {
    const file = new URL(req.url, 'http://localhost').pathname.replace(/^\/web\/?/, '') || 'index.html';
    if (!['index.html','app.js','style.css','icon.svg'].includes(file)) { res.writeHead(404); res.end(); return; }
    const types = {'.html':'text/html', '.js':'text/javascript', '.css':'text/css', '.svg':'image/svg+xml'};
    res.setHeader('Content-Type', types[path.extname(file)]); res.end(await fs.readFile(path.join(root,file)));
  });
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({channel:process.env.BROWSER_CHANNEL || 'msedge', headless:true});
  const context = await browser.newContext({viewport:{width:1365,height:900}, colorScheme:'light',
    userAgent:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'});
  const page = await context.newPage();
  await page.addInitScript(() => {
    window.requestBudgets = [];
    const original = window.setTimeout;
    window.setTimeout = (callback,ms,...args) => { if (ms === 10000 || ms === 30000) window.requestBudgets.push(ms); return original(callback,ms,...args); };
  });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  let pending = false, failAction = false, failCatalog = false, offline = false, unauthorized = false, noNodes = false, delayA = false, empty = false, failLock = false;
  const requests = [];
  let nodeUnauthorized = false, invalidCatalog = false, invalidEncoding = false, stopFailure = false, statusOnly = false;
  let releaseOpen = null, holdOpen = null;
  await context.route('**/__remote_everything**', async route => {
    const request = route.request(); const url = new URL(request.url()); const headers = request.headers();
    requests.push({path:url.pathname, node:headers['x-remote-everything-node'], appearance:headers['x-remote-everything-web-appearance']});
    const fulfill = (data,status=200) => route.fulfill({status,contentType:'application/json',body:JSON.stringify(data)});
    if (url.pathname.endsWith('_pair')) {
      assert.equal(headers.authorization, `Invitation ${invitation}`);
      assert.equal(request.postDataJSON().device_name, 'Windows 浏览器');
      return fulfill({ok:true,session_token:'1'.repeat(64),unlock_token:'e'.repeat(64),revoke_token:'f'.repeat(64),fingerprint:'c'.repeat(64),device_name:'Windows 浏览器',status:pending?'pending':'approved',nodes:[nodeA,nodeB],expires_at:'2026-10-19T12:00:00Z'});
    }
    if (url.pathname.endsWith('_lock')) {
      assert.equal(headers['x-remote-everything-web-revoke'], 'f'.repeat(64));
      return failLock ? fulfill({ok:false,code:'session_revoke_failed'},500) : fulfill({ok:true});
    }
    if (url.pathname.endsWith('_unlock') && !unauthorized) {
      assert.equal(headers['x-remote-everything-web-unlock'], 'e'.repeat(64));
      return fulfill({ok:true,session_token:'2'.repeat(64),fingerprint:'c'.repeat(64),device_name:'Windows 浏览器',status:pending?'pending':'approved',nodes:null,expires_at:'2026-10-19T12:00:00Z'});
    }
    if (unauthorized) return fulfill({ok:false,code:'unauthorized'},401);
    if (url.pathname.endsWith('_activate')) return pending ? fulfill({ok:false,code:'approval_pending'},202) : fulfill({ok:true,status:'approved',device_name:'Windows 浏览器',fingerprint:'c'.repeat(64),nodes:[nodeA,nodeB]});
    if (url.pathname.endsWith('_logout')) return fulfill({ok:true});
    if (url.pathname.endsWith('/nodes')) {
      assert.equal(headers['x-remote-everything-node'], undefined);
      return fulfill({ok:true,nodes:noNodes?[]:[{id:nodeA,name:'Windows-PC',link:'tunnel'},{id:nodeB,name:'书房电脑',link:'local'}]});
    }
    if (url.pathname.endsWith('/apps')) {
      if (nodeUnauthorized && headers['x-remote-everything-node'] === nodeB) return fulfill({ok:false,code:'unauthorized'},401);
      if (invalidCatalog) return fulfill({ok:true,computer_connected:true,code:'ready',apps:[{...apps[0],code:'unknown'}]});
      if (invalidEncoding) return route.fulfill({status:200,contentType:'application/json',body:Buffer.from([0x7b,0xff,0x7d])});
      if (delayA && headers['x-remote-everything-node'] === nodeA) await new Promise(resolve=>setTimeout(resolve,350));
      if (failCatalog) return fulfill({ok:false,code:'server_busy'},503);
      return fulfill({ok:true,computer_connected:!offline && headers['x-remote-everything-node'] !== nodeB,code:!offline && headers['x-remote-everything-node'] !== nodeB ? 'ready' : 'computer_offline',apps:empty || offline || headers['x-remote-everything-node'] === nodeB ? [] : apps});
    }
    if (url.pathname.includes('/open/')) {
      assert.equal(headers.accept,'application/json'); assert.equal(headers['x-remote-everything-node'],nodeA);
      if (holdOpen) await holdOpen;
      return fulfill({ok:true,location:'https://application.example.test/?_reticket=test-once'});
    }
    if (/\/(start|stop|status)$/.test(url.pathname)) {
      if (stopFailure && url.pathname.endsWith('/stop')) return fulfill({ok:false,action:'stop',computer_connected:true,enabled:true,running:true,code:'state_update_failed',error_code:'stop_command_failed'});
      if (failAction) return fulfill({ok:false,code:'server_busy'},503);
      const id = url.pathname.split('/').at(-2); const app = apps.find(app=>app.id===id);
      if (!url.pathname.endsWith('/status')) { app.running = url.pathname.endsWith('/start'); app.enabled = app.running; app.code = app.running ? 'ready' : 'stopped'; }
      if (statusOnly) {
        if (url.pathname.endsWith('/start')) { app.running = false; app.code = 'starting'; }
        if (url.pathname.endsWith('/status')) { app.running = true; app.enabled = true; app.code = 'ready'; }
      }
      return fulfill({ok:true,action:url.pathname.split('/').at(-1),computer_connected:true,enabled:app.enabled,running:app.running,code:app.code,...(statusOnly?{}:{app})});
    }
    throw new Error('Unexpected API request: '+url.pathname);
  });
  await context.route('https://application.example.test/**', route=>route.fulfill({contentType:'text/html',body:'<title>Application</title><h1>Application</h1>'}));
  const visible = async selector => { await page.locator(selector).waitFor({state:'visible'}); };
  const checkText = async (selector, text) => { await page.waitForFunction(({selector,text})=>document.querySelector(selector)?.textContent.includes(text),{selector,text}); };
  const pair = async () => {
    await page.locator('#pair-invitation').fill(invitation); await page.locator('#pair-passphrase').fill('test-password'); await page.locator('#pair-passphrase-confirm').fill('test-password'); await page.locator('#btn-start-pair').click();
  };
  await page.goto(origin+'/web/'); await visible('#view-pair');
  await page.screenshot({path:path.join(output,'pair-desktop.png')});
  await page.locator('#pair-invitation').fill('invalid'); await page.locator('#pair-passphrase').fill('test-password'); await page.locator('#pair-passphrase-confirm').fill('test-password'); await page.locator('#btn-start-pair').click(); await checkText('#pair-error','邀请码格式不正确');
  await pair(); await visible('#view-dashboard'); await checkText('#current-node-badge','已连接');
  assert.equal(await page.locator('.app-row').count(),2); await checkText('.app-row','DSH'); await checkText('.app-row .status','运行中');
  const saved = await page.evaluate(async () => {
    const db = await new Promise((resolve,reject)=>{ const req=indexedDB.open('RemoteEverythingWeb',1); req.onsuccess=()=>resolve(req.result); req.onerror=()=>reject(req.error); });
    const record = await new Promise((resolve,reject)=>{ const req=db.transaction('vault_store').objectStore('vault_store').get('primary_vault'); req.onsuccess=()=>resolve(req.result); req.onerror=()=>reject(req.error); });
    db.close(); return JSON.stringify(record);
  });
  assert(!saved.includes('1'.repeat(64)) && !saved.includes('e'.repeat(64)), 'access or unlock credential stored in plaintext');
  assert(saved.includes('f'.repeat(64)), 'deny-only credential must be available without the password');
  await page.screenshot({path:path.join(output,'dashboard-desktop.png')});
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:path.join(output,'dashboard-mobile.png'),fullPage:true});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'mobile horizontal overflow');
  await page.setViewportSize({width:1365,height:900});
  await page.locator('#btn-settings').click(); await visible('#modal-settings');
  await page.screenshot({path:path.join(output,'settings-desktop.png')});
  await page.locator('#theme-select').selectOption('dark'); await page.keyboard.press('Escape');
  await page.screenshot({path:path.join(output,'dashboard-dark.png')});
  assert.equal(await page.locator('#modal-settings').evaluate(el=>el.open),false);
  await page.locator('#btn-settings').click(); await page.locator('#theme-select').selectOption('light'); await page.locator('#btn-close-settings').click();
  await page.keyboard.press('/'); assert.equal(await page.locator('#app-search').evaluate(el=>el===document.activeElement),true);
  await page.locator('#app-search').fill('DSH'); assert.equal(await page.locator('.app-row').count(),1);
  await page.locator('#app-search').fill('missing'); await checkText('#empty-title','没有找到应用');
  await page.locator('#app-search').fill('');
  failAction = true; await page.getByRole('button',{name:'启动 SillyTavern',exact:true}).click(); await checkText('.app-inline-error','繁忙');
  assert.equal(await page.getByRole('button',{name:'启动 SillyTavern',exact:true}).isEnabled(),true);
  failAction = false; await page.getByRole('button',{name:'启动 SillyTavern',exact:true}).click(); await page.getByRole('button',{name:'打开 SillyTavern',exact:true}).waitFor();
  for (const theme of ['dark','light','system']) {
    await page.locator('#btn-settings').click(); await page.locator('#theme-select').selectOption(theme); await page.locator('#btn-close-settings').click();
    if (theme === 'system') await page.emulateMedia({colorScheme:'dark'});
    holdOpen = new Promise(resolve => { releaseOpen = resolve; });
    const popupPromise = context.waitForEvent('page'); await page.getByRole('button',{name:'打开 SillyTavern',exact:true}).click(); const popup = await popupPromise;
    await popup.waitForFunction(()=>document.title === 'SillyTavern');
    const expected = await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--canvas').trim());
    const actual = await popup.evaluate(()=>({background:getComputedStyle(document.documentElement).backgroundColor,body:document.body.textContent,opener:window.opener}));
    const expectedRGB = await page.evaluate(color=>{const probe=document.createElement('span');probe.style.color=color;document.body.append(probe);const rgb=getComputedStyle(probe).color;probe.remove();return rgb;},expected);
    assert.equal(actual.background,expectedRGB);assert.equal(actual.body,'');assert.equal(actual.opener,null);
    await popup.screenshot({path:path.join(output,`application-opening-${theme}.png`)});
    releaseOpen();holdOpen=null;
    assert.equal(requests.filter(request=>request.path.includes('/open/')).at(-1).appearance,theme === 'light' ? 'light' : 'dark');
    await popup.waitForURL('https://application.example.test/**'); assert(popup.url().endsWith('#/home')); assert.equal(await popup.evaluate(()=>window.opener),null); await popup.close();
  }
  await page.emulateMedia({colorScheme:'light'});
  await page.getByRole('button',{name:'停止 SillyTavern',exact:true}).click();
  await page.getByRole('button',{name:'启动 SillyTavern',exact:true}).waitFor();
  assert.equal(await page.locator('#modal-confirm').evaluate(el=>el.open),false);
  assert((await page.evaluate(()=>window.requestBudgets)).includes(30000),'stop must outlive the server shutdown budget');
  assert((await page.evaluate(()=>window.requestBudgets)).includes(10000),'ordinary reads keep the shared request budget');
  stopFailure = true; await page.getByRole('button',{name:'停止 DSH',exact:true}).click(); await checkText('.app-inline-error','未能停止'); stopFailure = false;
  statusOnly = true; await page.getByRole('button',{name:'启动 SillyTavern',exact:true}).click();
  await page.waitForFunction(()=>document.querySelectorAll('.app-row')[1]?.querySelector('.status')?.textContent==='运行中');
  assert(requests.some(request=>request.path.endsWith('/sillytavern/status')),'control status without optional app must settle the row');
  statusOnly = false;
  nodeUnauthorized = true; await page.getByRole('button',{name:/书房电脑/}).click(); await checkText('#dashboard-error','访问权限');
  assert.equal(await page.locator('#view-dashboard').isVisible(),true,'node-specific unauthorized must preserve the browser session');
  nodeUnauthorized = false; await page.getByRole('button',{name:/Windows-PC 远程连接/}).click(); await checkText('#current-node-badge','已连接');
  invalidCatalog = true; await page.locator('#btn-refresh-apps').click(); await checkText('#dashboard-error','无法读取'); invalidCatalog = false;
  await page.locator('#btn-retry').click(); await checkText('#current-node-badge','已连接');
  invalidEncoding = true; await page.locator('#btn-refresh-apps').click(); await checkText('#dashboard-error','无法读取'); invalidEncoding = false;
  await page.locator('#btn-retry').click(); await checkText('#current-node-badge','已连接');
  await page.getByRole('button',{name:/书房电脑/}).click(); await checkText('#empty-title','电脑暂时离线');
  delayA = true; await page.getByRole('button',{name:/Windows-PC 远程连接/}).click(); await page.getByRole('button',{name:/书房电脑/}).click();
  await page.waitForTimeout(450); await checkText('#current-node-name','书房电脑'); assert.equal(await page.locator('.app-row').count(),0); delayA = false;
  await page.getByRole('button',{name:/Windows-PC 远程连接/}).click(); await checkText('#current-node-badge','已连接');
  failCatalog = true; await page.locator('#btn-refresh-apps').click(); await checkText('#dashboard-error','繁忙'); assert.equal(await page.locator('.app-row').count(),0);
  failCatalog = false; await page.locator('#btn-retry').click(); await checkText('#current-node-badge','已连接');
  empty = true; await page.locator('#btn-refresh-apps').click(); await checkText('#empty-title','还没有应用'); empty = false;
  noNodes = true; await page.locator('#btn-refresh-apps').click(); await checkText('#empty-title','没有可访问'); noNodes = false;
  await page.locator('#btn-refresh-apps').click(); await checkText('#current-node-badge','已连接');
  failLock = true; await page.locator('#btn-lock').click(); await checkText('#dashboard-error','尚未锁定');
  assert.equal(await page.locator('#view-dashboard').isVisible(),true); failLock = false;
  await page.locator('#btn-lock').click(); await visible('#view-unlock'); assert.equal(await page.locator('.app-row').count(),0);
  await page.screenshot({path:path.join(output,'unlock-desktop.png')});
  await page.setViewportSize({width:320,height:720});
  await page.screenshot({path:path.join(output,'unlock-mobile.png'),fullPage:true});
  await page.setViewportSize({width:1365,height:900});
  await page.locator('#unlock-passphrase').fill('incorrect'); await page.locator('#btn-unlock').click(); await checkText('#unlock-error','密码错误');
  await page.locator('#unlock-passphrase').fill('test-password'); await page.locator('#btn-unlock').click(); await checkText('#current-node-badge','已连接');
  const sibling = await context.newPage(); await sibling.goto(origin+'/web/'); await sibling.locator('#view-unlock').waitFor();
  await visible('#view-unlock'); await sibling.close();
  await page.reload(); await visible('#view-unlock'); await page.locator('#unlock-passphrase').fill('test-password'); await page.locator('#btn-unlock').click(); await checkText('#current-node-badge','已连接');
  unauthorized = true; await page.locator('#btn-refresh-apps').click(); await visible('#view-unlock');
  await page.locator('#unlock-passphrase').fill('test-password'); await page.locator('#btn-unlock').click();
  await visible('#view-pair'); await checkText('#pair-error','已失效'); unauthorized = false;
  pending = true; await pair(); await visible('#view-pending'); await page.screenshot({path:path.join(output,'pending.png')});
  await page.reload(); await visible('#view-unlock'); await page.locator('#unlock-passphrase').fill('test-password'); await page.locator('#btn-unlock').click(); await visible('#view-pending');
  pending = false; await checkText('#current-node-badge','已连接');
  await page.locator('#btn-settings').click(); await page.locator('#btn-logout').click(); await page.locator('#confirm-accept').click(); await visible('#view-pair');
  await page.reload(); await visible('#view-pair');
  await page.setViewportSize({width:320,height:720}); await page.screenshot({path:path.join(output,'pair-mobile.png'),fullPage:true});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'pair horizontal overflow');
  assert.deepEqual(errors,[]);
  console.log('PASS: pairing, validation, catalog contract, light/dark, mobile, search, action failure/retry, start/stop, authenticated app open, node race, offline, empty states, unlock, pending resume, expiry, logout.');
  console.log(`${requests.length} API requests checked; screenshots: ${output}`);
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{await browser?.close();server?.close();});
