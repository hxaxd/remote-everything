const {chromium} = require(process.env.PLAYWRIGHT_MODULE);
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
(async () => {
  const browser = await chromium.launch({channel: process.env.BROWSER_CHANNEL || 'msedge', headless: true});
  try {
    const origin = process.env.LOADING_TEST_ORIGIN;
    const output = path.resolve(process.env.WEB_TEST_OUTPUT || '../../dist/web-loading');
    await fs.mkdir(output, {recursive:true});
    for (const theme of ['dark','light']) {
      // Deliberately oppose the OS appearance: the control page's selection must win.
      const context = await browser.newContext({colorScheme: theme === 'dark' ? 'light' : 'dark',
        extraHTTPHeaders: {'X-Remote-Everything-Web-Token': process.env.LOADING_TEST_TOKEN}});
      const errors = [];
      const page = await context.newPage(); page.on('pageerror',error=>errors.push(error.message));
      await context.request.get(origin+'/__remote_everything/open/test', {headers:{'X-Remote-Everything-Web-Appearance':theme}});
      for (const reload of [false,true]) {
        if (reload) await page.reload(); else await page.goto(origin+'/');
        const cover = page.locator('[data-remote-everything-loading]');
        await cover.waitFor({state:'visible'});
        await page.waitForTimeout(400);
        assert.equal(await cover.isVisible(),true,'blank document must remain covered');
        assert.equal(await page.evaluate(()=>performance.getEntriesByName('first-contentful-paint').length),0,'the spinner must not itself trigger content paint');
        assert.equal(await cover.evaluate(el=>getComputedStyle(el).backgroundColor),theme==='dark'?'rgb(28, 30, 36)':'rgb(255, 255, 255)');
        assert.equal(await page.evaluate(()=>document.querySelector('meta[name="color-scheme"]').content),theme);
        await page.screenshot({path:path.join(output,`cover-${theme}-${reload?'reload':'open'}.png`)});
        await page.evaluate(theme=>{
          document.body.style.backgroundColor=theme==='dark'?'#17191e':'#fff';
          document.body.style.color=theme==='dark'?'#fff':'#111';
          document.getElementById('root').textContent='Application content';
        },theme);
        await cover.waitFor({state:'detached'});
        assert.equal(await page.locator('#root').textContent(),'Application content');
        await page.screenshot({path:path.join(output,`content-${theme}-${reload?'reload':'open'}.png`)});
      }
      assert.deepEqual(errors,[]);
      await context.close();
    }
    console.log('PASS: authenticated HTML injection, CSP self, opposing OS appearance, blank/slow loading, first content reveal and reload in dark/light.');
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
