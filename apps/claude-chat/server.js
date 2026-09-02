'use strict';
// ── Chat Claude do Motobase — via Claude Code (plano Max, SEM créditos de API) ──
// O backend roda o `claude -p` por baixo, autenticado com o setup-token do dono
// (CLAUDE_CODE_OAUTH_TOKEN = a assinatura Max). Nada de chave de API, nada de
// custo por token. A barreira de acesso é a tailnet (feita no Traefik).
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const express = require('express');
const Database = require('better-sqlite3');

const PORT = process.env.PORT || 3000;
// seletor de modelo (chave → rótulo) e o mapeamento pro --model do Claude Code
const MODELOS = {
  'opus':   'Opus',
  'sonnet': 'Sonnet',
  'haiku':  'Haiku',
  'fable':  'Fable'
};
const MODEL_ARG = { opus: 'opus', sonnet: 'sonnet', haiku: 'haiku', fable: 'claude-fable-5-1' };
const MODEL = MODELOS[process.env.MODEL] ? process.env.MODEL : 'sonnet';
const APP_TITLE = process.env.APP_TITLE || 'Claude';
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT || '';
const DATA_DIR = process.env.DATA_DIR || '/data';
const CLAUDE_BIN = process.env.CLAUDE_BIN || 'claude';
const SETTINGS = process.env.CHAT_SETTINGS || path.join(__dirname, 'chat-settings.json');
const MEM_TURNS = parseInt(process.env.MEM_TURNS || '20', 10);   // turnos de contexto enviados

// preços de referência (US$ por 1M tokens — entrada/saída). No plano Max NÃO se
// paga por token; isto é só pra mostrar quanto a resposta "valeria" na API.
const PRECOS = {
  opus:   { in: 5.00,  out: 25.00 },
  sonnet: { in: 2.00,  out: 10.00 },
  haiku:  { in: 1.00,  out: 5.00 },
  fable:  { in: 10.00, out: 50.00 }
};
let USD_BRL = parseFloat(process.env.USD_BRL || '') || 5.40;
async function atualizarCambio() {
  if (process.env.USD_BRL) return;
  try {
    const r = await fetch('https://economia.awesomeapi.com.br/last/USD-BRL', { signal: AbortSignal.timeout(5000) });
    const j = await r.json(); const v = parseFloat(j?.USDBRL?.bid);
    if (v > 0) USD_BRL = v;
  } catch (e) { /* mantém fallback */ }
}
function custoBRL(modelo, tin, tout) {
  const p = PRECOS[modelo] || PRECOS.sonnet;
  const usd = (tin / 1e6) * p.in + (tout / 1e6) * p.out;
  return +(usd * USD_BRL).toFixed(4);
}

// setup-token (sk-ant-oat…) do plano do dono — via secret ou env
function lerOAuth() {
  for (const f of ['/run/secrets/claude_oauth_token', '/run/secrets/anthropic_oauth_token']) {
    try { if (fs.existsSync(f)) return fs.readFileSync(f, 'utf8').trim(); } catch (e) {}
  }
  return (process.env.CLAUDE_CODE_OAUTH_TOKEN || '').trim();
}
const OAUTH = lerOAuth();
if (!OAUTH) console.warn('[chat] AVISO: sem setup-token do Claude — o chat sobe, mas responder vai falhar. Informe o sk-ant-oat.');

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
for (const col of ['tokens_in INTEGER','tokens_out INTEGER','cost_usd REAL','cost_brl REAL']) {
  try { db.exec(`ALTER TABLE messages ADD COLUMN ${col}`); } catch (e) { /* já existe */ }
}
const now = () => Date.now();

// ── app ─────────────────────────────────────────────────────────────────────
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '120mb' }));
app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/config', (req, res) => res.json({ title: APP_TITLE, model: MODEL, models: MODELOS, plan: 'max' }));
app.get('/healthz', (req, res) => res.json({ ok: true, oauth: !!OAUTH }));

