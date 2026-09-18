// Remote Everything Web Client (SPA)
// Pure Vanilla ES6+, Zero External Dependencies, WebCrypto AES-GCM Vault

(() => {
  'use strict';

  // ===================== 1. WebCrypto 加密保险箱 =====================
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
      try {
        const db = await this.openDB();
        return new Promise((resolve) => {
          const tx = db.transaction(DB_STORE, 'readonly');
          const req = tx.objectStore(DB_STORE).get(VAULT_KEY);
          req.onsuccess = () => resolve(!!req.result);
          req.onerror = () => resolve(false);
        });
      } catch (e) {
        return false;
      }
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

    static async save(data, passphrase) {
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
        salt: Array.from(salt),
        iv: Array.from(iv),
        ciphertext: Array.from(new Uint8Array(ciphertext)),
        updatedAt: new Date().toISOString(),
      };

      const db = await this.openDB();
      return new Promise((resolve, reject) => {
        const tx = db.transaction(DB_STORE, 'readwrite');
        tx.objectStore(DB_STORE).put(record, VAULT_KEY);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      });
    }

    static async load(passphrase) {
      const db = await this.openDB();
      const record = await new Promise((resolve, reject) => {
        const tx = db.transaction(DB_STORE, 'readonly');
        const req = tx.objectStore(DB_STORE).get(VAULT_KEY);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });

      if (!record) {
        throw new Error('本地保险箱为空');
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
      try {
        const db = await this.openDB();
        return new Promise((resolve) => {
          const tx = db.transaction(DB_STORE, 'readwrite');
          tx.objectStore(DB_STORE).delete(VAULT_KEY);
          tx.oncomplete = () => resolve();
          tx.onerror = () => resolve();
        });
      } catch (e) {}
    }
  }

  // ===================== 2. 状态管理与 API 交互 =====================
  const state = {
    session: null,       // { token, fingerprint, deviceName, expiresAt }
    nodes: [],           // [{ id, name }]
    currentNodeId: null, // 当前选中的 node_id
    apps: [],            // [{ id, title, state, port, origin }]
    pollTimer: null,
  };

  async function api(path, options = {}) {
    const headers = options.headers || {};
    if (state.session && state.session.token) {
      headers['X-Remote-Everything-Web-Token'] = state.session.token;
    }
    if (state.currentNodeId) {
      headers['X-Remote-Everything-Node'] = state.currentNodeId;
    }
    headers['X-Remote-Everything-Web'] = '1';

    const res = await fetch(path, {
      ...options,
      headers: headers,
    });

    // 401 凭据失效处理
    if (res.status === 401 && !path.includes('_pair') && !path.includes('_activate')) {
      showError('会话已失效或设备已被管理员吊销，请重新配对');
      await CryptoVault.clear();
      showView('pair');
      throw new Error('Unauthorized');
    }

    return res;
  }

  // ===================== 3. UI 视图切换 =====================
  const views = {
    unlock: document.getElementById('view-unlock'),
    pair: document.getElementById('view-pair'),
    pending: document.getElementById('view-pending'),
    dashboard: document.getElementById('view-dashboard'),
  };
  const navActions = document.getElementById('nav-actions');

  function showView(name) {
    Object.keys(views).forEach((v) => {
      if (views[v]) views[v].style.display = (v === name) ? 'block' : 'none';
    });
    if (navActions) {
      navActions.style.display = (name === 'dashboard') ? 'flex' : 'none';
    }
    if (state.pollTimer && name !== 'pending') {
      clearInterval(state.pollTimer);
      state.pollTimer = null;
    }
  }

  function showError(msg, targetId = 'pair-error') {
    const el = document.getElementById(targetId);
    if (el) {
      el.textContent = msg;
      el.style.display = msg ? 'block' : 'none';
    }
  }

  // ===================== 4. 流程与业务逻辑 =====================

  // 生成稳定的随机 64-hex client_id
  function getOrGenerateClientId() {
    let id = localStorage.getItem('re_web_client_id');
    if (!id || !/^[a-f0-9]{64}$/.test(id)) {
      const bytes = crypto.getRandomValues(new Uint8Array(32));
      id = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
      localStorage.setItem('re_web_client_id', id);
    }
    return id;
  }

  // 初始化应用
  async function init() {
    // 检查 URL 是否带邀请码参数 (如 ?invitation=... 或 hash)
    const urlParams = new URLSearchParams(window.location.search);
    const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ''));
    const inviteParam = urlParams.get('invitation') || urlParams.get('token') || hashParams.get('invitation');

    const hasVault = await CryptoVault.hasVault();

    if (hasVault) {
      showView('unlock');
    } else {
      showView('pair');
      if (inviteParam) {
        const input = document.getElementById('pair-invitation');
        if (input) input.value = inviteParam;
      }
      const nameInput = document.getElementById('pair-devicename');
      if (nameInput && !nameInput.value) {
        const os = navigator.userAgent.includes('Windows') ? 'Windows' :
                   navigator.userAgent.includes('Mac') ? 'macOS' :
                   navigator.userAgent.includes('Linux') ? 'Linux' : 'Device';
        nameInput.value = `Web Browser on ${os}`;
      }
    }

    bindEvents();
  }

  // 事件绑定
  function bindEvents() {
    // 解锁表单
    const formUnlock = document.getElementById('form-unlock');
    if (formUnlock) {
      formUnlock.addEventListener('submit', async (e) => {
        e.preventDefault();
        const pwd = document.getElementById('unlock-passphrase').value;
        try {
          const vault = await CryptoVault.load(pwd);
          state.session = vault.session;
          showError('', 'unlock-error');
          await enterDashboard();
        } catch (err) {
          showError(err.message, 'unlock-error');
        }
      });
    }

    // 遗忘此设备
    const btnForget = document.getElementById('btn-forget');
    if (btnForget) {
      btnForget.addEventListener('click', async () => {
        if (confirm('确定要清除本地保存的凭据吗？之后需要重新配对。')) {
          await CryptoVault.clear();
          showView('pair');
        }
      });
    }

    // 配对表单
    const formPair = document.getElementById('form-pair');
    if (formPair) {
      formPair.addEventListener('submit', async (e) => {
        e.preventDefault();
        const invitation = document.getElementById('pair-invitation').value.trim();
        const deviceName = document.getElementById('pair-devicename').value.trim();
        const pass = document.getElementById('pair-passphrase').value;
        const passConfirm = document.getElementById('pair-passphrase-confirm').value;

        if (pass.length < 6) {
          showError('本地主密码长度至少需 6 位');
          return;
        }
        if (pass !== passConfirm) {
          showError('两次输入的主密码不一致');
          return;
        }

        const btn = document.getElementById('btn-start-pair');
        btn.disabled = true;
        btn.textContent = '正在配对...';
        showError('');

        try {
          const clientId = getOrGenerateClientId();
          const cleanToken = invitation.startsWith('Invitation ') ? invitation.slice(11) : invitation;

          const res = await fetch('/__remote_everything_web_pair', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': `Invitation ${cleanToken}`,
              'X-Remote-Everything-Web': '1',
            },
            body: JSON.stringify({
              device_name: deviceName,
              client_id: clientId,
            }),
          });

          const data = await res.json();
          if (!res.ok || !data.ok) {
            throw new Error(data.code || '配对被网关拒绝');
          }

          state.session = {
            token: data.session_token,
            fingerprint: data.fingerprint,
            deviceName: data.device_name,
            status: data.status,
            expiresAt: data.expires_at,
          };

          // 保存到本地保险箱
          await CryptoVault.save({ session: state.session }, pass);

          if (data.status === 'pending') {
            enterPendingView();
          } else {
            await enterDashboard();
          }
        } catch (err) {
          showError(err.message || '配对失败，请检查邀请码是否有效');
        } finally {
          btn.disabled = false;
          btn.textContent = '立即配对';
        }
      });
    }

    // 复制指纹
    const btnCopy = document.getElementById('btn-copy-fp');
    if (btnCopy) {
      btnCopy.addEventListener('click', () => {
        const fp = document.getElementById('pending-fingerprint').textContent;
        navigator.clipboard.writeText(fp).then(() => {
          btnCopy.textContent = '已复制';
          setTimeout(() => btnCopy.textContent = '复制', 2000);
        });
      });
    }

    // 取消 pending
    const btnCancelPending = document.getElementById('btn-cancel-pending');
    if (btnCancelPending) {
      btnCancelPending.addEventListener('click', async () => {
        await CryptoVault.clear();
        showView('pair');
      });
    }

    // 锁屏
    const btnLock = document.getElementById('btn-lock');
    if (btnLock) {
      btnLock.addEventListener('click', () => {
        state.session = null;
        document.getElementById('unlock-passphrase').value = '';
        showView('unlock');
      });
    }

    // 刷新应用列表
    const btnRefresh = document.getElementById('btn-refresh-apps');
    if (btnRefresh) {
      btnRefresh.addEventListener('click', () => loadApps());
    }

    // 切换节点
    const nodeSelector = document.getElementById('node-selector');
    if (nodeSelector) {
      nodeSelector.addEventListener('change', (e) => {
        state.currentNodeId = e.target.value;
        updateNodeBanner();
        loadApps();
      });
    }

    // 设置弹窗
    const btnSettings = document.getElementById('btn-settings');
    const modalSettings = document.getElementById('modal-settings');
    const btnCloseSettings = document.getElementById('btn-close-settings');
    const btnLogout = document.getElementById('btn-logout');

    if (btnSettings && modalSettings) {
      btnSettings.addEventListener('click', () => {
        document.getElementById('settings-fingerprint').textContent = state.session ? state.session.fingerprint : '-';
        document.getElementById('settings-origin').textContent = window.location.origin;
        document.getElementById('settings-expires').textContent = state.session && state.session.expiresAt ? state.session.expiresAt : '30 天内有效';
        modalSettings.style.display = 'flex';
      });
    }
    if (btnCloseSettings && modalSettings) {
      btnCloseSettings.addEventListener('click', () => {
        modalSettings.style.display = 'none';
      });
    }
    if (btnLogout) {
      btnLogout.addEventListener('click', async () => {
        if (confirm('确定要退出登录并删除本地凭据吗？')) {
          try {
            await api('/__remote_everything_web_logout', { method: 'POST' });
          } catch (e) {}
          await CryptoVault.clear();
          state.session = null;
          modalSettings.style.display = 'none';
          showView('pair');
        }
      });
    }
  }

  // 进入审批等待视图并启动 5s 静默轮询
  function enterPendingView() {
    showView('pending');
    document.getElementById('pending-devicename').textContent = state.session.deviceName;
    document.getElementById('pending-fingerprint').textContent = state.session.fingerprint;
    document.getElementById('pending-cmd').textContent = `remote-everything-lan-server device --state <PATH> approve ${state.session.fingerprint}`;

    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = setInterval(async () => {
      try {
        const res = await api('/__remote_everything_web_activate', { method: 'POST' });
        const data = await res.json();
        if (res.status === 200 && data.ok && data.status === 'approved') {
          clearInterval(state.pollTimer);
          state.pollTimer = null;
          state.session.status = 'approved';
          await enterDashboard();
        }
      } catch (e) {}
    }, 5000);
  }

  // 进入主控制台
  async function enterDashboard() {
    showView('dashboard');
    await loadNodes();
    await loadApps();
  }

  // 加载节点列表
  async function loadNodes() {
    try {
      const res = await api('/__remote_everything/nodes');
      const data = await res.json();
      if (data && Array.isArray(data.nodes)) {
        state.nodes = data.nodes;
        renderNodeSelector();
      }
    } catch (err) {
      console.error('加载节点失败', err);
    }
  }

  function renderNodeSelector() {
    const sel = document.getElementById('node-selector');
    if (!sel) return;
    sel.innerHTML = '';
    state.nodes.forEach((n) => {
      const opt = document.createElement('option');
      opt.value = n.id;
      opt.textContent = n.name || n.id.slice(0, 12);
      sel.appendChild(opt);
    });

    if (state.nodes.length > 0) {
      if (!state.currentNodeId || !state.nodes.find(n => n.id === state.currentNodeId)) {
        state.currentNodeId = state.nodes[0].id;
      }
      sel.value = state.currentNodeId;
    }
    updateNodeBanner();
  }

  function updateNodeBanner() {
    const cur = state.nodes.find(n => n.id === state.currentNodeId);
    const nameEl = document.getElementById('current-node-name');
    const metaEl = document.getElementById('current-node-meta');
    if (cur) {
      if (nameEl) nameEl.textContent = cur.name || '默认节点';
      if (metaEl) metaEl.textContent = `Node ID: ${cur.id}`;
    }
  }

  // 加载当前节点应用
  async function loadApps() {
    if (!state.currentNodeId) return;
    const grid = document.getElementById('apps-grid');
    const emptyEl = document.getElementById('empty-apps');
    const countEl = document.getElementById('app-count');

    try {
      const res = await api('/__remote_everything/apps');
      const data = await res.json();

      const dot = document.getElementById('node-status-dot');
      const badge = document.getElementById('current-node-badge');

      if (!data.ok || !data.computer_connected) {
        if (dot) dot.className = 'node-status-indicator offline';
        if (badge) { badge.className = 'badge offline'; badge.textContent = '离线'; }
        if (grid) grid.innerHTML = '';
        if (emptyEl) { emptyEl.style.display = 'block'; emptyEl.querySelector('p').textContent = '节点计算机当前处于离线状态'; }
        if (countEl) countEl.textContent = '离线';
        return;
      }

      if (dot) dot.className = 'node-status-indicator';
      if (badge) { badge.className = 'badge'; badge.textContent = '在线'; }

      state.apps = data.apps || [];
      if (countEl) countEl.textContent = `${state.apps.length} 个应用`;

      if (state.apps.length === 0) {
        if (grid) grid.innerHTML = '';
        if (emptyEl) { emptyEl.style.display = 'block'; emptyEl.querySelector('p').textContent = '该节点没有登记任何受管应用'; }
        return;
      }

      if (emptyEl) emptyEl.style.display = 'none';
      renderAppsGrid();
    } catch (err) {
      console.error('加载应用异常', err);
    }
  }

  function renderAppsGrid() {
    const grid = document.getElementById('apps-grid');
    if (!grid) return;
    grid.innerHTML = '';

    state.apps.forEach((app) => {
      const card = document.createElement('div');
      card.className = 'app-card';

      const initial = (app.title || app.id || 'A').charAt(0).toUpperCase();
      const appState = app.state || 'stopped';

      card.innerHTML = `
        <div class="app-card-top">
          <div class="app-avatar">${initial}</div>
          <div class="app-card-details">
            <div class="app-card-title">${escapeHTML(app.title || app.id)}</div>
            <div class="app-card-id">${escapeHTML(app.id)}</div>
            <div class="app-status-row">
              <span class="app-status-dot ${appState}"></span>
              <span class="app-status-text">${formatState(appState)}</span>
            </div>
          </div>
        </div>
        <div class="app-card-actions">
          ${appState === 'ready' ? `
            <button class="btn btn-primary btn-sm btn-open" data-id="${app.id}">打开应用</button>
            <button class="btn btn-secondary btn-sm btn-stop" data-id="${app.id}">停止</button>
          ` : `
            <button class="btn btn-primary btn-sm btn-start" data-id="${app.id}">启动应用</button>
          `}
        </div>
      `;

      // 绑定动作
      const btnOpen = card.querySelector('.btn-open');
      if (btnOpen) {
        btnOpen.addEventListener('click', () => openApp(app.id));
      }
      const btnStart = card.querySelector('.btn-start');
      if (btnStart) {
        btnStart.addEventListener('click', () => startApp(app.id, btnStart));
      }
      const btnStop = card.querySelector('.btn-stop');
      if (btnStop) {
        btnStop.addEventListener('click', () => stopApp(app.id, btnStop));
      }

      grid.appendChild(card);
    });
  }

  function formatState(s) {
    switch (s) {
      case 'ready': return '运行中';
      case 'starting': return '正在启动...';
      case 'stopped': return '已停止';
      case 'errored': return '运行异常';
      default: return s;
    }
  }

  function escapeHTML(str) {
    return (str || '').replace(/[&<>'"]/g, tag => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[tag] || tag));
  }

  // 启动应用
  async function startApp(appId, btn) {
    btn.disabled = true;
    btn.textContent = '启动中...';
    try {
      await api(`/__remote_everything/apps/${appId}/start`, { method: 'POST' });
      await loadApps();
    } catch (err) {
      alert('启动失败：' + err.message);
    } finally {
      btn.disabled = false;
    }
  }

  // 停止应用
  async function stopApp(appId, btn) {
    if (!confirm(`确定要停止应用 ${appId} 吗？`)) return;
    btn.disabled = true;
    btn.textContent = '停止中...';
    try {
      await api(`/__remote_everything/apps/${appId}/stop`, { method: 'POST' });
      await loadApps();
    } catch (err) {
      alert('停止失败：' + err.message);
    } finally {
      btn.disabled = false;
    }
  }

  // 打开应用（跳转专属 origin）
  async function openApp(appId) {
    try {
      // 避免自动追踪重定向，手动获取 302 的 Location 并在新标签页中打开
      const res = await api(`/__remote_everything/open/${appId}`, {
        redirect: 'manual',
      });
      // 浏览器在 manual 模式下 opacity redirect 状态为 0 或 302
      let location = res.headers.get('Location');
      if (!location) {
        // 如果无法获取 Location，则请求 JSON fallback 或直接以同 host 解析
        const json = await res.json().catch(() => null);
        if (json && json.location) location = json.location;
      }
      if (location) {
        window.open(location, '_blank');
      } else {
        // 如果直接被跟随重定向或者同源，直接在新窗口打开该路径
        window.open(`/__remote_everything/open/${appId}`, '_blank');
      }
    } catch (err) {
      console.error('打开应用异常', err);
      window.open(`/__remote_everything/open/${appId}`, '_blank');
    }
  }

  // 启动
  window.addEventListener('DOMContentLoaded', init);
})();
