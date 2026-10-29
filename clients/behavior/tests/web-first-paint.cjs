const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');

let browser, server;
(async () => {
  const root = path.resolve(__dirname, '../../..');
  const android = await fs.readFile(path.join(root, 'clients/android/app/src/main/java/com/remoteeverything/app/web/AppWebActivity.kt'), 'utf8');
  const ios = await fs.readFile(path.join(root, 'clients/ios/RemoteEverything/App/Web/GatewayWebView.swift'), 'utf8');
  const scripts = [
    ['Android', android.match(/private fun observeFirstPaint[\s\S]*?evaluateJavascript\("""([\s\S]*?)"""\.trimIndent\(\), null\)/)?.[1]],
    ['iOS', ios.match(/static let firstPaintScript = """([\s\S]*?)"""/)?.[1]],
  ];
  const bridge = `window.paintSignals = 0;
    window.RemoteEverythingPaint = {painted: () => window.paintSignals++};
    window.webkit = {messageHandlers: {RemoteEverythingPaint: {postMessage: () => window.paintSignals++}}};`;
  server = http.createServer((request, response) => {
    response.setHeader('Content-Type', 'text/html; charset=utf-8');
    response.end('<!doctype html><html><head><title>First paint</title></head><body></body></html>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  browser = await chromium.launch({channel: process.env.BROWSER_CHANNEL || 'msedge', headless: true});
  for (const [platform, script] of scripts) {
    assert(script, `${platform}: production first-paint observer not found`);
    for (const late of [false, true]) {
      const page = await browser.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      // iOS installs at document start; Android installs after visible commit.
      if (!late && platform === 'iOS') await page.addInitScript({content: bridge + script});
      await page.goto(`http://127.0.0.1:${server.address().port}/`);
      if (late || platform === 'Android') await page.evaluate(bridge);
      if (!late && platform === 'Android') await page.evaluate(script);
      await page.waitForTimeout(150);
      assert.equal(await page.evaluate(() => window.paintSignals), 0, `${platform}: blank white document must stay covered`);
      await page.evaluate(() => {
        document.documentElement.style.background = '#141414';
        document.body.style.color = 'white';
        document.body.textContent = 'Application content';
      });
      await page.waitForFunction(() => performance.getEntriesByName('first-contentful-paint').length > 0);
      if (late) await page.evaluate(script);
      await page.waitForFunction(() => window.paintSignals > 0);
      assert.equal(await page.evaluate(() => window.paintSignals), 1);
      assert.deepEqual(errors, []);
      await page.close();
    }
  }
  console.log('PASS: production Android/iOS paint observers keep blank documents covered and reveal first content, including buffered paint. Native frame presentation requires device verification.');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  await browser?.close();
  server?.close();
});