app.get('/api/conversations', (req, res) => {
  res.json(db.prepare('SELECT id,title,updated_at FROM conversations ORDER BY updated_at DESC').all());
});
app.post('/api/conversations', (req, res) => {
  const t = now();
  const info = db.prepare('INSERT INTO conversations (title,created_at,updated_at) VALUES (?,?,?)').run('Nova conversa', t, t);
  res.json({ id: info.lastInsertRowid, title: 'Nova conversa' });
});
app.get('/api/conversations/:id', (req, res) => {
  const id = +req.params.id;
  const conv = db.prepare('SELECT id,title FROM conversations WHERE id=?').get(id);
  if (!conv) return res.status(404).json({ error: 'não encontrada' });
  const msgs = db.prepare('SELECT role,text,attachments,tokens_in,tokens_out,created_at FROM messages WHERE conversation_id=? ORDER BY id').all(id)
    .map(m => ({ role: m.role, text: m.text, attachments: JSON.parse(m.attachments || '[]'),
      usage: (m.tokens_out != null ? { in: m.tokens_in, out: m.tokens_out, plan: 'max' } : null),
      created_at: m.created_at }));
  res.json({ id: conv.id, title: conv.title, messages: msgs });
});
app.delete('/api/conversations/:id', (req, res) => {
  db.prepare('DELETE FROM messages WHERE conversation_id=?').run(+req.params.id);
  db.prepare('DELETE FROM conversations WHERE id=?').run(+req.params.id);
  res.json({ ok: true });
});

// monta o prompt: histórico recente + a nova mensagem, num texto só pro claude -p
function montarPrompt(convId, message, metaAnexos) {
  const rows = db.prepare('SELECT role,text,attachments FROM messages WHERE conversation_id=? ORDER BY id DESC LIMIT ?')
    .all(convId, MEM_TURNS * 2).reverse();
  let p = '';
  for (const r of rows) {
    const meta = JSON.parse(r.attachments || '[]');
    const marca = meta.length ? ` [${meta.length} anexo(s): ${meta.map(m => m.name).join(', ')}]` : '';
    p += (r.role === 'user' ? 'Humano' : 'Assistente') + ': ' + (r.text || '') + marca + '\n\n';
  }
  const marcaNova = metaAnexos.length ? ` [${metaAnexos.length} anexo(s): ${metaAnexos.map(m => m.name).join(', ')}]` : '';
  p += 'Humano: ' + (message || '') + marcaNova + '\n\nAssistente:';
  return p;
}

