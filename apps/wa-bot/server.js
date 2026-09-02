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
const MODEL = process.env.MODEL || 'claude-haiku-4-5';     // barato por padrão (bot é alto volume)
const MAX_TOKENS = parseInt(process.env.MAX_TOKENS || '1024', 10);
const MEM_TURNS = parseInt(process.env.MEM_TURNS || '12', 10);   // últimas N mensagens por contato
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT ||
  'Você é um assistente de atendimento no WhatsApp. Responda em português do Brasil, de forma curta, clara e cordial.';
const DATA_DIR = process.env.DATA_DIR || '/data';

const seg = (f, e) => { try { return fs.existsSync(f) ? fs.readFileSync(f, 'utf8').trim() : (process.env[e] || '').trim(); } catch { return (process.env[e] || '').trim(); } };
const API_KEY = seg('/run/secrets/anthropic_api_key', 'ANTHROPIC_API_KEY');
const WH_TOKEN = seg('/run/secrets/wa_webhook_token', 'WA_WEBHOOK_TOKEN');
// o token da conta Ryze é lido pelo próprio wa.js (RYZE_ACCOUNT_TOKEN); avisa se faltar
if (!process.env.RYZE_ACCOUNT_TOKEN && fs.existsSync('/run/secrets/ryze_account_token')) {
  process.env.RYZE_ACCOUNT_TOKEN = fs.readFileSync('/run/secrets/ryze_account_token', 'utf8').trim();
}
if (!process.env.RYZE_ACCOUNT_TOKEN) console.warn('[wa-bot] RYZE_ACCOUNT_TOKEN ausente — envio desligado');
if (!API_KEY) console.warn('[wa-bot] ANTHROPIC_API_KEY ausente — respostas da LLM vão falhar');
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
  const messages = rows.map(r => ({ role: r.role, content: r.text }));
  messages.push({ role: 'user', content: texto });
  const base = (process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com').replace(/\/$/, '');
  const r = await fetch(base + '/v1/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': API_KEY, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: MODEL, max_tokens: MAX_TOKENS, system: SYSTEM_PROMPT, messages })
  });
  const j = await r.json().catch(() => null);
  if (!r.ok) { console.error('[wa-bot] LLM erro', r.status, JSON.stringify(j).slice(0, 300)); return null; }
  const txt = (j?.content || []).filter(b => b.type === 'text').map(b => b.text).join('').trim();
  return txt || null;
}

// ── app ─────────────────────────────────────────────────────────────────────
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '25mb' }));

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
    salvar.run(numero, 'user', msg.text, Date.now());
    const resposta = await responder(numero, msg.text);
    if (!resposta) return;
    salvar.run(numero, 'assistant', resposta, Date.now());
    await wa.sendText(INST, null, numero, resposta);
  } catch (e) { console.error('[wa-bot] processamento:', e.message); }
});

app.listen(PORT, () => console.log(`[wa-bot] na porta ${PORT} · instância ${INST || '(defina RYZE_INSTANCE)'} · modelo ${MODEL} · chave ${API_KEY ? 'ok' : 'AUSENTE'}`));
