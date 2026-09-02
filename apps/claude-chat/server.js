'use strict';
// ── Chat Claude do Motobase ─────────────────────────────────────────────────
// Proxy SSE para a Messages API da Anthropic. A chave NUNCA vai ao frontend:
// fica só no servidor (Docker secret /run/secrets/anthropic_api_key, ou env).
// Sem login próprio — a barreira de acesso é a tailnet (feito no Traefik).
const fs = require('fs');
const path = require('path');
const express = require('express');
const Database = require('better-sqlite3');

const PORT = process.env.PORT || 3000;
// modelos oferecidos no seletor (id da API → rótulo). Fable/Opus/Sonnet/Haiku.
const MODELOS = {
  'claude-opus-5':        'Opus',
  'claude-sonnet-5':      'Sonnet',
  'claude-haiku-4-5-20251001': 'Haiku',
  'claude-fable-5':       'Fable'
};
const MODEL = MODELOS[process.env.MODEL] ? process.env.MODEL : 'claude-sonnet-5';
const MAX_TOKENS = parseInt(process.env.MAX_TOKENS || '4096', 10);
const APP_TITLE = process.env.APP_TITLE || 'Claude';
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT || '';
const DATA_DIR = process.env.DATA_DIR || '/data';

// preços oficiais (US$ por 1 milhão de tokens) — entrada / saída
const PRECOS = {
  'claude-opus-5':             { in: 5.00,  out: 25.00 },
  'claude-sonnet-5':           { in: 2.00,  out: 10.00 },
  'claude-haiku-4-5-20251001': { in: 1.00,  out: 5.00 },
  'claude-fable-5':            { in: 10.00, out: 50.00 }
};
// câmbio US$→R$: env USD_BRL manda; senão tenta pegar 1x no boot; fallback 5.40
let USD_BRL = parseFloat(process.env.USD_BRL || '') || 5.40;
async function atualizarCambio() {
  if (process.env.USD_BRL) return;   // fixado pelo operador
  try {
    const r = await fetch('https://economia.awesomeapi.com.br/last/USD-BRL', { signal: AbortSignal.timeout(5000) });
    const j = await r.json(); const v = parseFloat(j?.USDBRL?.bid);
    if (v > 0) { USD_BRL = v; console.log('[chat] câmbio USD→BRL =', v); }
  } catch (e) { console.warn('[chat] câmbio: usando fallback', USD_BRL); }
}
function custo(model, tin, tout) {
  const p = PRECOS[model] || PRECOS['claude-sonnet-5'];
  const usd = (tin / 1e6) * p.in + (tout / 1e6) * p.out;
  return { in: tin, out: tout, usd: +usd.toFixed(6), brl: +(usd * USD_BRL).toFixed(4) };
}

function lerChave() {
  const f = '/run/secrets/anthropic_api_key';
  try { if (fs.existsSync(f)) return fs.readFileSync(f, 'utf8').trim(); } catch (e) {}
  return (process.env.ANTHROPIC_API_KEY || '').trim();
}
const API_KEY = lerChave();
const WORKSPACE_ID = (process.env.ANTHROPIC_WORKSPACE_ID || '').trim();
if (!API_KEY) console.warn('[chat] AVISO: sem chave Anthropic — o chat sobe, mas responder vai falhar.');

// ── banco (SQLite em volume) ────────────────────────────────────────────────
fs.mkdirSync(DATA_DIR, { recursive: true });
const db = new Database(path.join(DATA_DIR, 'chat.db'));
db.pragma('journal_mode = WAL');
db.exec(`
  CREATE TABLE IF NOT EXISTS conversations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL DEFAULT 'Nova conversa',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    text TEXT NOT NULL DEFAULT '',
    attachments TEXT NOT NULL DEFAULT '[]',
    tokens_in INTEGER, tokens_out INTEGER, cost_usd REAL, cost_brl REAL,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id);
`);
// migração leve: adiciona colunas de uso se o banco for de uma versão anterior
for (const col of ['tokens_in INTEGER','tokens_out INTEGER','cost_usd REAL','cost_brl REAL']) {
  try { db.exec(`ALTER TABLE messages ADD COLUMN ${col}`); } catch (e) { /* já existe */ }
}
const now = () => Date.now();

