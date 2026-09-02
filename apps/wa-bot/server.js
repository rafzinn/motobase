'use strict';
// ── Base de chatbot WhatsApp — Motobase ──────────────────────────────────────
// RyzeAPI (mesma do Motobot, cliente reusado em lib/wa.js) + Claude.
// Recebe mensagem no webhook, responde com a LLM (memória por contato), envia
// de volta. É um PONTO DE PARTIDA: troque o SYSTEM_PROMPT e a lógica de resposta
// pelo produto do aluno. A chave e o token nunca aparecem em resposta.
const fs = require('fs');
const path = require('path');
const express = require('express');
const Database = require('better-sqlite3');
const wa = require('./lib/wa');

const PORT = process.env.PORT || 3000;
const INST = process.env.RYZE_INSTANCE || '';              // nome da instância (número próprio)
const MODEL = process.env.MODEL || 'gpt-4o-mini';           // OpenAI (o que o Motobot usa; rápido/barato p/ alto volume)
const MAX_TOKENS = parseInt(process.env.MAX_TOKENS || '1024', 10);
const MEM_TURNS = parseInt(process.env.MEM_TURNS || '12', 10);   // últimas N mensagens por contato
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT ||
  'Você é um assistente de atendimento no WhatsApp. Responda em português do Brasil, de forma curta, clara e cordial.';
const DATA_DIR = process.env.DATA_DIR || '/data';
const WEBHOOK_URL = process.env.WA_WEBHOOK_URL || '';   // ex: https://bot.DOMINIO/webhook/wa

const seg = (f, e) => { try { return fs.existsSync(f) ? fs.readFileSync(f, 'utf8').trim() : (process.env[e] || '').trim(); } catch { return (process.env[e] || '').trim(); } };
const API_KEY = seg('/run/secrets/openai_api_key', 'OPENAI_API_KEY');
const WH_TOKEN = seg('/run/secrets/wa_webhook_token', 'WA_WEBHOOK_TOKEN');
// o token da conta Ryze é lido pelo próprio wa.js (RYZE_ACCOUNT_TOKEN); avisa se faltar
if (!process.env.RYZE_ACCOUNT_TOKEN && fs.existsSync('/run/secrets/ryze_account_token')) {
  process.env.RYZE_ACCOUNT_TOKEN = fs.readFileSync('/run/secrets/ryze_account_token', 'utf8').trim();
}
if (!process.env.RYZE_ACCOUNT_TOKEN) console.warn('[wa-bot] RYZE_ACCOUNT_TOKEN ausente — envio desligado');
if (!API_KEY) console.warn('[wa-bot] OPENAI_API_KEY ausente — respostas da LLM vão falhar');
if (!INST) console.warn('[wa-bot] RYZE_INSTANCE ausente — defina o nome da instância (número do bot)');

// ── memória por contato (SQLite em volume) ──────────────────────────────────
fs.mkdirSync(DATA_DIR, { recursive: true });
const db = new Database(path.join(DATA_DIR, 'bot.db'));
db.pragma('journal_mode = WAL');
db.exec(`CREATE TABLE IF NOT EXISTS msgs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  number TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL, ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_msgs_num ON msgs(number, id);`);
const salvar = db.prepare('INSERT INTO msgs (number,role,text,ts) VALUES (?,?,?,?)');
const historico = db.prepare('SELECT role,text FROM msgs WHERE number=? ORDER BY id DESC LIMIT ?');

// ── LLM: gera a resposta (não-streaming; WhatsApp manda tudo de uma vez) ─────
async function responder(number, texto) {
  const rows = historico.all(number, MEM_TURNS).reverse();
  const messages = [{ role: 'system', content: SYSTEM_PROMPT }];
  for (const r of rows) messages.push({ role: r.role, content: r.text });
  messages.push({ role: 'user', content: texto });
  const base = (process.env.OPENAI_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');
  const r = await fetch(base + '/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'Authorization': `Bearer ${API_KEY}` },
    body: JSON.stringify({ model: MODEL, max_tokens: MAX_TOKENS, messages })
  });
  const j = await r.json().catch(() => null);
  if (!r.ok) { console.error('[wa-bot] LLM erro', r.status, JSON.stringify(j).slice(0, 300)); return null; }
  const txt = (j?.choices?.[0]?.message?.content || '').trim();
  return txt || null;
}

