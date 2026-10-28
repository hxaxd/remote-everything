// Production ArkTS logic in a host VM. Platform services are replaced; this does not verify ArkWeb or devices.
// Run with TYPESCRIPT_MODULE pointing to the SDK TypeScript package.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_MODULE || 'typescript');
const root = path.resolve(__dirname,'../entry/src/main/ets');
function runtime(extra = {}) {
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
      utf8Hex:s=>Buffer.from(s).toString('hex'),wipe:b=>b.fill(0)};
    if (modules.has(file)) return modules.get(file).exports;
    const module={exports:{}}; modules.set(file,module);
    const source=fs.readFileSync(file,'utf8');
    const js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,experimentalDecorators:true}}).outputText;
    const req=name=>name.startsWith('@kit.')?{util:{Base64Helper:class {encodeToStringSync(bytes){return Buffer.from(bytes).toString('base64url');}},Type:{BASIC_URL_SAFE:1}},hilog:{error:()=>{}}}:
      name.startsWith('.')?load(path.resolve(path.dirname(file),name+'.ets')):require(name);
    vm.runInContext('(function(exports,require,module){'+js+'\n})',context,{filename:file})(module.exports,req,module);
    return module.exports;
  }
  return {load,timers,async next(){const entry=[...timers].sort((a,b)=>a[1].at-b[1].at)[0];assert(entry,'expected a scheduled poll');timers.delete(entry[0]);now=entry[1].at;await entry[1].f();await Promise.resolve();}};
}
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
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
    check('multiple pending gateways survive a store restart',()=>assert.equal(restarted.readAll().length,2));
    await restarted.discard(a.origin);
    check('abandoning one gateway leaves the other pending',()=>assert.equal(restarted.readAll()[0].origin,b.origin));
    const {NodeCacheStore}=isolated.load('core/store/NodeCacheStore');const cache=new NodeCacheStore();
    const tunnel=new M.GatewayPath(a.origin,'ref',true,1,true,null,M.LinkKind.Tunnel);
    cache.write(a.origin,[new M.Node(a.node,'A',[tunnel,road])],Date.now());
    check('node cache stores one origin and retains declared tunnel links',()=>{const loaded=cache.read(a.origin,'ref');assert(loaded);assert.equal(loaded.nodes[0].paths.length,1);assert.equal(loaded.nodes[0].paths[0].link,M.LinkKind.Tunnel);});
  }
  console.log(`${assertions} Harmony host regression groups passed; native execution remains separate.`);
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>clearTimeout(watchdog));