// ── app ─────────────────────────────────────────────────────────────────────
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '120mb' }));
app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/config', (req, res) => res.json({ title: APP_TITLE, model: MODEL, models: MODELOS, usd_brl: USD_BRL }));
app.get('/healthz', (req, res) => res.json({ ok: true, key: !!API_KEY }));

app.get('/api/conversations', (req, res) => {
  const rows = db.prepare('SELECT id,title,updated_at FROM conversations ORDER BY updated_at DESC').all();
  res.json(rows);
});
app.post('/api/conversations', (req, res) => {
  const t = now();
  const info = db.prepare('INSERT INTO conversations (title,created_at,updated_at) VALUES (?,?,?)')
    .run('Nova conversa', t, t);
  res.json({ id: info.lastInsertRowid, title: 'Nova conversa' });
});
app.get('/api/conversations/:id', (req, res) => {
  const id = +req.params.id;
  const conv = db.prepare('SELECT id,title FROM conversations WHERE id=?').get(id);
  if (!conv) return res.status(404).json({ error: 'não encontrada' });
  const msgs = db.prepare('SELECT role,text,attachments,tokens_in,tokens_out,cost_usd,cost_brl,created_at FROM messages WHERE conversation_id=? ORDER BY id').all(id)
    .map(m => ({ role: m.role, text: m.text, attachments: JSON.parse(m.attachments || '[]'),
      usage: (m.tokens_out != null ? { in: m.tokens_in, out: m.tokens_out, usd: m.cost_usd, brl: m.cost_brl } : null),
      created_at: m.created_at }));
  res.json({ id: conv.id, title: conv.title, messages: msgs });
});
app.delete('/api/conversations/:id', (req, res) => {
  db.prepare('DELETE FROM messages WHERE conversation_id=?').run(+req.params.id);
  db.prepare('DELETE FROM conversations WHERE id=?').run(+req.params.id);
  res.json({ ok: true });
});

// monta os blocos de conteúdo (texto + anexos) pro formato da API
function blocosDaMensagem(text, attachments) {
  const blocos = [];
  for (const a of (attachments || [])) {
    if (a.kind === 'image') {
      blocos.push({ type: 'image', source: { type: 'base64', media_type: a.media_type, data: a.data } });
    } else if (a.kind === 'pdf') {
      blocos.push({ type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: a.data } });
    }
  }
  if (text && text.trim()) blocos.push({ type: 'text', text });
  return blocos.length ? blocos : [{ type: 'text', text: '' }];
}

// histórico da API a partir do banco (só texto + tipos de anexo; sem re-enviar base64 antigo)
function historicoParaAPI(convId) {
  const rows = db.prepare('SELECT role,text,attachments FROM messages WHERE conversation_id=? ORDER BY id').all(convId);
  return rows.map(r => {
    const meta = JSON.parse(r.attachments || '[]');
    const marca = meta.length ? `\n\n[${meta.length} anexo(s): ${meta.map(m => m.name).join(', ')}]` : '';
    return { role: r.role, content: (r.text || '') + marca };
  });
}