// ── app ─────────────────────────────────────────────────────────────────────
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '25mb' }));

const PAIR_HTML = `<!DOCTYPE html><html lang="pt-BR"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Parear WhatsApp</title>
<style>
:root{color-scheme:dark;--bg:#14100D;--sf:#1C1712;--bd:rgba(217,164,107,.14);--ink:#F3ECDF;--ink2:#C6B7A4;--ink3:#8A7C6B;--terra:#D9714A;--gold:#E0B274;--ok:#5FAE86;--mono:"JetBrains Mono",ui-monospace,Menlo,monospace}
*{box-sizing:border-box;margin:0;padding:0}body{background:var(--bg);color:var(--ink);font:15px/1.6 Inter,system-ui,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px}
.card{width:min(420px,100%);background:var(--sf);border:1px solid var(--bd);border-left:3px solid var(--terra);padding:26px;text-align:center}
h1{font-size:20px;margin-bottom:4px}.sub{color:var(--ink3);font:12px var(--mono);letter-spacing:.04em;margin-bottom:20px}
.inst{font:12px var(--mono);color:var(--ink2);margin-bottom:18px}.inst b{color:var(--gold)}
button{font:600 14px Inter;background:var(--terra);color:#14100D;border:0;padding:12px 20px;cursor:pointer;width:100%}
button:hover{background:var(--gold)}button:disabled{opacity:.5;cursor:default}
.qr{margin:18px auto;width:230px;height:230px;background:#fff;padding:10px;display:none}.qr img{width:100%;height:100%;display:block}
.pill{display:inline-flex;gap:8px;align-items:center;margin-top:14px;font:12px var(--mono);color:var(--ink3)}
.dot{width:8px;height:8px;border-radius:50%;background:var(--ink3)}.dot.on{background:var(--ok)}.dot.wait{background:var(--gold)}
.state.ok{color:var(--ok)}.hint{font:11px var(--mono);color:var(--ink3);margin-top:16px;line-height:1.5}
.code{font:600 22px var(--mono);letter-spacing:.3em;color:var(--gold);margin:14px 0;display:none}
</style></head><body><div class="card">
<h1>Parear WhatsApp</h1><p class="sub">acesso só pela tailnet</p>
<p class="inst">instância <b id="inst">—</b></p>
<div class="qr" id="qrbox"><img id="qr" alt="QR"></div>
<div class="code" id="code"></div>
<button id="btn">Gerar QR / código</button>
<div class="pill"><span class="dot" id="dot"></span><span class="state" id="state">verificando…</span></div>
<p class="hint">Abra o WhatsApp no celular do número do bot → Aparelhos conectados → Conectar → escaneie o QR (ou digite o código).</p>
</div><script>
const $=s=>document.querySelector(s);let timer=null;
async function status(){try{const s=await(await fetch('/status')).json();$('#inst').textContent=s.instance||'—';
const st=s.state||'desconhecido';const conn=s.connected;
$('#dot').className='dot '+(conn?'on':(st==='connecting'?'wait':''));
$('#state').textContent=conn?('conectado'+(s.number?' · '+s.number:'')):st;
$('#state').className='state'+(conn?' ok':'');
if(conn){$('#qrbox').style.display='none';$('#code').style.display='none';$('#btn').textContent='Conectado ✓';$('#btn').disabled=true;if(timer)clearInterval(timer);}}catch(e){$('#state').textContent='erro ao consultar';}}
$('#btn').onclick=async()=>{$('#btn').disabled=true;$('#btn').textContent='gerando…';
try{const c=await(await fetch('/connect')).json();
if(c.qrBase64){$('#qr').src=c.qrBase64;$('#qrbox').style.display='block';}
if(c.pairingCode){$('#code').textContent=c.pairingCode;$('#code').style.display='block';}
$('#btn').textContent='Gerar de novo';}catch(e){$('#btn').textContent='falhou — tentar de novo';}
$('#btn').disabled=false;if(!timer)timer=setInterval(status,3000);status();};
status();timer=setInterval(status,4000);
</script></body></html>`;
app.get('/', (req, res) => res.type('html').send(PAIR_HTML));
app.get('/healthz', (req, res) => res.json({ ok: true, inst: INST || null, key: !!API_KEY, ryze: !!process.env.RYZE_ACCOUNT_TOKEN }));

