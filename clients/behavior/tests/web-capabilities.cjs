const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('node:fs/promises');
const path=require('node:path');
const http=require('node:http');
const assert=require('node:assert/strict');
let browser,server;
(async()=>{
  const fixture=await fs.readFile(path.resolve(__dirname,'../web-capabilities.html'));
  server=http.createServer((request,response)=>{response.setHeader('Content-Type','text/html; charset=utf-8');response.end(fixture);});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  browser=await chromium.launch({channel:process.env.BROWSER_CHANNEL || 'msedge',headless:true});
  const context=await browser.newContext({acceptDownloads:true});
  const page=await context.newPage();
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/web-capabilities.html`);
  const popupEvent=context.waitForEvent('page');await page.locator('#popup').click();const popup=await popupEvent;
  await popup.locator('#finish').click();await page.waitForFunction(()=>document.querySelector('#result').textContent.includes('popup-result: complete'));
  await page.locator('#store').click();await page.waitForFunction(()=>document.querySelector('#result').textContent.includes('store:'));
  const value=await page.evaluate(()=>localStorage.getItem('fixture'));assert(value);
  await page.reload();await page.locator('#read').click();
  await page.waitForFunction(value=>document.querySelector('#result').textContent.includes(`"indexedDB":"${value}"`),value);
  await page.locator('#multiple').setInputFiles([
    {name:'fixture.txt',mimeType:'text/plain',buffer:Buffer.from('fixture')},
    {name:'fixture.png',mimeType:'image/png',buffer:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZVLkAAAAASUVORK5CYII=','base64')}
  ]);
  assert((await page.locator('#result').textContent()).includes('fixture.txt'));
  const downloadEvent=page.waitForEvent('download');await page.locator('#download').click();const download=await downloadEvent;
  assert.equal(download.suggestedFilename(),'client-capability.txt');
  assert.equal(await fs.readFile(await download.path(),'utf8'),'client capability fixture\n');
  assert.deepEqual(errors,[]);
  console.log('PASS: real web fixture popup/opener/return, persistent storage, multiple upload, blob download. Native permissions and pickers require device execution.');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(async()=>{await browser?.close();server?.close();});