app.post('/api/chat', async (req, res) => {
  const { conversation_id, message, attachments, model } = req.body || {};
  const modelo = MODELOS[model] ? model : MODEL;
  const convId = +conversation_id;
  if (!convId) return res.status(400).json({ error: 'conversation_id faltando' });
  if (!OAUTH) return res.status(503).json({ error: 'servidor sem setup-token do Claude' });

  const anexos = (attachments || []).slice(0, 5);
  const metaAnexos = anexos.map(a => ({ name: a.name, kind: a.kind, media_type: a.media_type }));

  const prompt = montarPrompt(convId, message, metaAnexos);   // histórico ANTES de gravar a nova
  db.prepare('INSERT INTO messages (conversation_id,role,text,attachments,created_at) VALUES (?,?,?,?,?)')
    .run(convId, 'user', message || '', JSON.stringify(metaAnexos), now());

  const conv = db.prepare('SELECT title FROM conversations WHERE id=?').get(convId);
  if (conv && conv.title === 'Nova conversa' && (message || '').trim()) {
    db.prepare('UPDATE conversations SET title=?, updated_at=? WHERE id=?').run(message.trim().slice(0, 48), now(), convId);
  }

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders && res.flushHeaders();

  const args = ['-p', '--model', (MODEL_ARG[modelo] || 'sonnet'),
    '--output-format', 'stream-json', '--include-partial-messages', '--verbose',
    '--settings', SETTINGS];
  if (SYSTEM_PROMPT) { args.push('--append-system-prompt', SYSTEM_PROMPT); }

  let textoFinal = '';
  let tin = 0, tout = 0, errou = null, done = false;
  const child = spawn(CLAUDE_BIN, args, {
    env: { ...process.env, CLAUDE_CODE_OAUTH_TOKEN: OAUTH, HOME: process.env.HOME || '/root' },
    stdio: ['pipe', 'pipe', 'pipe']
  });
  child.on('error', (e) => { errou = 'claude não pôde iniciar: ' + e.message; });
  try { child.stdin.write(prompt); child.stdin.end(); } catch (e) {}

  let buf = '';
  child.stdout.on('data', (chunk) => {
    buf += chunk.toString('utf8');
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const linha = buf.slice(0, idx); buf = buf.slice(idx + 1);
      if (!linha.trim()) continue;
      let ev; try { ev = JSON.parse(linha); } catch (e) { continue; }
      // deltas de texto (--include-partial-messages): stream_event → content_block_delta
      if (ev.type === 'stream_event' && ev.event) {
        const inner = ev.event;
        if (inner.type === 'content_block_delta' && inner.delta && inner.delta.type === 'text_delta') {
          textoFinal += inner.delta.text;
          res.write(`event: delta\ndata: ${JSON.stringify({ t: inner.delta.text })}\n\n`);
        } else if (inner.type === 'message_start' && inner.message && inner.message.usage) {
          tin = inner.message.usage.input_tokens || tin;
        } else if (inner.type === 'message_delta' && inner.usage) {
          tout = inner.usage.output_tokens || tout;
        }
      } else if (ev.type === 'result') {
        if (typeof ev.result === 'string' && !textoFinal) textoFinal = ev.result;   // fallback (sem partials)
        if (ev.usage) { tin = ev.usage.input_tokens || tin; tout = ev.usage.output_tokens || tout; }
        if (ev.subtype && ev.subtype !== 'success') errou = 'claude: ' + ev.subtype;
      } else if (ev.type === 'assistant' && ev.message && !textoFinal) {
        // fallback: se não vierem partials, pega o texto do bloco completo
        const t = (ev.message.content || []).filter(c => c.type === 'text').map(c => c.text).join('');
        if (t) { textoFinal = t; res.write(`event: delta\ndata: ${JSON.stringify({ t })}\n\n`); }
      }
    }
  });
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c.toString('utf8'); });

  child.on('close', (code) => {
    done = true;
    if (errou || (code !== 0 && !textoFinal)) {
      res.write(`event: erro\ndata: ${JSON.stringify({ detail: (errou || stderr.slice(0, 300) || ('claude saiu com código ' + code)) })}\n\n`);
    } else {
      res.write('event: fim\ndata: {}\n\n');
    }
    if (textoFinal) {
      db.prepare('INSERT INTO messages (conversation_id,role,text,attachments,tokens_in,tokens_out,created_at) VALUES (?,?,?,?,?,?,?)')
        .run(convId, 'assistant', textoFinal, '[]', tin, tout, now());
      db.prepare('UPDATE conversations SET updated_at=? WHERE id=?').run(now(), convId);
    }
    try { res.write(`event: uso\ndata: ${JSON.stringify({ in: tin, out: tout, plan: 'max', model: modelo, brl: custoBRL(modelo, tin, tout) })}\n\n`); } catch (e) {}
    res.end();
  });

  // se o NAVEGADOR desconectar no meio, encerra o claude (não desperdiça). Só mata
  // se ainda não terminou — o fim normal da resposta também dispara 'close'.
  res.on('close', () => { if (!done) { try { child.kill('SIGTERM'); } catch (e) {} } });
});

atualizarCambio();
app.listen(PORT, () => console.log(`[chat] ${APP_TITLE} na porta ${PORT} · modelo ${MODEL} · plano Max · claude ${OAUTH ? 'ok' : 'SEM TOKEN'}`));