// status da conexão (tailnet) — pra saber se o número está pareado
app.get('/status', async (req, res) => {
  try { const st = await wa.status(INST, null); res.json({ instance: INST, ...st }); }
  catch (e) { res.status(502).json({ error: String(e.message || e) }); }
});
// parear o número: devolve o QR (base64) pra escanear no WhatsApp (tailnet)
app.get('/connect', async (req, res) => {
  try { const c = await wa.connect(INST, null, req.query.number || ''); res.json({ instance: INST, qrBase64: c.qrBase64, pairingCode: c.pairingCode, state: c.state }); }
  catch (e) { res.status(502).json({ error: String(e.message || e) }); }
});

// ── webhook inbound da Ryze ─────────────────────────────────────────────────
app.post('/webhook/wa', async (req, res) => {
  // verificação: eventos de mensagem trazem o token; instance.state chega sem
  // header (confirmado no Motobot) — por isso só exige token quando há.
  if (WH_TOKEN) {
    const t = req.get('authorization') || req.query.token || '';
    const ok = t === WH_TOKEN || t === `Bearer ${WH_TOKEN}`;
    const isState = req.body?.event === 'instance.state';
    if (!ok && !isState) return res.status(401).json({ error: 'token' });
  }
  res.json({ ok: true });   // responde rápido; processa depois

  try {
    const msg = wa.parseInbound(req.body);
    if (!msg || msg.event !== 'message.exchange') return;
    if (msg.fromMe || msg.isGroup || msg.isBroadcast) return;   // só 1:1 do cliente
    if (msg.type !== 'text' || !msg.text || !msg.number) return; // base: só texto (áudio fica pro produto)
    const numero = msg.number;
    // responder() lê o histórico e anexa a mensagem atual — por isso salvamos
    // DEPOIS, senão a última fala do usuário iria duplicada pro modelo.
    const resposta = await responder(numero, msg.text);
    if (!resposta) return;
    salvar.run(numero, 'user', msg.text, Date.now());
    salvar.run(numero, 'assistant', resposta, Date.now());
    await wa.sendText(INST, null, numero, resposta);
  } catch (e) { console.error('[wa-bot] processamento:', e.message); }
});

// no boot: garante que a instância existe e o webhook aponta pra cá (idempotente)
async function provisionar() {
  if (!INST || !process.env.RYZE_ACCOUNT_TOKEN) return;
  try {
    const st = await wa.status(INST, null);
    if (!st.exists) {
      const c = await wa.createInstance(INST);
      console.log('[wa-bot] instância criada:', INST, c.ok ? 'ok' : ('falhou ' + c.status));
    }
    if (WEBHOOK_URL) {
      const r = await wa.setWebhook(INST, null, WEBHOOK_URL, ['message.exchange', 'instance.state'], WH_TOKEN || undefined);
      console.log('[wa-bot] webhook →', WEBHOOK_URL, r.ok ? 'ok' : ('falhou ' + r.status));
    }
  } catch (e) { console.warn('[wa-bot] provisionamento adiado:', e.message); }
}

app.listen(PORT, () => console.log(`[wa-bot] na porta ${PORT} · instância ${INST || '(defina RYZE_INSTANCE)'} · modelo ${MODEL} · chave ${API_KEY ? 'ok' : 'AUSENTE'}`));
setTimeout(provisionar, 1500);
