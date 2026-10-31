// Production ArkTS logic in a host VM. Platform services are replaced; this does not verify ArkWeb or devices.
// Run with TYPESCRIPT_MODULE pointing to the SDK TypeScript package.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_MODULE || 'typescript');
const root = path.resolve(__dirname,'../entry/src/main/ets');
function runtime(extra = {}, kits = {}) {
  const modules = new Map(), timers = new Map(); let serial = 0, now = Date.now();
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({console,Promise,Map,Set,Date:Clock,Error,RegExp,Number,JSON,Uint8Array,ArrayBuffer,
    ObservedV2:c=>c,Trace:()=>{},setTimeout:(f,ms)=>{const id=++serial;timers.set(id,{f,at:now+ms});return id;},clearTimeout:id=>timers.delete(id)});
  function load(relative) {
    const file=path.resolve(root,relative.endsWith('.ets')?relative:relative+'.ets');
    if (extra[file]) return extra[file];
    if (file.endsWith(path.normalize('app/ui/Components.ets'))) return {palette:()=>({})};
    if (file.endsWith(path.normalize('core/model/Digest.ets'))) return {
      randomBytes:n=>new Uint8Array(crypto.randomBytes(n)),sha256HexOfText:s=>crypto.createHash('sha256').update(s).digest('hex'),
      sha256:bytes=>new Uint8Array(crypto.createHash('sha256').update(bytes).digest()),toHex:bytes=>Buffer.from(bytes).toString('hex'),base64Encode:bytes=>Buffer.from(bytes).toString('base64'),
      utf8:s=>new Uint8Array(Buffer.from(s)),utf8Hex:s=>Buffer.from(s).toString('hex'),wipe:b=>b.fill(0)};
    if (modules.has(file)) return modules.get(file).exports;
    const module={exports:{}}; modules.set(file,module);
    const source=fs.readFileSync(file,'utf8');
    const js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}}).outputText;
    const req=name=>kits[name] || (name.startsWith('@kit.')?{util:{Base64Helper:class {encodeToStringSync(bytes){return Buffer.from(bytes).toString('base64url');}},Type:{BASIC_URL_SAFE:1}},hilog:{error:()=>{}}}:
      name.startsWith('.')?load(path.resolve(path.dirname(file),name+'.ets')):require(name));
    vm.runInContext('(function(exports,require,module){'+js+'\n})',context,{filename:file})(module.exports,req,module);
    return module.exports;
  }
  return {load,timers,elapse(ms){now+=ms;},async next(){const entry=[...timers].sort((a,b)=>a[1].at-b[1].at)[0];assert(entry,'expected a scheduled poll');timers.delete(entry[0]);now=entry[1].at;await entry[1].f();await Promise.resolve();}};
}
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
const flush=async()=>{for(let turn=0;turn<12;turn++)await Promise.resolve();};
const moduleKey=relative=>path.resolve(root,relative+'.ets');
let assertions=0;
function check(name,body){body();assertions++;console.log('PASS '+name);}
const watchdog=setTimeout(()=>{console.error('Host regression stalled');process.exitCode=1;process.exit(1);},15000);
(async()=>{
  const r=runtime(), M=r.load('core/model/Models'), D=r.load('core/api/Dto'), S=r.load('app/State');
  const Merge=r.load('core/api/Merge'), {PathSelector}=r.load('core/pathselect/PathSelector');
  const paths=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../behavior/fixtures/paths.json'),'utf8'));
  const tls=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../behavior/fixtures/tls.json'),'utf8'));
  const pinning=r.load('core/api/Pinning');
  check('shared TLS hostname expiry and mismatched-pin counterexamples',()=>{
    for(const entry of tls.cases){const pin=new M.ServerPin(entry.mismatch?'0'.repeat(64):tls.pin.fingerprint,entry.mismatch?'A'.repeat(43)+'=':tls.pin.publicKeyPin);
      assert.equal(pinning.certificateMatchesPin(new Uint8Array(Buffer.from(tls.certificates[entry.certificate],'base64')),pin,entry.host),entry.trusted,entry.host);}
  });
  check('shared private address cases',()=>{for(const c of paths.privateHosts)assert.equal(Merge.isPrivateHost(c.host),c.private,c.host);});
  check('shared declaration fallback and restoration action chain',()=>{
    for(const chain of paths.updates){const selector=new PathSelector();for(const step of chain.steps){
      const node=new M.Node('node',chain.name,step.paths.map(p=>new M.GatewayPath(p.origin,p.origin,p.reachable,p.latencyMs,p.isPrivate,null,p.link)));
      const chosen=selector.choose(node);assert.equal(chosen?.origin,step.chosen);assert.equal(chosen?.link,step.link);selector.remember([node]);
    }}
  });
  const wire=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../behavior/fixtures/wire-cases.json'),'utf8'));
  const setup=r.load('core/setup/SetupUri'), release=r.load('core/update/UpdateChecker');
  const decode={nodes:D.decodeNodes,apps:D.decodeCatalog,catalog:D.decodeCatalog,control:D.decodeControl,pair:D.decodePairing,pairing:D.decodePairing,error:body=>{if(D.failureCode(body)===null)throw new Error('invalid refusal');},
    release:release.decodeRelease,setup:body=>setup.parseSetupUri(JSON.parse(body).uri),activation:body=>{try{const c=D.decodeCatalog(body);r.load('core/api/Wire').validateActivation(c.computerConnected,c.code);}catch(error){if(D.failureCode(body)===null)throw error;}}};
  check('shared strict wire cases',()=>{for(const c of wire.cases){assert(decode[c.kind],c.kind);let accepted=true;try{decode[c.kind](JSON.stringify(c.payload));}catch{accepted=false;}assert.equal(accepted,c.expect==='accept',c.name);}});
  const identity=new M.Identity('https://first.example','Phone','f'.repeat(64),'ref',null,1);
  const road=new M.GatewayPath(identity.origin,'ref',true,1,false,null);
  const rows=new Map(['A','B'].map(id=>[id,new S.NodeRow(new M.Node(id,id,[road]),M.NodeStatus.OnlineTunnel)]));
  const app=(id,name=id,code=M.AppState.Ready)=>new M.AppInfo(id,name,'','','#123456','',code==='ready'||code==='starting',code==='ready'||code==='stopping',code);
  const catalog=name=>new D.CatalogResponse(true,true,'ready',[app('dsh',name)]);
  const nodes={nodeRow:id=>rows.get(id),selectorForCatalog:()=>new PathSelector(),identitiesSnapshot:()=>[identity],markPath:()=>{}};
  const {CatalogController}=r.load('app/CatalogController');
  {
    const pending=deferred(),entered=deferred();let calls=0;
    const c=new CatalogController({connect:async()=>{},apps:async id=>{if(++calls===1){entered.resolve();return pending.promise;}return catalog('fresh');}},{},nodes);
    const first=c.loadCatalog('A');await entered.promise;
    await c.loadCatalog('B');await c.loadCatalog('A');pending.resolve(catalog('old'));await first;
    check('A to B to A does not revive the old catalog',()=>assert.equal(c.catalog.apps[0].name,'fresh'));
  }
  {
    const pending=deferred(),entered=deferred();let calls=0;
    const c=new CatalogController({connect:async()=>{},apps:async()=>{if(++calls===1){entered.resolve();return pending.promise;}return catalog('fresh');}},{},nodes);
    const first=c.loadCatalog('A');await entered.promise;await c.loadCatalog('A');pending.resolve(catalog('old'));await first;
    check('older same-visit catalogs cannot replace the latest answer',()=>assert.equal(c.catalog.apps[0].name,'fresh'));
  }
  {
    let commands=0;
    const status=new D.ControlResponse(true,'status',true,true,true,D.ControlCode.Ready,null,null);
    const c=new CatalogController({connect:async()=>{},apps:async()=>new D.CatalogResponse(true,true,'ready',[app('one'),app('two')]),
      status:async()=>status,stop:async()=>{commands++;throw new Error('reply lost');}},{},nodes);
    await c.loadCatalog('A');await Promise.all(c.catalog.apps.map(a=>c.toggleApp('A',a)));
    check('each application keeps an independent settle poll after lost replies',()=>{assert.equal(commands,2);assert.equal(r.timers.size,2);});
    await r.next();await r.next();
    check('reconciliation reads never resend a control',()=>assert.equal(commands,2));
  }
  {
    const notices=[];
    const status=new D.ControlResponse(true,'status',true,false,false,D.ControlCode.Stopped,null,null);
    const c=new CatalogController({connect:async()=>{},apps:async()=>catalog('DSH'),status:async()=>status,
      stop:async()=>new D.ControlResponse(false,'stop',true,false,false,D.ControlCode.Stopped,null,'stop_command_failed')},{},nodes);
    c.onToast=message=>notices.push(message);
    await c.loadCatalog('A');await c.toggleApp('A',c.catalog.apps[0]);await r.next();
    check('a failed stop helper is reported even when the app has stopped',()=>
      assert(notices.includes(r.load('core/model/MessageKeys').MessageKeys.ERROR_STOP_FAILED)));
  }
  {
    class Transport {
      constructor(){this.sessions=new Map();this.liveClosures=0;Transport.instance=this;}
      has(origin){return this.sessions.has(origin);}open(origin,identity){this.sessions.set(origin,identity);}
      close(origin){if(this.sessions.has(origin))this.liveClosures++;this.sessions.delete(origin);}closeAll(){this.sessions.clear();}
    }
    class SessionIdentity {constructor(archive,password,pin){Object.assign(this,{archive,password,pin});}}
    const isolated=runtime({[moduleKey('core/api/Transport')]:{Transport,SessionIdentity}});
    const {ProtocolClient}=isolated.load('core/api/ProtocolClient');
    let version=0,waiting=deferred();
    const vault={version:()=>version,material:async()=>waiting.promise};
    const client=new ProtocolClient(vault),material={archive:new Uint8Array([1]),password:'p',wipe:()=>{}};
    const pending=client.connect('https://gateway.example',null);
    client.releaseAll();waiting.resolve(material);await assert.rejects(pending);
    check('releaseAll fences a connection that is still opening',()=>assert.equal(Transport.instance.sessions.size,0));
    waiting=deferred();const fresh=client.connect('https://gateway.example',null);waiting.resolve(material);await fresh;
    version++;waiting=deferred();const replacement=client.connect('https://gateway.example',null);waiting.resolve({...material,password:'new'});await replacement;
    check('same pin with a renewed identity opens a fresh transport',()=>assert.equal(Transport.instance.sessions.get('https://gateway.example').password,'new'));
    client.releaseAll();
    const firstMaterial=deferred(),secondMaterial=deferred();let reads=0,wipes=0;
    const concurrent=new ProtocolClient({version:()=>0,material:()=>++reads===1?firstMaterial.promise:secondMaterial.promise});
    const first=concurrent.connect('https://gateway.example',null),second=concurrent.connect('https://gateway.example',null);
    firstMaterial.resolve({...material,wipe:()=>wipes++});await first;
    const session=Transport.instance.sessions.get('https://gateway.example');
    secondMaterial.resolve({...material,wipe:()=>wipes++});await second;
    check('concurrent connects preserve the live session and wipe both credential copies',()=>{
      assert.equal(Transport.instance.liveClosures,0);
      assert.equal(Transport.instance.sessions.get('https://gateway.example'),session);
      assert.equal(wipes,2);
    });
  }
  {
    const files=new Map();const atomic={read:f=>files.get(f)??null,readText:f=>files.get(f)??null,writeAtomic:(f,s)=>files.set(f,s),removeWithTemporary:f=>files.delete(f),ensureDirectory:()=>{},originKey:s=>Buffer.from(s).toString('hex')};
    const isolated=runtime({[moduleKey('core/store/AtomicFile')]:{AtomicFile:atomic}});
    const {StagedSetup,StagedSetupStore}=isolated.load('core/pairing/StagedSetup');
    const vault={forget:async()=>{},presence:async()=> 'present'};
    const store=new StagedSetupStore(vault);
    const a=new StagedSetup('https://a.example','a'.repeat(64),'A','Phone','f'.repeat(64),'ref',Date.now()+600000,null);
    const b=new StagedSetup('https://b.example','b'.repeat(64),'B','Phone','e'.repeat(64),'ref2',Date.now()+600000,null);
    store.stage(a);store.stage(b);const restarted=new StagedSetupStore(vault);
    check('only the newest pending gateway survives a store restart',()=>assert.equal(restarted.readAll().length,1));
    await restarted.discard(a.origin);
    check('abandoning one gateway leaves the other pending',()=>assert.equal(restarted.readAll()[0].origin,b.origin));
    const {NodeCacheStore}=isolated.load('core/store/NodeCacheStore');const cache=new NodeCacheStore();
    const tunnel=new M.GatewayPath(a.origin,'ref',true,1,true,null,M.LinkKind.Tunnel);
    cache.write(a.origin,[new M.Node(a.node,'A',[tunnel,road])],Date.now());
    check('node cache stores one origin and retains declared tunnel links',()=>{const loaded=cache.read(a.origin,'ref');assert(loaded);assert.equal(loaded.nodes[0].paths.length,1);assert.equal(loaded.nodes[0].paths[0].link,M.LinkKind.Tunnel);});
  }
  {
    const isolated=runtime();
    const {PairingSession}=isolated.load('app/PairingSession');
    const {PairingResult}=isolated.load('core/pairing/PairingService');
    const staged={origin:'https://approval.example',node:'a'.repeat(64),nodeName:'Desk',deviceName:'Phone',serverPin:null};
    const records=[staged],entered=deferred(),reply=deferred();let calls=0;
    const service={pair:async()=>PairingResult.waiting(null),resume:async()=>{calls++;if(calls===1){entered.resolve();await reply.promise;}return PairingResult.waiting(null);}};
    const session=new PairingSession(service,{readAll:()=>records},{reloadIdentities:()=>{},identitiesSnapshot:()=>[],refreshNodes:async()=>{}});
    session.beginApprovalPolling();
    const first=isolated.next();await entered.promise;
    session.beginApprovalPolling();await session.retryStaged(staged.origin);
    check('approval retry cannot duplicate an in-flight request or timer',()=>{assert.equal(calls,1);assert.equal(isolated.timers.size,0);assert.deepEqual(Array.from(session.checkingOrigins),[staged.origin]);});
    session.varForeground=false;session.stopApprovalPolling();reply.resolve();await first;
    check('late approval reply cannot restart polling in the background',()=>{assert.equal(isolated.timers.size,0);assert.equal(session.checkingOrigins.length,0);assert.equal(session.pendingSetups.length,1);});
    session.varForeground=true;
    const retry=session.retryStaged(staged.origin);await flush();
    check('fast approval replies keep feedback visible for the shared minimum',()=>{
      assert.deepEqual(Array.from(session.checkingOrigins),[staged.origin]);
      assert.equal(isolated.timers.size,1);
      assert.equal(isolated.load('core/model/Cadence').Cadence.approvalFeedbackMinMs,1500);
    });
    await session.retryStaged(staged.origin);
    check('repeated retry during feedback does not send another request',()=>assert.equal(calls,2));
    await isolated.next();await retry;
    for(let tick=0;tick<125;tick++){
      const poll=isolated.next();await flush();await isolated.next();await poll;
    }
    check('approval checks continue automatically beyond ten minutes',()=>{assert.equal(session.pendingSetups.length,1);assert.equal(session.checkingOrigins.length,0);assert.equal(isolated.timers.size,1);});
    records.length=0;await isolated.next();
    check('approval checks end when no pending records remain',()=>assert.equal(isolated.timers.size,0));
    session.stopApprovalPolling();
  }
  {
    const isolated=runtime(),{PairingSession}=isolated.load('app/PairingSession'),{PairingResult}=isolated.load('core/pairing/PairingService');
    const staged={origin:'https://feedback.example',node:'b'.repeat(64),nodeName:'Desk',deviceName:'Phone',serverPin:null};
    const records=[staged],reply=deferred();
    const session=new PairingSession({resume:async()=>{await reply.promise;return PairingResult.waiting(null);}},
      {readAll:()=>records},{reloadIdentities:()=>{},identitiesSnapshot:()=>[],refreshNodes:async()=>{}});
    const slow=session.retryStaged(staged.origin);isolated.elapse(2000);reply.resolve();await slow;
    check('slow approval checks do not add another minimum delay',()=>{
      assert.equal(session.checkingOrigins.length,0);assert.equal(isolated.timers.size,1);
    });
    session.stopApprovalPolling();
    let finished=false;
    const approved=new PairingSession({resume:async()=>{records.length=0;return PairingResult.activated();}},
      {readAll:()=>records},{reloadIdentities:()=>{},identitiesSnapshot:()=>[],refreshNodes:async()=>{}});
    approved.onFinished=()=>{finished=true;};
    const success=approved.retryStaged(staged.origin);await flush();
    check('approval navigation is immediate while minimum feedback completes',()=>assert.equal(finished,true));
    await isolated.next();await success;
  }
  {
    const files=new Map(),atomic={readText:f=>files.get(f)??null,writeAtomic:(f,s)=>files.set(f,s),removeWithTemporary:f=>files.delete(f),ensureDirectory:()=>{},originKey:s=>Buffer.from(s).toString('hex')};
    const isolated=runtime({[moduleKey('core/store/AtomicFile')]:{AtomicFile:atomic}});
    const {PairingService,PairingVerdict}=isolated.load('core/pairing/PairingService');
    const {StagedSetupStore}=isolated.load('core/pairing/StagedSetup');
    const credentials=new Map([['https://a.example','live-A'],['https://b.example','live-B']]),active=new Map();
    const originals=[{origin:'https://a.example',credentialRef:'uri-live-A',certificateFingerprint:'a'.repeat(64)},
      {origin:'https://b.example',credentialRef:'uri-live-B',certificateFingerprint:'b'.repeat(64)}];
    let identities=originals.slice(),admitted=false,heldNode='',hold=null,connectRefs=[];
    const vault={version:()=>0,adopt:async(key)=>{credentials.set(key,'new');return {fingerprint:'f'.repeat(64),keyUri:'uri-'+key};},
      forget:async key=>{credentials.delete(key);},webIdentity:async key=>'uri-'+key,
      promote:(origin,key)=>{const old=active.get(origin)??origin;active.set(origin,key);return old;},retire:async key=>credentials.delete(key)};
    const transaction=new StagedSetupStore(vault);
    const client={releaseAll:()=>{},release:()=>{},pair:async()=>({credentialPkcs12:'data',certificateFingerprint:'f'.repeat(64),deviceName:'Phone',pendingExpiresAt:'2099-01-01T00:00:00Z'}),
      connect:async(origin,pin,ref)=>{connectRefs.push(ref);assert(credentials.has(ref));},
      activate:async(origin,node)=>{if(node===heldNode&&hold){await hold.promise;return {pending:false,failure:null};}return {pending:!admitted,failure:null};}};
    const service=new PairingService(client,vault,transaction,{readIdentities:()=>identities,writeIdentities:value=>{identities=value;}});
    const invite=(origin,node,invitation)=>({origin,node,nodeName:'Desk',invitation,serverPin:null});
    const a=invite('https://a.example','a'.repeat(64),'first'),b=invite('https://b.example','b'.repeat(64),'second');
    await service.pair(a,'Phone');const first=transaction.read();
    check('pending replacement keeps existing credentials and identities untouched',()=>{
      assert.equal(credentials.get(a.origin),'live-A');assert.equal(credentials.get(b.origin),'live-B');assert.deepEqual(identities,originals);assert.notEqual(first.credentialRef,a.origin);
    });
    service.cancelPending();await flush();
    check('cancelling pairing deletes only its temporary credential',()=>{
      assert(!credentials.has(first.credentialRef));assert.equal(credentials.get(a.origin),'live-A');assert.equal(credentials.get(b.origin),'live-B');assert.deepEqual(identities,originals);
    });
    await service.pair(a,'Phone');const replaced=transaction.read();await service.pair(b,'Phone');
    check('a new gateway request replaces the sole pending request',()=>{
      assert.equal(transaction.readAll().length,1);assert.equal(transaction.read().origin,b.origin);assert(!credentials.has(replaced.credentialRef));assert.deepEqual(identities,originals);
    });
    heldNode=b.node;hold=deferred();const late=service.resume(transaction.read(),null);await flush();
    await service.pair({...a,invitation:'third'},'Phone');const newest=transaction.read();hold.resolve();await late;
    check('late approval of a superseded request cannot promote or replace the newest request',()=>{
      assert.equal(transaction.read().credentialRef,newest.credentialRef);assert.deepEqual(identities,originals);assert.equal(active.size,0);
    });
    admitted=true;heldNode='';await service.resume(newest,null);await flush();
    check('approved replacement retires only its previous gateway credential',()=>{
      assert.equal(transaction.read(),null);assert.equal(active.get(a.origin),newest.credentialRef);
      assert(!credentials.has(a.origin));assert.equal(credentials.get(b.origin),'live-B');assert.equal(identities.find(i=>i.origin===b.origin),originals[1]);
      assert.equal(identities.find(i=>i.origin===a.origin).credentialRef,'uri-'+newest.credentialRef);
    });
  }
  {
    const isolated=runtime(),M=isolated.load('core/model/Errors');
    const {PairingService,PairingVerdict}=isolated.load('core/pairing/PairingService');
    for(const code of [M.ErrorCode.NotFound,M.ErrorCode.Unauthorized]) {
      let current={origin:'https://approval.example',node:'a'.repeat(64),nodeName:'Desk',serverPin:null,expired:false,certificateFingerprint:'f'.repeat(64)};
      const staged=current;
      const service=new PairingService({connect:async()=>{},release:()=>{},activate:async()=>({pending:false,failure:new M.ClientError(code,404)})},{},
        {read:()=>current,discard:async()=>{current=null;}},{});
      const result=await service.resume(staged,null);
      check(code===M.ErrorCode.NotFound?'temporary node absence retains approval and automatic retry':'final activation refusal ends the pending request',()=>{
        assert.equal(result.verdict,code===M.ErrorCode.NotFound?PairingVerdict.WaitingApproval:PairingVerdict.Failed);
        assert.equal(current!==null,code===M.ErrorCode.NotFound);
      });
    }
  }
  for (const failClear of [false,true]) {
    const calls=[],files=new Map();let cookies=[];
    const atomic={exists:f=>files.has(f),readBytes:f=>files.get(f),ensureDirectory:()=>{},writeBytesAtomic:(f,b)=>files.set(f,b.slice())};
    class HuksVault {
      async seal(alias,scope,password,data){calls.push('save');return data.slice();}
      async unseal(alias,scope,data){return {archive:data.slice(),wipe:()=>{}};}
    }
    const webview={WebDestroyMode:{FAST_MODE:1},WebviewController:{setWebDestroyMode:()=>{}},
      WebHttpCookieSameSitePolicy:{NONE:0,LAX:1,STRICT:2},
      WebCookieManager:{clearAllCookies:async()=>{},clearAllCookiesSync:()=>{calls.push('clear-cookies');cookies=[];},existCookie:()=>cookies.length>0,
        fetchAllCookies:async()=>{calls.push('snapshot');return cookies;},configCookie:async(url,header)=>{cookies=[{name:'session',value:header.split(';')[0].split('=')[1]}];}},
      WebStorage:{deleteAllData:privateMode=>{assert.equal(privateMode,true);calls.push('clear-storage');if(failClear)throw new Error('storage failure');}}};
    const isolated=runtime({[moduleKey('core/store/AtomicFile')]:{AtomicFile:atomic},[moduleKey('core/identity/HuksVault')]:{HuksVault},
      [moduleKey('app/web/WebDownloads')]:{WebDownloads:{allowSession:()=>calls.push('open'),stopSession:()=>calls.push('stop-downloads')}}},
      {'@kit.ArkWeb':{webview},'@kit.ArkTS':{util:{TextDecoder:class {decodeToString(bytes){return Buffer.from(bytes).toString();}}}}});
    const {WebSessions}=isolated.load('app/web/WebSessions');
    const url='https://gateway.example/',scope=await WebSessions.enter(url,'node/a',url);
    cookies=[{name:'session',value:'a',domain:'gateway.example',path:'/',isSessionCookie:true,expiresDate:'',isSecure:true,isHttpOnly:true,samesitePolicy:1}];
    calls.length=0;
    const detached=deferred(),freezing=deferred();
    const leaving=WebSessions.leave(scope,url,async()=>{calls.push('detach');freezing.resolve();await detached.promise;},async()=>calls.push('destroy'));
    await freezing.promise;
    const opening=WebSessions.enter(url,'node/b',url);
    const refused=failClear?assert.rejects(opening):null;
    assert.deepEqual(calls,['stop-downloads','detach']);
    detached.resolve();
    if (failClear) {
      await assert.rejects(leaving);await refused;
      await assert.rejects(WebSessions.enter(url,'node/a',url));
      check('private storage cleanup failure blocks all later web sessions',()=>assert.equal(calls.includes('open'),false));
    } else {
      await leaving;
      const second=await opening;
      check('web switch detaches before snapshot and clears private storage before the next app',()=>{
        assert.deepEqual(calls.slice(0,7),['stop-downloads','detach','snapshot','save','destroy','clear-storage','clear-cookies']);
        assert.equal(cookies.length,0);assert.equal(calls.at(-1),'open');
      });
      await WebSessions.leave(second,url,async()=>{},async()=>{});
    }
  }
  console.log(`${assertions} Harmony host regression groups passed; native execution remains separate.`);
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>clearTimeout(watchdog));
