// Browser tests for the Ticker app. Run with tests/run.sh (it starts the servers this file expects).
//   http://localhost:8787  plain server (used with ?demo, no network needed)
//   http://localhost:8788  server whose upstream is tests/mock_yahoo.js, which mimics Yahoo's real response shape
const { chromium } = require('playwright');
const { spawn } = require('child_process');
const path = require('path');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const DEMO = 'http://localhost:8787/?demo', LIVE = 'http://localhost:8788/';
const shots = path.join(__dirname, 'shots');
let failures = 0, mock = null;
const check = (name, cond, detail) => { console.log((cond ? 'ok    ' : 'FAIL  ') + name + (cond || detail === undefined ? '' : '  -> ' + JSON.stringify(detail))); if (!cond) failures++; };
const startMock = async regime => { mock = spawn('node', [path.join(__dirname, 'mock_yahoo.js'), '9911', regime], { stdio: 'ignore' }); await sleep(500); };
const stopMock = async () => { if (mock) mock.kill(); mock = null; await sleep(300); };

(async () => {
  const browser = await chromium.launch();
  const errors = [];
  const open = async (url, w, h, opts) => {
    const ctx = await browser.newContext(Object.assign({ viewport: { width: w, height: h } }, opts || {}));
    const p = await ctx.newPage();
    p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
    p.on('pageerror', e => errors.push(e.message));
    await p.goto(url); await p.waitForSelector('#boot', { state: 'detached', timeout: 20000 }); await sleep(400);
    return p;
  };
  try {
    // ── compact ticker (demo data)
    let p = await open(DEMO, 680, 138);
    check('small window shows the compact ticker', await p.evaluate(() => document.body.className) === 'mode-ticker');
    check('tape lists every stock twice (seamless loop)', await p.locator('#tape-track .ti').count() >= 120);
    check('demo badge is shown', /DEMO/.test(await p.locator('#t-meta').innerText()));
    await p.screenshot({ path: path.join(shots, 'compact.png') });
    p = await open(DEMO, 420, 520);
    check('tall compact window shows the heat board', await p.locator('#board .chip').count() >= 60);

    // ── full analysis (demo data)
    p = await open(DEMO, 1920, 1080, { colorScheme: 'dark' });
    check('large window shows the analysis view', await p.evaluate(() => document.body.className) === 'mode-analysis');
    check('movers tables are filled', await p.locator('#a-movers tbody tr[data-sym]').count() >= 10);
    check('11 sector rows', await p.locator('.srow[data-sym]').count() === 11);
    check('prediction cards with counterpoints', await p.locator('.pred .con li').count() >= 6);
    check('speculative label on every prediction', await p.locator('.pred .spec').count() === await p.locator('.pred').count());
    check('disclaimer present', /not financial advice/i.test(await p.locator('.notice').last().innerText()));
    const ol = await p.evaluate(() => ['short', 'medium', 'long'].map(h => S.outlook && S.outlook[h] ? S.outlook[h].all.length : 0));
    check('sector outlook ranks all sectors on three horizons', ol.every(n => n === 11), ol);
    check('sector outlook shows picks with Why and But', await p.locator('#a-outlook .pick').count() >= 3 && await p.locator('#a-outlook .pick p.but').count() === await p.locator('#a-outlook .pick').count());
    check('sector outlook has horizon counterpoints', await p.locator('#a-outlook .ol-cav li').count() >= 6);
    check('full statistics table lists the watchlist', await p.locator('.full tbody tr').count() >= 60);
    await p.screenshot({ path: path.join(shots, 'analysis.png'), fullPage: true });
    await p.locator('#a-movers tbody tr').first().click(); await p.waitForSelector('#sheet .chart svg');
    check('detail sheet opens with chart and signals', await p.locator('#sheet .sig tbody tr').count() >= 4);
    await p.keyboard.press('Escape');
    check('Esc closes the detail sheet', await p.locator('#modal').isHidden());
    await p.locator('#a-outlook .pick button').first().click();
    check('clicking an outlook pick opens that sector', await p.locator('#modal').isVisible());
    await p.keyboard.press('Escape');
    await p.locator('[data-act="range"][data-k="ret21"]').click();
    await p.locator('.full th[data-k="rsi"]').click();
    check('sorting and sector range toggle do not break the page', await p.locator('.full th.on').innerText().then(t => /RSI/.test(t)));

    // ── live path through the proxy, with a mock feed in Yahoo's response shape
    await startMock('bear');
    p = await open(LIVE, 1920, 1080);
    const st = () => p.evaluate(() => ({ source: S.source, n: Object.keys(S.stats).length, preds: Object.values(S.pred).filter(Boolean).length, weekly: Object.keys(S.weekly).length }));
    let s = await st();
    check('live data loads through the proxy', s.source === 'live' && s.n >= 80 && s.preds >= 70 && s.weekly === 12, s);
    check('a symbol missing from the feed is tolerated', await p.evaluate(() => !S.stats.PLTR));
    await stopMock();
    await p.evaluate(() => refresh(true)); await sleep(2500);
    s = await st();
    check('feed outage falls back to saved prices', s.source === 'cache' && s.n >= 80, s);
    check('outage is announced', /saved prices/i.test(await p.locator('#a-alert').innerText()));
    await p.reload(); await p.waitForSelector('#boot', { state: 'detached' }); await sleep(300);
    check('saved prices survive a reload', (await st()).source === 'cache');
    const p2 = await open(LIVE, 680, 138);
    check('no feed and no saved prices gives labelled demo data', await p2.evaluate(() => S.source) === 'demo' && /DEMO/.test(await p2.locator('#t-meta').innerText()));
    await startMock('bull');
    await p.evaluate(() => refresh(true)); await p2.evaluate(() => refresh(true)); await sleep(1500);
    check('recovers to live when the feed returns', (await st()).source === 'live' && await p2.evaluate(() => S.source) === 'live');

    // ── one window, two forms
    await p2.locator('[data-act="expand"]').click(); await sleep(600);
    check('expand button goes full screen into analysis', await p2.evaluate(() => document.body.className === 'mode-analysis' && !!document.fullscreenElement));
    await p2.locator('[data-act="collapse"]').click(); await sleep(600);
    check('compact button returns to the ticker', await p2.evaluate(() => document.body.className === 'mode-ticker' && !document.fullscreenElement));
    await p2.evaluate(() => document.querySelector('#tape-track .ti[data-sym="MSFT"]').click()); await sleep(600);
    check('clicking a tape symbol expands to its detail', await p2.evaluate(() => document.body.className === 'mode-analysis' && S.selected === 'MSFT' && !document.querySelector('#modal').hidden));

    // ── history feed failing while quotes work
    const p3 = await (await browser.newContext({ viewport: { width: 1600, height: 900 } })).newPage();
    p3.on('pageerror', e => errors.push(e.message));
    await p3.route(u => /\/api\/spark\?/.test(u.href) && !/range=1d/.test(u.href), r => r.fulfill({ status: 429, body: 'Too Many Requests' }));
    await p3.goto(LIVE); await p3.waitForSelector('#boot', { state: 'detached' }); await sleep(500);
    const part = await p3.evaluate(() => ({ source: S.source, preds: Object.values(S.pred).filter(Boolean).length, outlook: !!S.outlook, movers: document.querySelectorAll('#a-movers tbody tr[data-sym]').length }));
    check('quotes still show when history is unavailable, with no predictions invented', part.source === 'live' && part.preds === 0 && !part.outlook && part.movers > 0, part);

    check('no console or page errors', errors.length === 0, errors);
  } catch (e) { console.log('FAIL  test run crashed -> ' + e.message); failures++; }
  await stopMock(); await browser.close();
  console.log(failures ? `\n${failures} check(s) failed` : '\nAll checks passed');
  process.exit(failures ? 1 : 0);
})();
