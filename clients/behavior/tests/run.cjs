const path=require('node:path');
const {spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'../../..');
const env={...process.env,BROWSER_CHANNEL:process.env.BROWSER_CHANNEL || 'chromium',TYPESCRIPT_MODULE:require.resolve('typescript'),PLAYWRIGHT_MODULE:require.resolve('playwright')};
for(const file of ['clients/harmony/tests/controllers.cjs','internal/client/webclient/tests/browser.cjs','clients/behavior/tests/web-capabilities.cjs','clients/behavior/tests/web-first-paint.cjs']){
  const result=spawnSync(process.execPath,[path.join(root,file)],{cwd:root,env,stdio:'inherit'});
  if(result.error)throw result.error;
  if(result.status!==0)process.exit(result.status || 1);
}