app.post('/api/chat', async (req, res) => {
  const { conversation_id, message, attachments, model } = req.body || {};
  const modelo = MODELOS[model] ? model : MODEL;   // nunca confia cegamente no cliente
  const convId = +conversation_id;
  if (!convId) return res.status(400).json({ error: 'conversation_id faltando' });
  if (!API_KEY) return res.status(503).json({ error: 'servidor sem chave Anthropic' });

  const anexos = (attachments || []).slice(0, 5);
  const metaAnexos = anexos.map(a => ({ name: a.name, kind: a.kind, media_type: a.media_type }));

  // histórico ANTES de gravar a nova mensagem
  const historico = historicoParaAPI(convId);
  db.prepare('INSERT INTO messages (conversation_id,role,text,attachments,created_at) VALUES (?,?,?,?,?)')
    .run(convId, 'user', message || '', JSON.stringify(metaAnexos), now());

  // título da conversa a partir da 1ª mensagem
  const conv = db.prepare('SELECT title FROM conversations WHERE id=?').get(convId);
  if (conv && conv.title === 'Nova conversa' && (message || '').trim()) {
    const titulo = message.trim().slice(0, 48);
    db.prepare('UPDATE conversations SET title=?, updated_at=? WHERE id=?').run(titulo, now(), convId);
  }

  const mensagens = [...historico, { role: 'user', content: blocosDaMensagem(message, anexos) }];
  const corpo = { model: modelo, max_tokens: MAX_TOKENS, stream: true, messages: mensagens };
  if (SYSTEM_PROMPT) corpo.system = SYSTEM_PROMPT;

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders && res.flushHeaders();

  let textoFinal = '';
  let tin = 0, tout = 0;   // uso EXATO reportado pela própria API
  try {
    const base = (process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com').replace(/\/$/, '');
    const upstream = await fetch(base + '/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': API_KEY,
        'anthropic-version': '2023-06-01',
        'anthropic-beta': 'pdfs-2024-09-25',
        // chaves vinculadas a workspace (identity-linked) exigem este cabeçalho;
        // opcional — só é enviado se o workspace id foi informado
        ...(WORKSPACE_ID ? { 'anthropic-workspace-id': WORKSPACE_ID } : {})
      },
      body: JSON.stringify(corpo)
    });
    if (!upstream.ok || !upstream.body) {
      const err = await upstream.text().catch(() => '');
      res.write(`event: erro\ndata: ${JSON.stringify({ status: upstream.status, detail: err.slice(0, 500) })}\n\n`);
      return res.end();
    }
    // repassa o SSE da Anthropic, extraindo os deltas de texto pro cliente
    const reader = upstream.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf('\n\n')) >= 0) {
        const bloco = buf.slice(0, idx); buf = buf.slice(idx + 2);
        const linha = bloco.split('\n').find(l => l.startsWith('data:'));
        if (!linha) continue;
        const payload = linha.slice(5).trim();
        if (!payload || payload === '[DONE]') continue;
        try {
          const ev = JSON.parse(payload);
          if (ev.type === 'message_start' && ev.message && ev.message.usage) {
            const u = ev.message.usage;
            tin = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
          } else if (ev.type === 'message_delta' && ev.usage) {
            tout = ev.usage.output_tokens || tout;
          } else if (ev.type === 'content_block_delta' && ev.delta && ev.delta.type === 'text_delta') {
            textoFinal += ev.delta.text;
            res.write(`event: delta\ndata: ${JSON.stringify({ t: ev.delta.text })}\n\n`);
          } else if (ev.type === 'message_stop') {
            res.write('event: fim\ndata: {}\n\n');
          } else if (ev.type === 'error') {
            res.write(`event: erro\ndata: ${JSON.stringify(ev.error || {})}\n\n`);
          }
        } catch (e) { /* linha não-JSON: ignora */ }
      }
    }
  } catch (e) {
    res.write(`event: erro\ndata: ${JSON.stringify({ detail: String(e && e.message || e) })}\n\n`);
  } finally {
    const uso = custo(modelo, tin, tout);
    if (textoFinal) {
      db.prepare('INSERT INTO messages (conversation_id,role,text,attachments,tokens_in,tokens_out,cost_usd,cost_brl,created_at) VALUES (?,?,?,?,?,?,?,?,?)')
        .run(convId, 'assistant', textoFinal, '[]', uso.in, uso.out, uso.usd, uso.brl, now());
      db.prepare('UPDATE conversations SET updated_at=? WHERE id=?').run(now(), convId);
    }
    try { res.write(`event: uso\ndata: ${JSON.stringify({ ...uso, model: modelo })}\n\n`); } catch (e) {}
    res.end();
  }
});

atualizarCambio();
app.listen(PORT, () => console.log(`[chat] ${APP_TITLE} na porta ${PORT} · modelo ${MODEL} · chave ${API_KEY ? 'ok' : 'AUSENTE'}`));
