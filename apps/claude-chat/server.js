'use strict';
// ── Chat Claude do Motobase — via Claude Code (plano Max, SEM créditos de API) ──
// Duas bocas, um mesmo Claude:
//   · ASSISTENTE: `claude -p` aqui dentro do container, sem ferramenta nenhuma
//     (chat-settings.json nega tudo). Memória = histórico da conversa (SQLite)
//     + nota "Sobre mim" de cada pessoa + REGRAS globais do dono.
//   · VPS (só o dono): o pedido vai pra PORTA — o Claude Code do HOST, que
//     enxerga e opera a máquina. Sessão por conversa (--resume); modo LEITURA
//     por padrão e modo MASTER (senha mestra + código de 4 dígitos) por 3 h.
// Identidade: quem fala é descoberto pela tailnet (identidade.js) — sem login.
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const express = require('express');
const Database = require('better-sqlite3');
const auth = require('./auth');
const identidade = require('./identidade');
const canal2fa = require('./canal-2fa');
const porta = require('./porta-cliente');

const PORT = process.env.PORT || 3000;
const MODELOS = { opus: 'Opus', sonnet: 'Sonnet', haiku: 'Haiku', fable: 'Fable' };
const MODEL_ARG = { opus: 'opus', sonnet: 'sonnet', haiku: 'haiku', fable: 'claude-fable-5-1' };
const MODEL = MODELOS[process.env.MODEL] ? process.env.MODEL : 'sonnet';
const APP_TITLE = process.env.APP_TITLE || 'Claude';
const PROJ_NAME = process.env.PROJ_NAME || APP_TITLE;
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT || '';
const DATA_DIR = process.env.DATA_DIR || '/data';
const CLAUDE_BIN = process.env.CLAUDE_BIN || 'claude';
const SETTINGS = process.env.CHAT_SETTINGS || path.join(__dirname, 'chat-settings.json');
const MEM_TURNS = parseInt(process.env.MEM_TURNS || '20', 10);
const REGRAS = path.join(DATA_DIR, 'regras.md');

// preços de referência (US$ por 1M tokens). No plano Max NÃO se paga por token.
const PRECOS = { opus: { in: 5, out: 25 }, sonnet: { in: 2, out: 10 }, haiku: { in: 1, out: 5 }, fable: { in: 10, out: 50 } };
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
  return +(((tin / 1e6) * p.in + (tout / 1e6) * p.out) * USD_BRL).toFixed(4);
}

function lerOAuth() {
  for (const f of ['/run/secrets/claude_oauth_token', '/run/secrets/anthropic_oauth_token']) {
    try { if (fs.existsSync(f)) return fs.readFileSync(f, 'utf8').trim(); } catch (e) {}
  }
  return (process.env.CLAUDE_CODE_OAUTH_TOKEN || '').trim();
}
const OAUTH = lerOAuth();
if (!OAUTH) console.warn('[chat] AVISO: sem setup-token do Claude — o chat sobe, mas o modo assistente vai falhar. Informe o sk-ant-oat.');

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
  CREATE TABLE IF NOT EXISTS perfis (
    login TEXT PRIMARY KEY,
    nota TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL
  );
