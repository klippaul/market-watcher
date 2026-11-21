// Mock of Yahoo's v7 spark endpoint, in the real response shape (verified against the live API).
const http = require('http');
const regime = process.argv[3] || 'bear';
function rng(seed){let a=seed>>>0;return()=>{a=a+0x6D2B79F5|0;let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296}}
function hash(s){let h=2166136261;for(const c of s){h^=c.charCodeAt(0);h=Math.imul(h,16777619)}return h>>>0}
function gauss(r){let u=0;while(!u)u=r();return Math.sqrt(-2*Math.log(u))*Math.cos(2*Math.PI*r())}
const now = Math.floor(Date.now()/1000), open = now - 2*3600;
const rm = rng(42), mkt = []; for (let i=0;i<253;i++) mkt.push(gauss(rm)*0.009 + (regime==='bear' ? -0.0012 : 0.0006));
function build(sym){
  const r = rng(hash(sym)); const beta = sym.startsWith('^') ? 1 : 0.5 + r()*1.2, idio = sym.startsWith('^') ? 0.001 : 0.006 + r()*0.014;
  let p = 30 + r()*500; const c=[], t=[];
  for (let d=0; d<252; d++){ p *= Math.exp(beta*mkt[d] + gauss(r)*idio); c.push(d%97===13 ? null : +p.toFixed(2)); t.push(open - (252-d)*86400); }
  const prev = +p.toFixed(2);
  let today = beta*mkt[252] + gauss(r)*idio; if (r()<0.12) today += (r()<0.6?-1:1)*(0.04+r()*0.05);
  const intr=[], it=[]; for (let j=0;j<24;j++){ intr.push(j===5?null:+(prev*Math.exp(today*(j+1)/24 + gauss(r)*idio/8)).toFixed(2)); it.push(open+j*300); }
  const price = +(prev*Math.exp(today)).toFixed(2); intr[23]=price;
  return {c,t,prev,intr,it,price};
}
http.createServer((req,res)=>{
  const u = new URL(req.url,'http://x'); const syms = (u.searchParams.get('symbols')||'').split(',').filter(Boolean);
  const range = u.searchParams.get('range');
  res.setHeader('content-type','application/json');
  if (!/Mozilla/.test(req.headers['user-agent']||'')) { res.statusCode=429; return res.end('Too Many Requests'); }
  if (syms.length>20){ res.statusCode=400; return res.end(JSON.stringify({spark:{result:null,error:{code:'Bad Request',description:'Too many symbols'}}})); }
  const result = syms.filter(s=>s!=='PLTR').map(sym=>{ const b=build(sym);
    const meta={currency:'USD',symbol:sym,regularMarketTime:now,gmtoffset:-18000,regularMarketPrice:b.price,chartPreviousClose: range==='1d'?b.prev:b.c[0],fiftyTwoWeekHigh:Math.max(...b.c.filter(Boolean),b.price),fiftyTwoWeekLow:Math.min(...b.c.filter(Boolean),b.price),regularMarketDayHigh:Math.max(...b.intr.filter(Boolean)),regularMarketDayLow:Math.min(...b.intr.filter(Boolean)),regularMarketVolume:12345678,shortName:sym+' Inc',
      currentTradingPeriod:{pre:{start:open-19800,end:open},regular:{start:open,end:open+23400},post:{start:open+23400,end:open+37800}}};
    if (range==='1d') meta.previousClose=b.prev;
    return {symbol:sym,response:[{meta, timestamp: range==='1d'?b.it:b.t.concat([open]), indicators:{quote:[{close: range==='1d'?b.intr:b.c.concat([b.price])}]}}]};
  });
  res.end(JSON.stringify({spark:{result,error:null}}));
}).listen(+process.argv[2]||9911,'127.0.0.1');
