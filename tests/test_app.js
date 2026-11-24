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

    // ── thin bar and the Windows host window (window.ps1), with chrome.webview faked
    p = await open(DEMO, 900, 30);
    check('thin bar in a browser shows the expand button but no window controls', await p.locator('#ticker [data-act="expand"]').isVisible() && await p.locator('#ticker .win').isHidden());
    const hostCtx = { viewport: { width: 900, height: 30 } };
    const hp = await (await browser.newContext(hostCtx)).newPage();
    hp.on('pageerror', e => errors.push(e.message));
    await hp.addInitScript(() => { window.__sent = []; window.chrome = window.chrome || {}; window.chrome.webview = { postMessage: m => window.__sent.push(m), addEventListener() {} }; });
    await hp.goto(DEMO); await hp.waitForSelector('#boot', { state: 'detached' }); await sleep(400);
    const fit = await hp.evaluate(() => { const t = document.querySelector('#tape-track .ti'), r = t.getBoundingClientRect(), fs = parseFloat(getComputedStyle(t).fontSize); return { top: r.top, bottom: r.bottom, fs, h: innerHeight }; });
    check('thin bar text fits without clipping', fit.top >= 0 && fit.bottom <= fit.h && fit.fs >= 13, fit);
    check('host window shows minimize, close and throw on the expand row', await hp.locator('#ticker [data-act="minimize"]').isVisible() && await hp.locator('#ticker [data-act="quit"]').isVisible() && await hp.locator('#ticker [data-act="throw"]').isVisible() && await hp.locator('#ticker [data-act="expand"]').isVisible());
    await hp.locator('#ticker [data-act="minimize"]').click(); await hp.locator('#ticker [data-act="quit"]').click(); await hp.locator('#ticker [data-act="throw"]').click();
    check('window buttons message the host', JSON.stringify(await hp.evaluate(() => window.__sent.splice(0))) === '["minimize","quit","throw"]');
    await hp.locator('#tape').click({ position: { x: 200, y: 15 } }); await sleep(300);
    check('clicking the thin bar throws the window and does not open a stock', JSON.stringify(await hp.evaluate(() => window.__sent.splice(0))) === '["throw"]' && await hp.evaluate(() => document.body.className) === 'mode-ticker');
    await hp.mouse.move(300, 15); await hp.mouse.down(); await hp.mouse.move(320, 15, { steps: 4 }); await hp.mouse.up(); await sleep(200);
    check('dragging the thin bar asks the host to move the window', JSON.stringify(await hp.evaluate(() => window.__sent.splice(0))) === '["drag"]');
    await hp.setViewportSize({ width: 680, height: 138 }); await sleep(300);
    await hp.evaluate(() => document.querySelector('#tape-track .ti[data-sym="MSFT"]').click()); await sleep(500);
    check('in the taller ticker, tape stocks still open their detail', await hp.evaluate(() => document.body.className === 'mode-analysis' && S.selected === 'MSFT'));
    check('analysis header has minimize and close in the host', await hp.locator('.a-head [data-act="minimize"]').isVisible() && await hp.locator('.a-head [data-act="quit"]').isVisible());
    await hp.close();

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
    check('scorecard records nothing from simulated prices and says so', await p.evaluate(() => localStorage.getItem('ticker-score-v1')) === null && /simulated/.test(await p.locator('#a-score').innerText()) && /none yet/.test(await p.locator('#a-track').innerText()));
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

    // ── prediction scorecard: today's leans are recorded, and an earlier session's leans are scored against the next close
    const rec = await p.evaluate(() => { const sc = scoreLoad(), days = Object.keys(sc.open), o = sc.open[days[0]] || { r: {} }, rows = Object.values(o.r);
      return { days: days.length, rows: rows.length, shape: rows.every(r => r.length === 8 && r[1] > 0 && Math.abs(r[0]) <= 1), market: !!o.m, scored: sc.days.length }; });
    check('scorecard records the session\'s leans from live prices', rec.days === 1 && rec.rows >= 60 && rec.shape && rec.market && rec.scored === 0, rec);
    check('scorecard says it is waiting for the next close', /Waiting for the next close: \d+ leans/.test(await p.locator('#sc-wait').innerText()));
    // Plant leans for the session two bars back (the next bar is a finished session): alternate up and down, with only the Trend signal active.
    const want = await p.evaluate(() => {
      const sc = scoreLoad(), r = {}, exp = { n: 0, hit: 0, up: 0, trend: 0 }; let day = null, i = 0;
      for (const u of UNIVERSE) { const d = S.daily[u.sym], q = S.quotes[u.sym]; if (!d || !q || d.c.length < 5) continue;
        const k = d.c.length - 3, base = d.c[k], next = d.c[k + 1], dir = i++ % 2 ? 1 : -1, moved = Math.sign(next - base);
        day = dayOf(d.t[k], q.gmt); r[u.sym] = [dir, base, 1, 0, 0, 0, 0, 0];
        if (moved) { exp.n++; if (moved === dir) exp.hit++; if (moved > 0) { exp.up++; exp.trend++; } } }
      const g = S.daily['^GSPC']; sc.open[day] = { at: 1, m: [1, g.c[g.c.length - 3]], r };
      localStorage.setItem('ticker-score-v1', JSON.stringify(sc)); exp.day = day; exp.mkt = Math.sign(g.c[g.c.length - 2] - g.c[g.c.length - 3]); return exp; });
    await p.evaluate(() => refresh(true)); await sleep(1500);
    const got = await p.evaluate(() => { const sc = scoreLoad(), d = sc.days[0] || {}; return { days: sc.days.length, d: d.d, n: d.n, hit: d.hit, up: d.up, trend: d.sg && d.sg[0], other: d.sg && d.sg[1], m: d.m, open: Object.keys(sc.open).length }; });
    check('scorecard scores a past session against the next close', got.days === 1 && got.d === want.day && got.n === want.n && got.hit === want.hit && got.up === want.up && want.n >= 60, { got, want });
    check('scorecard scores each signal and the market lean', got.trend && got.trend[0] === want.n && got.trend[1] === want.trend && got.other[0] === 0 && got.m && got.m[0] === 1 && got.m[1] === want.mkt && got.open === 1, { got, want });
    const pct = Math.round(want.hit / want.n * 100) + '%';
    check('scorecard shows the hit rate, the per-signal table and its counterpoints', (await p.locator('#sc-stats').innerText()).includes(`${pct} (${want.hit} of ${want.n})`) && await p.locator('#sc-signals tbody tr').count() === 7 && await p.locator('#sc-days tbody tr').count() === 1 && await p.locator('#a-score .ol-cav li').count() >= 3);
    check('track record is shown next to the predictions', (await p.locator('#a-track').innerText()).includes(`${pct} of ${want.n} scored leans`));
    await p.screenshot({ path: path.join(shots, 'scorecard.png'), fullPage: true });
    await stopMock();
    await p.evaluate(() => refresh(true)); await sleep(2500);
    s = await st();
    check('feed outage falls back to saved prices', s.source === 'cache' && s.n >= 80, s);
    check('outage is announced', /saved prices/i.test(await p.locator('#a-alert').innerText()));
    check('scorecard keeps its results but stops recording on saved prices', /Nothing is being recorded right now/.test(await p.locator('#a-score').innerText()) && await p.evaluate(() => scoreLoad().days.length) === 1);
    await p.reload(); await p.waitForSelector('#boot', { state: 'detached' }); await sleep(300);
    check('saved prices survive a reload', (await st()).source === 'cache');
    const p2 = await open(LIVE, 680, 138);
    check('no feed and no saved prices gives labelled demo data', await p2.evaluate(() => S.source) === 'demo' && /DEMO/.test(await p2.locator('#t-meta').innerText()));
    await startMock('bull');
    await p.evaluate(() => refresh(true)); await p2.evaluate(() => refresh(true)); await sleep(1500);
    check('recovers to live when the feed returns', (await st()).source === 'live' && await p2.evaluate(() => S.source) === 'live');

    await p.locator('[data-act="score-clear"]').click();
    const kept = await p.evaluate(() => scoreLoad().days.length);
    await p.locator('[data-act="score-clear"]').click();
    check('clearing the scorecard takes two clicks', kept === 1 && await p.evaluate(() => scoreLoad().days.length) === 0 && /No results yet/.test(await p.locator('#a-score').innerText()));

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