`);
// migrações aditivas (instalações que já tinham o chat)
for (const [tab, col] of [
  ['messages', 'tokens_in INTEGER'], ['messages', 'tokens_out INTEGER'], ['messages', 'cost_usd REAL'], ['messages', 'cost_brl REAL'],
  ['messages', 'segundos INTEGER'],
  ['conversations', "user_login TEXT NOT NULL DEFAULT 'tailnet'"], ['conversations', "mode TEXT NOT NULL DEFAULT 'assistente'"],
  ['conversations', 'session_id TEXT']
]) { try { db.exec(`ALTER TABLE ${tab} ADD COLUMN ${col}`); } catch (e) { /* já existe */ } }
db.exec('CREATE INDEX IF NOT EXISTS idx_conv_user ON conversations(user_login, updated_at)');
const now = () => Date.now();

function lerRegras() { try { return fs.readFileSync(REGRAS, 'utf8'); } catch (e) { return ''; } }
function lerNota(login) { const r = db.prepare('SELECT nota FROM perfis WHERE login=?').get(login); return r ? r.nota : ''; }

// ── app ─────────────────────────────────────────────────────────────────────
const app = express();
app.disable('x-powered-by');
app.set('trust proxy', true);
app.use(express.json({ limit: '120mb' }));
app.use(express.static(path.join(__dirname, 'public')));

// quem é (tailnet) — em toda rota /api
app.use('/api', (req, res, next) => {
  identidade.identificar(req).then(eu => { req.eu = eu; next(); }).catch(() => {
    req.eu = { login: 'tailnet', nome: 'tailnet', identidade: 'anonimo', dono: false }; next();
  });
});
const soDono = (req, res, next) => (req.eu && req.eu.dono) ? next() : res.status(403).json({ error: 'só o dono da VPS pode fazer isso' });
const minhaConv = (req, id) => db.prepare('SELECT id,title,mode,session_id,user_login FROM conversations WHERE id=? AND user_login=?').get(+id, req.eu.login);

app.get('/api/config', (req, res) => res.json({ title: APP_TITLE, model: MODEL, models: MODELOS, plan: 'max' }));
app.get('/healthz', (req, res) => res.json({ ok: true, oauth: !!OAUTH, porta: porta.disponivel(), tailscale: identidade.disponivel() }));

app.get('/api/me', (req, res) => {
  const ate = porta.disponivel() ? porta.masterAte() : null;
  res.json({
    login: req.eu.login, nome: req.eu.nome, identidade: req.eu.identidade, dono: !!req.eu.dono,
    ip: req.eu.ip || null, motivo: req.eu.motivo || null, dono_esperado: req.eu.dono_esperado || null,
    porta: porta.disponivel(), tailscale: identidade.disponivel(),
    master: { aberto: !!ate, ate, tem_senha: auth.temSenha(), bloqueado_seg: auth.bloqueado(), canal: canal2fa.canal() }
  });
});

// ── conversas (cada pessoa vê só as suas) ───────────────────────────────────
app.get('/api/conversations', (req, res) => {
  res.json(db.prepare('SELECT id,title,updated_at,mode FROM conversations WHERE user_login=? ORDER BY updated_at DESC').all(req.eu.login));
});
app.post('/api/conversations', (req, res) => {
  const mode = (req.body && req.body.mode) === 'vps' ? 'vps' : 'assistente';
  if (mode === 'vps' && !req.eu.dono) return res.status(403).json({ error: 'a conversa com a VPS é só do dono' });
  if (mode === 'vps' && !porta.disponivel()) return res.status(503).json({ error: 'a porta da VPS não está instalada (rode: motobase chat)' });
  const t = now();
  const info = db.prepare('INSERT INTO conversations (title,created_at,updated_at,user_login,mode) VALUES (?,?,?,?,?)')
    .run(mode === 'vps' ? 'Conversa com a VPS' : 'Nova conversa', t, t, req.eu.login, mode);
  res.json({ id: info.lastInsertRowid, title: mode === 'vps' ? 'Conversa com a VPS' : 'Nova conversa', mode });
});
app.get('/api/conversations/:id', (req, res) => {
  const conv = minhaConv(req, req.params.id);
  if (!conv) return res.status(404).json({ error: 'não encontrada' });
  const msgs = db.prepare('SELECT role,text,attachments,tokens_in,tokens_out,segundos,cost_brl,created_at FROM messages WHERE conversation_id=? ORDER BY id').all(conv.id)
    .map(m => ({ role: m.role, text: m.text, attachments: JSON.parse(m.attachments || '[]'),
      usage: (m.tokens_out != null ? { in: m.tokens_in, out: m.tokens_out, plan: 'max', brl: m.cost_brl, segundos: m.segundos } : null),
      created_at: m.created_at }));
  res.json({ id: conv.id, title: conv.title, mode: conv.mode, messages: msgs });
});
app.delete('/api/conversations/:id', (req, res) => {
  const conv = minhaConv(req, req.params.id);
  if (!conv) return res.status(404).json({ error: 'não encontrada' });
  db.prepare('DELETE FROM messages WHERE conversation_id=?').run(conv.id);
  db.prepare('DELETE FROM conversations WHERE id=?').run(conv.id);
  res.json({ ok: true });
});

// ── regras (dono escreve, todos leem) e nota "Sobre mim" (cada um a sua) ────
app.get('/api/rules', (req, res) => res.json({ texto: lerRegras(), pode_editar: !!req.eu.dono }));
app.put('/api/rules', soDono, (req, res) => {
  const texto = String((req.body && req.body.texto) || '').slice(0, 20000);
  fs.writeFileSync(REGRAS, texto);
  res.json({ ok: true });
});
app.get('/api/me/nota', (req, res) => res.json({ texto: lerNota(req.eu.login) }));
app.put('/api/me/nota', (req, res) => {
  const texto = String((req.body && req.body.texto) || '').slice(0, 8000);
  db.prepare('INSERT INTO perfis (login,nota,updated_at) VALUES (?,?,?) ON CONFLICT(login) DO UPDATE SET nota=excluded.nota, updated_at=excluded.updated_at')
    .run(req.eu.login, texto, now());
  res.json({ ok: true });
});

// ── modo MASTER: senha mestra + código por outro canal (mesmo cofre da porta) ──
const fluxo2fa = new Map();   // login → { passo:'codigo', exp }
app.post('/api/master/senha', soDono, async (req, res) => {
  if (!porta.disponivel()) return res.status(503).json({ error: 'a porta da VPS não está instalada (rode: motobase chat)' });
  if (!auth.temSenha()) return res.status(503).json({ error: 'nenhuma senha mestra definida — na VPS rode: motobase senha' });
  const falta = auth.bloqueado();
  if (falta) return res.status(423).json({ error: `travado por ${Math.ceil(falta / 60)} min — tentativas erradas demais`, bloqueado_seg: falta });
  const senha = String((req.body && req.body.senha) || '');
  if (!senha || !auth.checaSenha(senha)) {
    const f = auth.bloqueado();
    if (f) {
      canal2fa.avisar(`${PROJ_NAME}: 3 senhas erradas no chat (${req.eu.login}). Modo master travado por 15 min. Se nao foi voce, troque a senha: motobase senha.`);
      return res.status(423).json({ error: 'errou 3 vezes — travado por 15 min', bloqueado_seg: f });
    }
    return res.status(401).json({ error: 'senha errada' });
  }
  const codigo = auth.geraOtp();
  const envio = await canal2fa.enviarCodigo(codigo, PROJ_NAME);
  if (!envio.ok) { fluxo2fa.delete(req.eu.login); return res.status(503).json({ error: 'senha certa, mas não consegui entregar o código: ' + envio.dica }); }
  fluxo2fa.set(req.eu.login, { passo: 'codigo', exp: Date.now() + auth.OTP_TTL * 1000 });
  res.json({ ok: true, canal: envio.canal, dica: envio.dica });
});
app.post('/api/master/codigo', soDono, (req, res) => {
  const f = fluxo2fa.get(req.eu.login);
  if (!f || Date.now() > f.exp) { fluxo2fa.delete(req.eu.login); return res.status(410).json({ error: 'o código venceu — comece de novo pela senha' }); }
  const r = auth.checaOtp(String((req.body && req.body.codigo) || ''));
  if (r === 'ok') {
    fluxo2fa.delete(req.eu.login);
    const ate = porta.abrirMaster(auth.MASTER_TTL);
    console.log(`[chat] MASTER aberto por ${req.eu.login} até ${new Date(ate).toISOString()}`);
    return res.json({ ok: true, ate });
  }
  if (r === 'expirado') { fluxo2fa.delete(req.eu.login); return res.status(410).json({ error: 'o código venceu — comece de novo pela senha' }); }
  if (r === 'travado') {
    fluxo2fa.delete(req.eu.login);
    canal2fa.avisar(`${PROJ_NAME}: 3 codigos errados no chat (${req.eu.login}). Modo master travado por 15 min.`);
    return res.status(423).json({ error: 'errou o código 3 vezes — travado por 15 min', bloqueado_seg: auth.bloqueado() });
  }
  res.status(401).json({ error: 'código errado' });
});
app.post('/api/master/fechar', soDono, (req, res) => {
  fluxo2fa.delete(req.eu.login);
  if (porta.disponivel()) porta.fecharMaster();
  res.json({ ok: true });
});

// ── mensagem → resposta (SSE) ───────────────────────────────────────────────
function sse(res) {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders && res.flushHeaders();
  return (ev, dados) => { try { res.write(`event: ${ev}\ndata: ${JSON.stringify(dados || {})}\n\n`); } catch (e) {} };
}
function gravarResposta(convId, texto, tin, tout, brl, segundos) {
  if (!texto) return;
  db.prepare('INSERT INTO messages (conversation_id,role,text,attachments,tokens_in,tokens_out,cost_brl,segundos,created_at) VALUES (?,?,?,?,?,?,?,?,?)')
    .run(convId, 'assistant', texto, '[]', tin, tout, brl, segundos || null, now());
  db.prepare('UPDATE conversations SET updated_at=? WHERE id=?').run(now(), convId);
}

// histórico (texto) + anexos da mensagem atual como blocos nativos (imagem/pdf)
function montarConteudo(req, convId, message, anexos) {
  const rows = db.prepare('SELECT role,text,attachments FROM messages WHERE conversation_id=? ORDER BY id DESC LIMIT ?')
    .all(convId, MEM_TURNS * 2).reverse();
  let historico = '';
  for (const r of rows) {
    const meta = JSON.parse(r.attachments || '[]');
    const marca = meta.length ? ` [${meta.length} anexo(s): ${meta.map(m => m.name).join(', ')}]` : '';
    historico += (r.role === 'user' ? 'Humano' : 'Assistente') + ': ' + (r.text || '') + marca + '\n\n';
  }
  const texto = historico + 'Humano: ' + (message || (anexos.length ? '(veja o(s) anexo(s))' : '')) + '\n\nAssistente:';
  const content = [{ type: 'text', text: texto }];
  for (const a of anexos) {
    if (!a.data) continue;
    if (a.kind === 'pdf') content.push({ type: 'document', source: { type: 'base64', media_type: a.media_type || 'application/pdf', data: a.data } });
    else content.push({ type: 'image', source: { type: 'base64', media_type: a.media_type || 'image/jpeg', data: a.data } });
  }
  return content;
}
function promptAssistente(req) {
  const partes = [];
  partes.push(`Você é o assistente de ${PROJ_NAME}, num chat privado da tailnet. Quem fala é ${req.eu.nome}${req.eu.identidade === 'tailscale' ? ` (${req.eu.login})` : ''}. Responda em PT-BR, direto.`);
  if (SYSTEM_PROMPT) partes.push(SYSTEM_PROMPT);
  partes.push('Você NÃO opera a VPS nesta conversa (é o assistente). Quem opera é a "Conversa com a VPS", que só o dono vê na barra lateral. '
    + 'Lá, em modo LEITURA (sem senha), o Claude já lê tudo: containers, serviços, portas, configs, logs, banco (SELECT), certificados, cron — auditoria e diagnóstico não precisam de master. '
    + 'O botão "Liberar master" (senha mestra + código de 4 dígitos) só é necessário pra ESCREVER: criar app, editar arquivo, subir serviço, deploy — e vale por 3 horas. '
    + 'Se pedirem auditoria, levantamento ou "liberar master" aqui, explique isso em 2 linhas e mande pra Conversa com a VPS.');
  const regras = lerRegras().trim(); if (regras) partes.push('REGRAS DO DONO (valem para todos):\n' + regras.slice(0, 8000));
  const nota = lerNota(req.eu.login).trim(); if (nota) partes.push('SOBRE QUEM FALA COM VOCÊ (escrito pela própria pessoa):\n' + nota.slice(0, 4000));
  return partes.join('\n\n');
}

app.post('/api/chat', async (req, res) => {
  const { conversation_id, message, attachments, model } = req.body || {};
  const modelo = MODELOS[model] ? model : MODEL;
  const conv = minhaConv(req, conversation_id);
  if (!conv) return res.status(404).json({ error: 'conversa não encontrada' });
  const anexos = (attachments || []).slice(0, 5);
  const metaAnexos = anexos.map(a => ({ name: a.name, kind: a.kind, media_type: a.media_type }));

  if (conv.mode === 'vps') {
    if (!req.eu.dono) return res.status(403).json({ error: 'a conversa com a VPS é só do dono' });
    if (!porta.disponivel()) return res.status(503).json({ error: 'a porta da VPS não está instalada (rode: motobase chat)' });
    return chatVps(req, res, conv, modelo, message, anexos, metaAnexos);
  }
  if (!OAUTH) return res.status(503).json({ error: 'servidor sem setup-token do Claude' });

  const conteudo = montarConteudo(req, conv.id, message, anexos);   // histórico ANTES de gravar a nova
  db.prepare('INSERT INTO messages (conversation_id,role,text,attachments,created_at) VALUES (?,?,?,?,?)')
    .run(conv.id, 'user', message || '', JSON.stringify(metaAnexos), now());
  if (conv.title === 'Nova conversa' && (message || '').trim()) {
    db.prepare('UPDATE conversations SET title=?, updated_at=? WHERE id=?').run(message.trim().slice(0, 48), now(), conv.id);
  }
  const emitir = sse(res);
  const args = ['-p', '--model', (MODEL_ARG[modelo] || 'sonnet'),
    '--input-format', 'stream-json', '--output-format', 'stream-json', '--include-partial-messages', '--verbose',
    '--settings', SETTINGS, '--append-system-prompt', promptAssistente(req)];

  let textoFinal = '', tin = 0, tout = 0, errou = null, done = false;
  const inicio = Date.now();
  const child = spawn(CLAUDE_BIN, args, { env: { ...process.env, CLAUDE_CODE_OAUTH_TOKEN: OAUTH, HOME: process.env.HOME || '/root' }, stdio: ['pipe', 'pipe', 'pipe'] });
  child.on('error', (e) => { errou = 'claude não pôde iniciar: ' + e.message; });
  try { child.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: conteudo } }) + '\n'); child.stdin.end(); } catch (e) {}
  let buf = '';
  child.stdout.on('data', (chunk) => {
    buf += chunk.toString('utf8');
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const linha = buf.slice(0, idx); buf = buf.slice(idx + 1);
      if (!linha.trim()) continue;
      let ev; try { ev = JSON.parse(linha); } catch (e) { continue; }
      if (ev.type === 'stream_event' && ev.event) {
        const inner = ev.event;
        if (inner.type === 'content_block_delta' && inner.delta && inner.delta.type === 'text_delta') {
          textoFinal += inner.delta.text; emitir('delta', { t: inner.delta.text });
        } else if (inner.type === 'message_start' && inner.message && inner.message.usage) tin = inner.message.usage.input_tokens || tin;
        else if (inner.type === 'message_delta' && inner.usage) tout = inner.usage.output_tokens || tout;
      } else if (ev.type === 'result') {
        if (typeof ev.result === 'string' && !textoFinal) { textoFinal = ev.result; emitir('delta', { t: ev.result }); }
        if (ev.usage) { tin = ev.usage.input_tokens || tin; tout = ev.usage.output_tokens || tout; }
        if (ev.subtype && ev.subtype !== 'success') errou = 'claude: ' + ev.subtype;
      } else if (ev.type === 'assistant' && ev.message && !textoFinal) {
        const t = (ev.message.content || []).filter(c => c.type === 'text').map(c => c.text).join('');
        if (t) { textoFinal = t; emitir('delta', { t }); }
      }
    }
  });
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c.toString('utf8'); });
  child.on('close', (code) => {
    done = true;
    const segundos = Math.round((Date.now() - inicio) / 1000);
    if (errou || (code !== 0 && !textoFinal)) emitir('erro', { detail: errou || stderr.slice(0, 300) || ('claude saiu com código ' + code) });
    const brl = custoBRL(modelo, tin, tout);
    gravarResposta(conv.id, textoFinal, tin, tout, brl, segundos);
    emitir('uso', { in: tin, out: tout, plan: 'max', model: modelo, brl, segundos });
    emitir('fim', {});
    res.end();
  });
  res.on('close', () => { if (!done) { try { child.kill('SIGTERM'); } catch (e) {} } });
});

// conversa com a VPS: o pedido vai pra porta (Claude Code do host)
async function chatVps(req, res, conv, modelo, message, anexos, metaAnexos) {
  const caminhos = [];
  const idAnexo = String(Date.now());
  for (const a of anexos) { try { if (a.data) caminhos.push(porta.salvarUpload(idAnexo, a)); } catch (e) {} }
  let texto = (message || '').trim();
  if (caminhos.length) texto += (texto ? '\n\n' : '') + 'Anexos (leia com sua ferramenta de arquivo): ' + caminhos.join(', ');
  if (!texto) return res.status(400).json({ error: 'mensagem vazia' });

  db.prepare('INSERT INTO messages (conversation_id,role,text,attachments,created_at) VALUES (?,?,?,?,?)')
    .run(conv.id, 'user', message || '', JSON.stringify(metaAnexos), now());
  if (conv.title === 'Conversa com a VPS' && (message || '').trim()) {
    db.prepare('UPDATE conversations SET title=?, updated_at=? WHERE id=?').run('VPS · ' + message.trim().slice(0, 40), now(), conv.id);
  }
  const emitir = sse(res);
  let textoFinal = '', done = false;
  const inicio = Date.now();
  const sessao = conv.session_id || require('crypto').randomUUID();
  if (!conv.session_id) db.prepare('UPDATE conversations SET session_id=? WHERE id=?').run(sessao, conv.id);
  const ped = { texto, origem: 'chat', usuario: `${req.eu.nome} (${req.eu.login})`, sessao, modelo, regras: lerRegras().slice(0, 4000) };
  const { promessa, cancelar } = porta.pedir(ped, (ev) => {
    if (ev.tipo === 'delta') { textoFinal += ev.t; emitir('delta', { t: ev.t }); }
    else if (ev.tipo === 'estado') emitir('estado', { texto: ev.texto });
    else if (ev.tipo === 'erro') emitir('erro', { detail: ev.detail });
  });
  res.on('close', () => { if (!done) cancelar(); });
  try {
    const fim = await promessa;
    done = true;
    if (fim.sessao_nova && fim.sessao) db.prepare('UPDATE conversations SET session_id=? WHERE id=?').run(fim.sessao, conv.id);
    const u = fim.uso || {};
    const tin = u.entrada || 0, tout = u.saida || 0;
    const brl = (u.usd != null) ? +(u.usd * USD_BRL).toFixed(4) : custoBRL(modelo, tin, tout);
    const segundos = fim.segundos != null ? fim.segundos : Math.round((Date.now() - inicio) / 1000);
    gravarResposta(conv.id, textoFinal, tin, tout, brl, segundos);
    emitir('uso', { in: tin, out: tout, plan: 'max', model: fim.modelo || modelo, brl, segundos });
  } catch (e) {
    done = true;
    emitir('erro', { detail: e.message });
    gravarResposta(conv.id, textoFinal, 0, 0, 0, Math.round((Date.now() - inicio) / 1000));
  }
  emitir('fim', {});
  res.end();
}

atualizarCambio();
app.listen(PORT, () => console.log(`[chat] ${APP_TITLE} na porta ${PORT} · modelo ${MODEL} · plano Max · claude ${OAUTH ? 'ok' : 'SEM TOKEN'} · porta ${porta.disponivel() ? 'ok' : 'ausente'} · tailscale ${identidade.disponivel() ? 'ok' : 'ausente'}`));
