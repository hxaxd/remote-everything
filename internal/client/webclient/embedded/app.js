(() => {
  'use strict';

  const DB_NAME = 'RemoteEverythingWeb';
  const DB_STORE = 'vault_store';
  const VAULT_KEY = 'primary_vault';

  class CryptoVault {
    static async openDB() {
      return new Promise((resolve, reject) => {
        const req = indexedDB.open(DB_NAME, 1);
        req.onupgradeneeded = (e) => {
          const db = e.target.result;
          if (!db.objectStoreNames.contains(DB_STORE)) {
            db.createObjectStore(DB_STORE);
          }
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
    }

    static async hasVault() {
        const db = await this.openDB();
        return new Promise((resolve, reject) => {
          const tx = db.transaction(DB_STORE, 'readonly');
          const req = tx.objectStore(DB_STORE).get(VAULT_KEY);
          req.onsuccess = () => resolve(!!req.result);
          req.onerror = () => reject(req.error);
          tx.oncomplete = () => db.close();
          tx.onabort = () => { db.close(); reject(tx.error); };
        });
    }

    static async revocation() {
      const db = await this.openDB();
      return new Promise((resolve, reject) => {
        const tx = db.transaction(DB_STORE, 'readonly');
        const req = tx.objectStore(DB_STORE).get(VAULT_KEY);
        req.onsuccess = () => resolve(req.result?.revokeToken);
        req.onerror = () => reject(req.error);
        tx.oncomplete = () => db.close();
        tx.onabort = () => { db.close(); reject(tx.error); };
      });
    }

    static async deriveKey(passphrase, salt) {
      const enc = new TextEncoder();
      const keyMaterial = await crypto.subtle.importKey(
        'raw',
        enc.encode(passphrase),
        { name: 'PBKDF2' },
        false,
        ['deriveKey']
      );
      return crypto.subtle.deriveKey(
        {
          name: 'PBKDF2',
          salt: salt,
          iterations: 100000,
          hash: 'SHA-256',
        },
        keyMaterial,
        { name: 'AES-GCM', length: 256 },
        false,
        ['encrypt', 'decrypt']
      );
    }

    static async save(data, passphrase, revokeToken) {
      const salt = crypto.getRandomValues(new Uint8Array(16));
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const key = await this.deriveKey(passphrase, salt);
      const plaintext = new TextEncoder().encode(JSON.stringify(data));
      const ciphertext = await crypto.subtle.encrypt(
        { name: 'AES-GCM', iv: iv },
        key,
        plaintext
      );

      const record = {
        revokeToken,
        salt: Array.from(salt),
        iv: Array.from(iv),
        ciphertext: Array.from(new Uint8Array(ciphertext)),
        updatedAt: new Date().toISOString(),
      };

      const db = await this.openDB();
      return new Promise((resolve, reject) => {
        const tx = db.transaction(DB_STORE, 'readwrite');
        tx.objectStore(DB_STORE).put(record, VAULT_KEY);
        tx.oncomplete = () => { db.close(); resolve(); };
        tx.onabort = () => { db.close(); reject(new Error('无法保存连接，请允许浏览器存储数据后重试。')); };
      });
    }

    static async load(passphrase) {
      const db = await this.openDB();
      const record = await new Promise((resolve, reject) => {
        const tx = db.transaction(DB_STORE, 'readonly');
        const req = tx.objectStore(DB_STORE).get(VAULT_KEY);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
        tx.oncomplete = () => db.close();
        tx.onabort = () => { db.close(); reject(tx.error); };
      });

      if (!record) {
        throw new Error('没有保存的连接，请重新配对。');
      }

      const salt = new Uint8Array(record.salt);
      const iv = new Uint8Array(record.iv);
      const ciphertext = new Uint8Array(record.ciphertext);
      const key = await this.deriveKey(passphrase, salt);

      try {
        const decrypted = await crypto.subtle.decrypt(
          { name: 'AES-GCM', iv: iv },
          key,
          ciphertext
        );
        return JSON.parse(new TextDecoder().decode(decrypted));
      } catch (err) {
        throw new Error('密码错误或数据已损坏');
      }
    }

    static async clear() {
        const db = await this.openDB();
        return new Promise((resolve, reject) => {
          const tx = db.transaction(DB_STORE, 'readwrite');
          tx.objectStore(DB_STORE).delete(VAULT_KEY);
          tx.oncomplete = () => { db.close(); resolve(); };
          tx.onabort = () => { db.close(); reject(new Error('无法删除本地连接，请检查浏览器存储权限。')); };
        });
    }
  }

  const $ = (id) => document.getElementById(id);
  const icon = (name) => `<svg class="icon" aria-hidden="true"><use href="#i-${name}"/></svg>`;
  const state = { session: null, nodes: [], nodeId: '', apps: [], catalogReady: false, view: '', epoch: 0, catalogSeq: 0, timer: null, requests: new Set(), actions: new Set(), errors: new Map() };
  let pairAttempt = null;
  const errorMessages = {
    invitation_denied: '邀请已失效或已被使用，请向管理员获取新的邀请。',
    approval_pending: '连接申请还在等待管理员确认。',
    unauthorized: '连接已锁定或失效，请重新解锁。',
    connection_expired: '连接已失效，请重新配对。',
    session_revoke_failed: '网关未能保存撤销结果，请重试。',
    device_revoked: '此设备的访问权限已被撤销，请联系管理员。',
    node_not_found: '这台电脑已被移除，请刷新电脑列表。',
    node_forbidden: '你没有这台电脑的访问权限，请联系管理员。',
    forbidden: '没有访问权限，请联系管理员。',
    computer_offline: '电脑当前离线，请确认电脑开机且远程服务正在运行。',
    app_not_found: '应用已被移除，请刷新列表。',
    rate_limited: '请求过于频繁，请稍后重试。',
    server_busy: '网关暂时繁忙，请稍后重试。',
    stop_command_failed: '应用未能停止，请稍后重试。',
    invalid_body: '提交的信息不完整，请检查后重试。',
    invalid_device_name: '请输入不超过 80 个字符的设备名称。',
  };
  const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
  const messageFor = (code) => errorMessages[code] || '请求未能完成，请稍后重试。';
  const staleError = () => new DOMException('Request superseded', 'AbortError');
  const refusalCodes = new Set(['node_required','unauthorized','invitation_denied','invitation_expired','approval_pending','node_not_found','app_not_found','not_found','forbidden','computer_offline','activation_failed','invalid_device_name','invalid_credential_password','invalid_body','invalid_json','rate_limited','server_busy','pairing_failed','internal_error','connection_expired','method_not_allowed','session_issue_failed','session_revoke_failed']);

  function notice(id, message = '') { $(id).textContent = message; $(id).hidden = !message; }
  function toast(message) {
    $('toast').textContent = message; $('toast').hidden = false;
    clearTimeout(toast.timer); toast.timer = setTimeout(() => { $('toast').hidden = true; }, 3500);
  }
  function setBusy(button, busy, text) {
    if (busy) { button.dataset.label = button.innerHTML; button.innerHTML = `${icon('clock')}<span>${text}</span>`; }
    else if (button.dataset.label) button.innerHTML = button.dataset.label;
    button.disabled = busy;
  }
  function showView(name) {
    state.epoch++; state.catalogSeq++; clearTimeout(state.timer);
    document.querySelectorAll('dialog[open]').forEach(dialog => dialog.close());
    state.requests.forEach(controller => controller.abort()); state.requests.clear();
    state.view = name;
    for (const view of ['pair', 'unlock', 'pending', 'dashboard']) $('view-' + view).hidden = view !== name;
    $('sidebar-connected').hidden = name !== 'dashboard';
    $('session-actions').hidden = name !== 'dashboard';
    if (name !== 'dashboard') {
      state.apps = []; state.catalogReady = false; $('apps-list').replaceChildren(); $('node-list').replaceChildren();
      $('app-search').value = ''; $('last-updated').textContent = '';
      $('btn-refresh-apps').disabled = false;
    }
    document.title = name === 'dashboard' ? '我的电脑 · Remote Everything' : 'Remote Everything';
    requestAnimationFrame(() => {
      if (state.view !== name) return;
      const focus = name === 'unlock' ? $('unlock-passphrase') : document.querySelector(`#view-${name} h1`);
      focus?.focus({preventScroll: true});
    });
  }
  const unreadable = () => new Error('网关返回了无法读取的响应，请稍后重试。');
  const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const keys = (value, required, optional = []) => object(value) && required.every(key => Object.hasOwn(value, key)) && Object.keys(value).every(key => required.includes(key) || optional.includes(key));
  const text = (value, min, max) => typeof value === 'string' && [...value].length >= min && [...value].length <= max && !/[\u0000-\u001f\u007f]/.test(value);
  const appCode = app => app.enabled ? (app.running ? 'ready' : 'starting') : (app.running ? 'stopping' : 'stopped');
  function validApp(app) {
    return keys(app, ['id','name','description','icon','accent','launch_fragment','computer_connected','enabled','running','code']) &&
      /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(app.id) && text(app.name,1,80) && text(app.description,0,240) && text(app.icon,0,4) &&
      /^#[0-9a-fA-F]{6}$/.test(app.accent) && text(app.launch_fragment,0,2048) && (!app.launch_fragment || app.launch_fragment.startsWith('#')) &&
      app.computer_connected === true && typeof app.enabled === 'boolean' && typeof app.running === 'boolean' && app.code === appCode(app);
  }
  function validateAnswer(path, data) {
    if (!object(data) || typeof data.ok !== 'boolean') throw unreadable();
    if (path.endsWith('/nodes')) {
      if (!keys(data,['ok','nodes']) || !data.ok || !Array.isArray(data.nodes) || !data.nodes.every(node => keys(node,['id','name'],['link']) && /^[a-f0-9]{64}$/.test(node.id) && text(node.name,1,80) && (!Object.hasOwn(node,'link') || ['local','tunnel'].includes(node.link))) || new Set(data.nodes.map(node=>node.id)).size !== data.nodes.length) throw unreadable();
    } else if (path.endsWith('/apps')) {
      if (!keys(data,['ok','computer_connected','code','apps']) || !data.ok || typeof data.computer_connected !== 'boolean' || data.code !== (data.computer_connected ? 'ready' : 'computer_offline') || !Array.isArray(data.apps) || !data.apps.every(validApp) || (!data.computer_connected && data.apps.length) || new Set(data.apps.map(app=>app.id)).size !== data.apps.length) throw unreadable();
    } else if (/\/apps\/[^/]+\/(start|stop|status)$/.test(path)) {
      const action = path.split('/').at(-1);
      if (!keys(data,['ok','action','computer_connected','enabled','running','code'],['app','error_code']) || data.action !== action || typeof data.computer_connected !== 'boolean' || typeof data.enabled !== 'boolean' || typeof data.running !== 'boolean' || !['ready','starting','stopping','stopped','computer_offline','app_not_found','state_update_failed'].includes(data.code) || (Object.hasOwn(data,'app') && (!validApp(data.app) || data.app.id !== path.split('/').at(-2) || data.app.code !== data.code || data.app.enabled !== data.enabled || data.app.running !== data.running)) || (['ready','starting','stopping','stopped'].includes(data.code) && (!data.computer_connected || data.code !== appCode(data))) || (Object.hasOwn(data,'error_code') && (data.ok || data.error_code !== 'stop_command_failed'))) throw unreadable();
    } else if (path.includes('/open/')) {
      if (!keys(data,['ok','location']) || !data.ok || typeof data.location !== 'string') throw unreadable();
    } else if (path.endsWith('_pair') || path.endsWith('_unlock')) {
      if (!keys(data,['ok','device_name','fingerprint','session_token','status','nodes','expires_at'],['unlock_token','revoke_token']) || !data.ok || !text(data.device_name,1,80) || !/^[a-f0-9]{64}$/.test(data.fingerprint) || !/^[a-f0-9]{64}$/.test(data.session_token) || !['approved','pending'].includes(data.status) || data.nodes !== null && (!Array.isArray(data.nodes) || !data.nodes.every(id=>typeof id === 'string' && /^[a-f0-9]{64}$/.test(id))) || typeof data.expires_at !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(data.expires_at) || !Number.isFinite(Date.parse(data.expires_at)) || ['unlock_token','revoke_token'].some(key=>Object.hasOwn(data,key) && !/^[a-f0-9]{64}$/.test(data[key])) || path.endsWith('_pair') && (!data.unlock_token || !data.revoke_token)) throw unreadable();
    } else if (path.endsWith('_activate')) {
      if (!keys(data,['ok','status','device_name','fingerprint','nodes']) || !data.ok || data.status !== 'approved' || !text(data.device_name,1,80) || !/^[a-f0-9]{64}$/.test(data.fingerprint) || data.nodes !== null && (!Array.isArray(data.nodes) || !data.nodes.every(id=>typeof id === 'string' && /^[a-f0-9]{64}$/.test(id)))) throw unreadable();
    } else if (path.endsWith('_lock') || path.endsWith('_logout')) {
      if (!keys(data,['ok']) || !data.ok) throw unreadable();
    }
    return data;
  }
  async function request(path, {method = 'GET', nodeId = '', body, headers = {}, timeoutMs = method === 'POST' && path.endsWith('/stop') ? 30000 : 10000} = {}) {
    const epoch = state.epoch;
    const controller = new AbortController(); state.requests.add(controller);
    const timeout = setTimeout(() => controller.abort('timeout'), timeoutMs);
    try {
      const auth = { 'X-Remote-Everything-Web': '1', 'Accept': 'application/json', ...headers };
      if (state.session?.token) auth['X-Remote-Everything-Web-Token'] = state.session.token;
      if (nodeId) auth['X-Remote-Everything-Node'] = nodeId;
      if (body) auth['Content-Type'] = 'application/json';
      const response = await fetch(path, {method, headers: auth, credentials: 'same-origin', cache: 'no-store', signal: controller.signal, body: body ? JSON.stringify(body) : undefined});
      let data;
      try { data = JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(await response.arrayBuffer())); }
      catch { throw unreadable(); }
      if (!object(data) || typeof data.ok !== 'boolean') throw unreadable();
      const controlBody = /\/apps\/[^/]+\/(start|stop|status)$/.test(path) && Object.hasOwn(data,'action');
      if (data.ok === false && !controlBody && (!keys(data,['ok','code']) || !refusalCodes.has(data.code)) || !response.ok && data.ok !== false) throw unreadable();
      if (epoch !== state.epoch) throw staleError();
      if (response.status === 401 && !path.endsWith('_pair')) {
        if (nodeId && data.code !== 'device_revoked') {
          await request('/__remote_everything/nodes');
          const error = new Error(messageFor('node_forbidden')); error.code = 'node_forbidden'; throw error;
        }
        if (path.endsWith('_unlock') || data.code === 'device_revoked' || path.endsWith('_activate') && state.session?.status === 'pending') {
          await CryptoVault.clear(); resetSession(); showView('pair');
          notice('pair-error', messageFor('connection_expired'));
        } else if (!path.endsWith('_lock') && !path.endsWith('_logout')) {
          resetSession(); showView('unlock'); notice('unlock-error', messageFor('unauthorized'));
        } else { throw new Error(messageFor('unauthorized')); }
        throw staleError();
      }
      if (data.code === 'approval_pending') {
        if (response.status !== 202 || !keys(data,['ok','code']) || data.ok !== false) throw unreadable();
        return data;
      }
      if (response.status === 202) throw unreadable();
      const control = /\/apps\/[^/]+\/(start|stop|status)$/.test(path);
      if (response.ok && (data.ok || control && Object.hasOwn(data,'action'))) validateAnswer(path,data);
      if (!response.ok || data.ok === false) {
        if (!control && !keys(data,['ok','code'])) throw unreadable();
        const error = new Error(messageFor(data.error_code || data.code)); error.code = data.error_code || data.code; throw error;
      }
      return data;
    } catch (error) {
      if (epoch !== state.epoch) throw staleError();
      if (controller.signal.reason === 'timeout') throw new Error('连接超时，请检查网络后重试。');
      if (error instanceof TypeError) throw new Error('无法连接网关，请检查网络后重试。');
      throw error;
    } finally { clearTimeout(timeout); state.requests.delete(controller); }
  }
  function resetSession() {
    pairAttempt = null; $('pair-devicename').disabled = false;
    state.session = null; state.nodes = []; state.nodeId = ''; state.apps = []; state.actions.clear(); state.errors.clear();
    $('form-pair').reset(); $('form-unlock').reset();
    ['settings-device', 'settings-origin', 'settings-expires', 'pending-fingerprint', 'pending-devicename'].forEach(id => $(id).textContent = '');
    document.querySelectorAll('dialog[open]').forEach(dialog => dialog.close());
    $('pair-devicename').value = deviceName();
  }
  function deviceName() {
    const ua = navigator.userAgent;
    const os = /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iPhone / iPad' : /Windows/.test(ua) ? 'Windows' : /Mac/.test(ua) ? 'Mac' : /Linux/.test(ua) ? 'Linux' : '我的';
    return `${os} 浏览器`;
  }
  function clientId() {
    let id = localStorage.getItem('re_web_client_id');
    if (!/^[a-f0-9]{64}$/.test(id || '')) {
      id = Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('');
      localStorage.setItem('re_web_client_id', id);
    }
    return id;
  }
  function invitationToken(input) {
    let token = input.trim().replace(/^Invitation\s+/, '');
    if (token.includes('://')) {
      let uri;
      if (!token.startsWith('remote-everything://setup?')) throw new Error('请粘贴 Remote Everything 的完整邀请链接或邀请码。');
      try { uri = new URL(token); } catch { throw new Error('邀请链接不完整，请重新复制。'); }
      if (uri.protocol !== 'remote-everything:' || uri.hostname !== 'setup' || uri.pathname || uri.hash) throw new Error('请粘贴 Remote Everything 的完整邀请链接或邀请码。');
      if (uri.searchParams.getAll('invitation').length !== 1 || uri.searchParams.getAll('origin').length !== 1) throw new Error('邀请链接不完整，请重新复制。');
      let origin;
      const originText = uri.searchParams.get('origin');
      try { origin = new URL(originText); } catch { throw new Error('邀请链接中的网关地址无效。'); }
      if (!/^https:\/\/[^/?#@]+$/.test(originText) || originText !== originText.toLowerCase() || origin.protocol !== 'https:' || origin.username || origin.password || origin.origin !== window.location.origin) throw new Error('这个邀请属于另一个网关，请打开对应网关的网页后配对。');
      token = uri.searchParams.get('invitation');
    }
    if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('邀请码格式不正确，请复制完整的邀请链接或邀请码。');
    return token;
  }
  function confirmAction(title, description, label) {
    const dialog = $('modal-confirm'); $('confirm-title').textContent = title; $('confirm-description').textContent = description; $('confirm-accept').textContent = label;
    dialog.returnValue = ''; dialog.showModal(); $('confirm-cancel').focus();
    return new Promise(resolve => dialog.addEventListener('close', () => resolve(dialog.returnValue === 'accept'), {once: true}));
  }
  async function activate() {
    let data;
    try { data = await request('/__remote_everything_web_activate', {method: 'POST'}); }
    catch (error) {
      if (await finishRefusedPairing(error)) return;
      if (error.name !== 'AbortError' && state.session?.status === 'pending') { enterPending(); notice('pending-error',error.message); return; }
      throw error;
    }
    if (data.code === 'approval_pending') { enterPending(); return; }
    state.session.status = 'approved'; await enterDashboard();
  }
  async function finishRefusedPairing(error) {
    if (!['invitation_denied','invitation_expired','activation_failed','pairing_failed'].includes(error.code)) return false;
    await CryptoVault.clear(); resetSession(); showView('pair'); notice('pair-error',error.message); return true;
  }
  function enterPending() {
    showView('pending'); $('pending-devicename').textContent = state.session.deviceName; $('pending-fingerprint').textContent = state.session.fingerprint;
    notice('pending-error');
    const epoch = state.epoch;
    const poll = async () => {
      if (state.view !== 'pending' || state.epoch !== epoch) return;
      if (document.querySelector('dialog[open]')) { state.timer = setTimeout(poll, 5000); return; }
      try {
        const data = await request('/__remote_everything_web_activate', {method: 'POST'});
        notice('pending-error');
        if (data.status === 'approved') { state.session.status = 'approved'; await enterDashboard(); return; }
      } catch (error) {
        if (await finishRefusedPairing(error)) return;
        if (error.name !== 'AbortError') notice('pending-error', error.message + ' 页面会自动重试。');
      }
      if (state.view === 'pending' && state.epoch === epoch) state.timer = setTimeout(poll, 5000);
    };
    state.timer = setTimeout(poll, 1500);
  }
  const linkLabel = node => node?.link === 'local' ? '局域网连接' : node?.link === 'tunnel' ? '远程连接' : '网关连接';
  async function enterDashboard() { showView('dashboard'); await refreshNodes(); }
  async function refreshNodes() {
    const button = $('btn-refresh-apps'); if (button.disabled) return;
    button.disabled = true; notice('dashboard-error');
    const epoch = state.epoch;
    if (!state.nodes.length) { $('apps-loading').hidden = false; $('empty-apps').hidden = true; }
    try {
      const data = await request('/__remote_everything/nodes');
      if (!Array.isArray(data.nodes)) throw new Error('无法读取电脑列表，请重试。');
      state.nodes = data.nodes;
      if (!state.nodes.some(node => node.id === state.nodeId)) state.nodeId = state.nodes[0]?.id || '';
      renderNodes();
      if (state.nodeId) await loadApps();
      else {
        state.apps = []; state.catalogReady = false; $('apps-list').replaceChildren(); $('app-count').textContent = '0';
        setConnection('没有可用电脑', 'neutral'); emptyState('还没有可访问的电脑', '请联系管理员，为这台设备添加电脑访问权限。', true);
      }
    } catch (error) {
      if (error.name !== 'AbortError') {
        notice('dashboard-error', error.message); setConnection('连接失败', 'bad');
        if (!state.apps.length) emptyState('暂时无法连接', '检查网络后，再试一次。', true);
      }
    } finally {
      if (state.epoch === epoch) { button.disabled = false; $('apps-loading').hidden = true; scheduleRefresh(); }
    }
  }
  function renderNodes() {
    $('node-count').textContent = state.nodes.length;
    $('node-list').replaceChildren();
    for (const node of state.nodes) {
      const button = document.createElement('button'); button.className = 'node-button'; button.setAttribute('aria-current', String(node.id === state.nodeId));
      button.innerHTML = `${icon('computer')}<span class="node-label"><strong>${escapeHTML(node.name)}</strong><small>${linkLabel(node)}</small></span>${icon('arrow')}`;
      button.addEventListener('click', () => {
        if (state.nodeId === node.id) return;
        state.epoch++; state.catalogSeq++;
        state.requests.forEach(controller => controller.abort()); state.requests.clear();
        state.actions.clear(); $('btn-refresh-apps').disabled = false;
        state.nodeId = node.id; state.apps = []; state.catalogReady = false; $('apps-list').replaceChildren(); $('app-search').value = ''; $('last-updated').textContent = '';
        renderNodes(); loadApps();
      }); $('node-list').appendChild(button);
    }
    const node = state.nodes.find(node => node.id === state.nodeId);
    $('breadcrumb-node').textContent = node?.name || '';
    $('current-node-name').textContent = node?.name || '我的电脑'; $('current-node-meta').textContent = node ? linkLabel(node) : '';
    document.title = `${node?.name || '我的电脑'} · Remote Everything`;
  }
  function setConnection(label, tone) { $('current-node-badge').textContent = label; $('current-node-badge').dataset.tone = tone; }
  function emptyState(title, description, retry = false) {
    $('empty-apps').hidden = false; $('empty-title').textContent = title; $('empty-description').textContent = description; $('btn-retry').hidden = !retry;
  }
  function scheduleRefresh() {
    clearTimeout(state.timer);
    if (state.view !== 'dashboard') return;
    state.timer = setTimeout(async () => {
      if (!document.hidden && !document.querySelector('dialog[open]') && !state.actions.size) await refreshNodes();
      else scheduleRefresh();
    }, 15000);
  }
  async function loadApps() {
    const nodeId = state.nodeId; if (!nodeId || state.view !== 'dashboard') return;
    const seq = ++state.catalogSeq;
    const current = () => seq === state.catalogSeq && state.view === 'dashboard' && state.nodeId === nodeId;
    const firstLoad = !state.apps.length;
    notice('dashboard-error'); $('empty-apps').hidden = true; $('apps-loading').hidden = !firstLoad;
    if (firstLoad) { setConnection('正在连接', 'neutral'); $('app-count').textContent = '—'; }
    try {
      const data = await request('/__remote_everything/apps', {nodeId});
      if (!current()) return;
      if (!data.computer_connected) {
        state.apps = []; state.catalogReady = false; $('apps-list').replaceChildren(); $('app-count').textContent = '—'; setConnection('离线', 'neutral');
        emptyState('电脑暂时离线', '请确认电脑已开机，并已启动远程服务。', true); return;
      }
      if (!Array.isArray(data.apps)) throw new Error('无法读取应用列表，请重试。');
      state.apps = data.apps.map(app => state.actions.has(`${nodeId}/${app.id}`) ? state.apps.find(old => old.id === app.id) || app : app); state.catalogReady = true; setConnection('已连接', 'good'); renderApps();
      $('last-updated').textContent = `更新于 ${new Date().toLocaleTimeString('zh-CN', {hour:'2-digit', minute:'2-digit'})}`;
    } catch (error) {
      if (current() && error.name !== 'AbortError') {
        state.apps = []; state.catalogReady = false; $('apps-list').replaceChildren(); $('app-count').textContent = '—'; setConnection('连接失败', 'bad');
        notice('dashboard-error', error.message); emptyState('暂时无法读取应用', '检查连接后重试。', true);
      }
    } finally { if (current()) { $('apps-loading').hidden = true; scheduleRefresh(); } }
  }
  function appStatus(app) {
    const states = {ready:['运行中','good'], stopped:['已停止','neutral'], starting:['启动中','busy'], stopping:['停止中','busy']};
    return states[app.code] || ['尚未就绪', 'neutral'];
  }
  function renderApps() {
    if (!state.catalogReady) return;
    const list = $('apps-list'); const focused = list.contains(document.activeElement) ? document.activeElement.dataset.focus : '';
    list.replaceChildren(); $('app-count').textContent = state.apps.length;
    const query = $('app-search').value.trim().toLocaleLowerCase();
    const apps = state.apps.filter(app => `${app.name} ${app.description} ${app.id}`.toLocaleLowerCase().includes(query));
    $('empty-apps').hidden = apps.length > 0;
    if (!apps.length) emptyState(query ? '没有找到应用' : '这台电脑还没有应用', query ? '试试其他名称，或清空搜索。' : '在电脑上添加应用后，它们会出现在这里。');
    for (const app of apps) {
      const key = `${state.nodeId}/${app.id}`;
      const pending = state.actions.has(key) || ['starting','stopping'].includes(app.code);
      const [label, tone] = appStatus(app);
      const canOpen = ['ready','starting'].includes(app.code);
      const row = document.createElement('article'); row.className = 'app-row'; row.setAttribute('aria-label', app.name);
      row.innerHTML = `<div class="app-identity"><span class="app-avatar" aria-hidden="true">${escapeHTML(app.icon || app.name?.slice(0,2) || 'APP')}</span><div class="app-copy"><${canOpen ? 'button' : 'span'} class="app-name">${escapeHTML(app.name || app.id)}</${canOpen ? 'button' : 'span'}><p class="app-description">${escapeHTML(app.description || app.id)}</p></div></div><span class="status" data-tone="${tone}">${label}</span><div class="app-actions"></div>`;
      if (/^#[a-fA-F0-9]{6}$/.test(app.accent)) { row.querySelector('.app-avatar').style.background = `color-mix(in srgb, ${app.accent} 12%, var(--canvas))`; row.querySelector('.app-avatar').style.color = 'var(--text)'; }
      const actions = row.querySelector('.app-actions');
      const addButton = (text, cls, action, handler) => {
        const button = document.createElement('button'); button.className = `button ${cls}`; button.innerHTML = text; button.disabled = action === 'open' ? state.actions.has(key) || app.code === 'stopping' : pending; button.dataset.focus = `${app.id}/${action}`; button.setAttribute('aria-label', `${action === 'open' ? '打开' : action === 'stop' ? '停止' : '启动'} ${app.name}`); button.addEventListener('click', handler); actions.appendChild(button);
      };
      if (canOpen) addButton(`打开 ${icon('external')}`, 'secondary', 'open', () => openApp(app));
      const action = app.running || app.code === 'ready' ? 'stop' : 'start';
      addButton(pending ? '处理中…' : action === 'stop' ? '停止' : '启动', canOpen ? 'quiet stop-button' : 'secondary', action, () => changeApp(app, action));
      const title = row.querySelector('button.app-name');
      if (title) { title.dataset.focus = `${app.id}/title`; title.disabled = state.actions.has(key); title.addEventListener('click', () => openApp(app)); }
      if (state.errors.has(key)) { const error = document.createElement('p'); error.className = 'app-inline-error'; error.setAttribute('role', 'alert'); error.textContent = state.errors.get(key); row.appendChild(error); }
      list.appendChild(row);
    }
    if (focused) Array.from(list.querySelectorAll('[data-focus]')).find(el => el.dataset.focus === focused)?.focus({preventScroll:true});
  }
  async function changeApp(app, action) {
    const nodeId = state.nodeId; const epoch = state.epoch; const key = `${nodeId}/${app.id}`;
    if (state.actions.has(key)) return;
    if (state.nodeId !== nodeId || state.epoch !== epoch) return;
    state.actions.add(key); state.errors.delete(key); renderApps();
    try {
      let answer;
      try { answer = await request(`/__remote_everything/apps/${encodeURIComponent(app.id)}/${action}`, {method:'POST', nodeId}); }
      catch (error) {
        if (error.name === 'AbortError' || error.code) throw error;
        state.errors.set(key,error.message);
      }
      if (state.epoch === epoch && state.nodeId === nodeId) {
        await pollApp(app,nodeId,epoch,action === 'start' ? 'ready' : 'stopped',answer);
        state.errors.delete(key);
      }
    } catch (error) { if (error.name !== 'AbortError' && state.epoch === epoch) state.errors.set(key, error.message); }
    finally { if (state.epoch === epoch) { state.actions.delete(key); if (state.nodeId === nodeId) renderApps(); } }
  }
  async function pollApp(app, nodeId, epoch, target, answer) {
    const deadline = performance.now() + 60000;
    let delay = 1000;
    while (state.epoch === epoch && state.nodeId === nodeId) {
      if (answer) {
        state.catalogSeq++;
        state.apps = state.apps.map(old => old.id !== app.id ? old : answer.app || {...old, enabled:answer.enabled, running:answer.running, code:answer.code});
        renderApps();
        if (answer.code === target) return;
        if (!['ready','starting','stopping','stopped'].includes(answer.code)) throw new Error(messageFor(answer.code));
      }
      const remaining = deadline - performance.now();
      if (remaining <= 0) throw new Error('操作仍未完成，请刷新状态后重试。');
      await new Promise(resolve => setTimeout(resolve,Math.min(delay,remaining)));
      if (state.epoch !== epoch || state.nodeId !== nodeId) throw staleError();
      const budget = deadline - performance.now();
      if (budget <= 0) throw new Error('操作仍未完成，请刷新状态后重试。');
      try { answer = await request(`/__remote_everything/apps/${encodeURIComponent(app.id)}/status`, {nodeId,timeoutMs:Math.min(10000,budget)}); }
      catch (error) { if (error.name === 'AbortError' || error.code) throw error; answer = null; }
      delay = Math.min(5000,delay * 1.5);
    }
    throw staleError();
  }
  async function openApp(app) {
    const nodeId = state.nodeId; const epoch = state.epoch; const key = `${nodeId}/${app.id}`;
    if (state.actions.has(key) || !['ready','starting'].includes(app.code)) return;
    const popup = window.open('about:blank', '_blank');
    if (!popup) { state.errors.set(key, '浏览器阻止了新标签页，请允许此网站打开弹出窗口后重试。'); renderApps(); return; }
    popup.opener = null; popup.document.title = `正在打开 ${app.name}`; popup.document.body.textContent = `正在连接 ${app.name}…`;
    state.actions.add(key); state.errors.delete(key); renderApps();
    try {
      if (app.code === 'starting') await pollApp(app,nodeId,epoch,'ready');
      const data = await request(`/__remote_everything/open/${encodeURIComponent(app.id)}`, {nodeId});
      if (state.epoch !== epoch || state.nodeId !== nodeId) throw staleError();
      const destination = new URL(data.location);
      if (destination.protocol !== 'https:' || destination.username || destination.password) throw new Error('应用地址无效，请刷新后重试。');
      if (app.launch_fragment) destination.hash = app.launch_fragment.replace(/^#/, '');
      if (!popup.closed) popup.location.replace(destination.href);
    } catch (error) {
      popup.close(); if (error.name !== 'AbortError' && state.epoch === epoch) state.errors.set(key, error.message);
    } finally { if (state.epoch === epoch) { state.actions.delete(key); if (state.nodeId === nodeId) renderApps(); } }
  }
  function applyTheme(value) {
    if (value === 'system') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = value;
    $('theme-select').value = value;
  }
  const sessionChannel = new BroadcastChannel('remote-everything-session');
  sessionChannel.onmessage = event => {
    if (!['lock', 'logout'].includes(event.data)) return;
    resetSession(); showView(event.data === 'logout' ? 'pair' : 'unlock');
  };
  async function revokeConnection(logout = false) {
    const credential = await CryptoVault.revocation();
    if (!/^[a-f0-9]{64}$/.test(credential || '')) throw new Error('连接已失效，请重新配对。');
    await request(logout ? '/__remote_everything_web_logout' : '/__remote_everything_web_lock', {
      method: 'POST', headers: {'X-Remote-Everything-Web-Revoke': credential}
    });
    if (logout) await CryptoVault.clear();
    resetSession(); showView(logout ? 'pair' : 'unlock');
    sessionChannel.postMessage(logout ? 'logout' : 'lock');
  }
  function rememberAccess(data) {
    state.session = {token:data.session_token, fingerprint:data.fingerprint, deviceName:data.device_name, status:data.status, expiresAt:data.expires_at};
  }
  function bindEvents() {
    $('pair-invitation').addEventListener('input', () => { pairAttempt = null; $('pair-devicename').disabled = false; });
    $('form-pair').addEventListener('submit', async event => {
      event.preventDefault(); const button = $('btn-start-pair'); if (button.disabled) return;
      const password = $('pair-passphrase').value; notice('pair-error');
      if (password !== $('pair-passphrase-confirm').value) { notice('pair-error', '两次输入的密码不一致。'); $('pair-passphrase-confirm').focus(); return; }
      setBusy(button, true, '正在连接');
      try {
        const token = invitationToken($('pair-invitation').value);
        if (!pairAttempt || pairAttempt.token !== token) pairAttempt = {token,deviceName:$('pair-devicename').value.trim(),clientId:clientId()};
        $('pair-devicename').value = pairAttempt.deviceName; $('pair-devicename').disabled = true;
        const data = await request('/__remote_everything_web_pair', {method:'POST', headers:{Authorization:`Invitation ${token}`}, body:{device_name:pairAttempt.deviceName,client_id:pairAttempt.clientId}});
        rememberAccess(data);
        try { await CryptoVault.save({unlockToken:data.unlock_token}, password, data.revoke_token); }
        catch (error) { await request('/__remote_everything_web_logout', {method:'POST',headers:{'X-Remote-Everything-Web-Revoke':data.revoke_token}}); resetSession(); throw error; }
        $('form-pair').reset();
        await activate();
      } catch (error) { if (error.name !== 'AbortError') notice('pair-error', error.message); }
      finally { setBusy(button, false); }
    });
    $('form-unlock').addEventListener('submit', async event => {
      event.preventDefault(); const button = $('btn-unlock'); if (button.disabled) return;
      setBusy(button, true, '正在解锁'); notice('unlock-error');
      try {
        const vault = await CryptoVault.load($('unlock-passphrase').value);
        $('unlock-passphrase').value = '';
        const data = await request('/__remote_everything_web_unlock', {method:'POST',headers:{'X-Remote-Everything-Web-Unlock':vault.unlockToken}});
        rememberAccess(data); await activate();
      }
      catch (error) { if (error.name !== 'AbortError') { state.session = null; notice('unlock-error', error.message); } }
      finally { setBusy(button, false); }
    });
    $('btn-forget').addEventListener('click', async () => {
      if (!await confirmAction('删除保存的连接？', '忘记密码后无法恢复保存的连接。删除后，你需要新的邀请才能重新配对。', '删除并重新配对')) return;
      try { await revokeConnection(true); } catch (error) { if (error.name !== 'AbortError') notice('unlock-error', error.message); }
    });
    $('btn-cancel-pending').addEventListener('click', async () => {
      if (!await confirmAction('取消连接申请？', '本次邀请已被使用。取消后重新连接需要新的邀请。', '取消连接')) return;
      const button = $('btn-cancel-pending'); setBusy(button, true, '正在取消');
      try { await revokeConnection(true); }
      catch (error) { if (error.name !== 'AbortError') notice('pending-error', error.message); }
      finally { setBusy(button, false); }
    });
    $('btn-copy-fp').addEventListener('click', async () => { try { await navigator.clipboard.writeText(state.session.fingerprint); toast('已复制设备指纹'); } catch { notice('pending-error', '无法访问剪贴板，请选中设备指纹手动复制。'); } });
    $('btn-lock').addEventListener('click', async () => {
      const button = $('btn-lock'); if (button.disabled) return; setBusy(button, true, '正在锁定');
      try { await revokeConnection(); notice('unlock-error'); }
      catch (error) { if (error.name !== 'AbortError') notice('dashboard-error', '尚未锁定。' + error.message); }
      finally { setBusy(button, false); }
    });
    $('btn-refresh-apps').addEventListener('click', refreshNodes); $('btn-retry').addEventListener('click', refreshNodes);
    $('app-search').addEventListener('input', renderApps);
    $('btn-settings').addEventListener('click', () => {
      $('settings-device').textContent = state.session.deviceName; $('settings-origin').textContent = window.location.origin;
      const expires = new Date(state.session.expiresAt); $('settings-expires').textContent = Number.isNaN(expires.valueOf()) ? '暂时无法读取' : expires.toLocaleString('zh-CN', {year:'numeric',month:'long',day:'numeric',hour:'2-digit',minute:'2-digit'});
      $('modal-settings').showModal();
    });
    $('btn-close-settings').addEventListener('click', () => $('modal-settings').close());
    $('confirm-cancel').addEventListener('click', () => $('modal-confirm').close('cancel'));
    $('confirm-accept').addEventListener('click', () => $('modal-confirm').close('accept'));
    $('modal-settings').addEventListener('click', event => {
      const rect = event.currentTarget.getBoundingClientRect();
      if (event.target === event.currentTarget && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) event.currentTarget.close();
    });
    $('btn-logout').addEventListener('click', async () => {
      if (!await confirmAction('退出此浏览器的连接？', '本地保存的连接将被删除。再次使用需要新的邀请和配对。', '退出连接')) return;
      const button = $('btn-logout'); setBusy(button, true, '正在退出');
      try { await revokeConnection(true); }
      catch (error) { if (error.name !== 'AbortError') { $('modal-settings').close(); notice('dashboard-error', error.message); } }
      finally { setBusy(button, false); }
    });
    $('theme-select').addEventListener('change', event => { applyTheme(event.target.value); try { localStorage.setItem('re_web_theme', event.target.value); } catch {} });
    document.addEventListener('keydown', event => {
      if (event.key === '/' && state.view === 'dashboard' && !document.querySelector('dialog[open]') && !/INPUT|TEXTAREA|SELECT/.test(event.target.tagName)) { event.preventDefault(); $('app-search').focus(); }
    });
    document.addEventListener('visibilitychange', () => { if (!document.hidden && state.view === 'dashboard') refreshNodes(); });
    window.addEventListener('online', () => { if (state.view === 'dashboard') refreshNodes(); });
  }
  async function init() {
    try { const theme = localStorage.getItem('re_web_theme'); applyTheme(['light','dark'].includes(theme) ? theme : 'system'); } catch { applyTheme('system'); }
    $('gateway-host').textContent = window.location.host; $('pair-devicename').value = deviceName(); bindEvents();
    try {
      const params = new URLSearchParams(window.location.search); const hash = new URLSearchParams(window.location.hash.slice(1));
      const invitation = params.get('invitation') || params.get('token') || hash.get('invitation');
      if (invitation) { params.delete('invitation'); params.delete('token'); history.replaceState(null, '', location.pathname + (params.size ? '?' + params : '')); }
      let hasVault = await CryptoVault.hasVault();
      if (hasVault && !/^[a-f0-9]{64}$/.test(await CryptoVault.revocation() || '')) {
        await CryptoVault.clear(); hasVault = false; notice('pair-error', messageFor('connection_expired'));
      }
      showView(hasVault ? 'unlock' : 'pair');
      if (hasVault) {
        $('btn-unlock').disabled = true;
        try { await revokeConnection(); }
        catch (error) { if (error.name !== 'AbortError') notice('unlock-error', '未能确认锁定。' + error.message); }
        finally { $('btn-unlock').disabled = false; }
      }
      if (!hasVault && invitation) $('pair-invitation').value = invitation;
      if (!window.isSecureContext || !crypto.subtle) { notice('pair-error', '请通过 HTTPS 地址打开此页面，以便安全保存连接。'); $('btn-start-pair').disabled = true; }
    } catch { showView('pair'); notice('pair-error', '无法访问浏览器存储。请允许此网站保存数据后刷新。'); }
  }
  init();
})();
