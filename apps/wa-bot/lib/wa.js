// lib/wa.js — cliente unico da RyzeAPI (WhatsApp).
//
// Base REST: https://ryzeapi.cloud  ·  Auth: header `token`.
// TOKEN UNICO: o RYZE_ACCOUNT_TOKEN (secret em /run/secrets) funciona pra
// TODAS as operacoes — conta e instancia (validado ao vivo). As funcoes de
// instancia mantem o parametro `token` por flexibilidade futura; passar null
// cai no token da conta. Nenhuma funcao lanca por status != 2xx — devolvem
// { ok, status, data } pro chamador decidir (erro de REDE lanca; quem nao
// pode lancar usa try/catch — ver bot/output.js).

const BASE = () => (process.env.RYZE_URL || 'https://ryzeapi.cloud').replace(/\/+$/, '');
const ACCT = () => process.env.RYZE_ACCOUNT_TOKEN || '';

const _headers = (token) => ({ 'Content-Type': 'application/json', token: token || '' });

// Token unico: o TokenAccount tem acesso a TUDO (conta dona de todas as
// instancias) — confirmado ao vivo, inclusive send. Callers passam o nome da
// instancia; o token cai no RYZE_ACCOUNT_TOKEN quando nao informado. Mantido o
// parametro `token` por flexibilidade (ex: token dedicado por instancia no
// futuro), mas hoje some a complexidade dos dois tokens.
async function _req(method, path, token, body) {
  const opt = { method, headers: _headers(token || ACCT()) };
  if (body !== undefined) opt.body = JSON.stringify(body);
  const r = await fetch(BASE() + path, opt);
  let data = null;
  try { data = await r.json(); } catch { data = null; }
  return { ok: r.ok, status: r.status, data };
}

// Ryze aceita numero so com digitos e converte pra JID internamente.
// Tolera receber JID (xxx@s.whatsapp.net) — extrai os digitos.
const _num = (n) => String(n || '').split('@')[0].replace(/\D/g, '');

/* ─────────────── Nivel conta (RYZE_ACCOUNT_TOKEN) ─────────────── */

async function createInstance(name) {
  const { ok, status, data } = await _req('POST', '/api/instance/new', ACCT(), { name });
  return { ok, status, token: data?.instance?.token || null, id: data?.instance?.id || null, data };
}

async function deleteInstance(name) {
  return _req('DELETE', `/api/instance/delete/${encodeURIComponent(name)}`, ACCT());
}

// Versao "crua" — devolve { ok, status, data } pra quem precisa distinguir
// "lista vazia" de "API fora do ar" (health-check do admin).
async function listAllFull() {
  return _req('GET', '/api/instance/list', ACCT());
}

async function listAll() {
  const { ok, data } = await listAllFull();
  return ok && Array.isArray(data?.instances) ? data.instances : [];
}

// Estado Ryze → rotulo legado que o painel/admin ja entendem ('open' quando
// conectado; o front do painel para o poll de QR quando ve 'open').
function legacyState(st) {
  if (st === 'connected') return 'open';
  if (st === 'connecting') return 'connecting';
  return 'close';
}

/* ─────────────── Nivel instancia (token da instancia) ─────────────── */

// number preenchido => força pairing-code; vazio => QR code.
async function connect(inst, token, number) {
  const q = number ? `?number=${_num(number)}` : '';
  const { ok, status, data } = await _req('GET', `/api/instance/connect/${encodeURIComponent(inst)}${q}`, token);
  const qb = data?.qrCodeBase64 || null;
  return {
    ok, status,
    qrCode: data?.qrCode || null,                         // ASCII
    qrBase64: qb ? (qb.startsWith('data:') ? qb : `data:image/png;base64,${qb}`) : null,
    pairingCode: data?.pairingCode || null,
    state: data?.status || null,
    data,
  };
}

async function reconnect(inst, token) {
  return _req('POST', `/api/instance/reconnect/${encodeURIComponent(inst)}`, token);
}

async function logout(inst, token) {
  return _req('DELETE', `/api/instance/logout/${encodeURIComponent(inst)}`, token);
}

// Status de UMA instancia. Normaliza o estado Ryze
// (connected|connecting|disconnected|closed|loggedout|banned).
async function status(inst, token) {
  // inst vazio = tenant sem conexão própria. NUNCA consultar a Ryze sem filtro:
  // instanceName= (vazio) lista a conta INTEIRA e o tenant novo "herdava" a
  // linha de outro dono no painel (vazamento cross-tenant, 2026-08-19).
  if (!inst) return { ok: false, exists: false, state: null, connected: false, numberJid: null, number: null, profile: null, raw: null };
  const { ok, data } = await _req('GET', `/api/instance/list?instanceName=${encodeURIComponent(inst)}`, token);
  const arr = ok && Array.isArray(data?.instances) ? data.instances : [];
  // Só aceita a instância cujo nome bate — adotar arr[0] "porque só tem uma"
  // devolve a linha de OUTRO tenant quando a API ignora o filtro.
  const one = arr.find((i) => i && i.name === inst) || null;
  const st = one?.connection?.state || one?.status || null;
  const jid = one?.connection?.numberJid || one?.numberJid || null;
  return {
    ok: !!one,
    exists: !!one,
    state: st,
    connected: st === 'connected',
    numberJid: jid,
    number: jid ? String(jid).split('@')[0] : null,
    profile: one?.profile || null,
    raw: one,
  };
}

async function setWebhook(inst, token, url, events, authorization) {
  return _req('POST', `/api/events/webhook/${encodeURIComponent(inst)}`, token, {
    label: 'default',
    enabled: true,
    url,
    events: events || ['message.exchange', 'instance.state', 'message.status'],
    mediaBase64: true, // audio/imagem chegam em base64 no payload (bot precisa pra Whisper)
    ...(authorization ? { authorization } : {}),
  });
}

async function findWebhook(inst, token) {
  const { ok, data } = await _req('GET', `/api/events/webhook/${encodeURIComponent(inst)}`, token);
  return { ok, data };
}

/* ─────────────── Sondagem de endpoints nao documentados ───────────────
 * A Ryze nao documenta foto de perfil de contato nem verificacao "numero tem
 * WhatsApp?". Sondamos candidatos plausiveis UMA vez (404 = endpoint nao
 * existe) e memorizamos o que responder; sem endpoint, degradamos graceful —
 * o chamador recebe null/unknown e segue com fallback. Re-sonda a cada 6h. */

const _PROBE_TTL_MS = 6 * 3600 * 1000;

async function _probePost(cacheBox, candidates, inst, token, body) {
  const call = (ep) => _req('POST', `${ep}/${encodeURIComponent(inst)}`, token, body);
  if (cacheBox.ep) return call(cacheBox.ep);
  if (cacheBox.failedAt && Date.now() - cacheBox.failedAt < _PROBE_TTL_MS) return null;
  for (const ep of candidates) {
    const r = await call(ep);
    if (r.status === 404) continue; // endpoint inexistente — proximo candidato
    cacheBox.ep = ep;
    console.log(`[WA] endpoint sondado com sucesso: ${ep}`);
    return r;
  }
  cacheBox.failedAt = Date.now();
  return null;
}

// Foto de perfil de um CONTATO (nao da instancia). null = sem foto.
// Endpoint oficial "Verificar conta" (docs.ryzeapi.cloud/pt/api/profile/
// read-account): GET /api/profile/getAccount/:inst?number= → profile.
// profilePicture e URL CDN do WhatsApp, TEMPORARIA — o chamador re-hospeda
// (fetchAndStoreProfilePic). BR: o servico ja tenta com/sem o 9o digito.
async function profilePic(inst, token, number) {
  const num = _num(number);
  if (!num || !inst) return null;
  try {
    const { ok, data } = await _req(
      'GET',
      `/api/profile/getAccount/${encodeURIComponent(inst)}?number=${encodeURIComponent(num)}`,
      token,
    );
    if (!ok || !data?.success) return null;
    return data.profile?.profilePicture || null;
  } catch { return null; }
}

// Numero existe no WhatsApp? { known:false } quando nao ha como verificar
// (sem endpoint / erro) — o chamador decide se envia mesmo assim.
const _chkProbe = {};
async function numberExists(inst, token, number) {
  const num = _num(number);
  if (!num || !inst) return { known: false };
  try {
    const r = await _probePost(_chkProbe, [
      '/api/chat/whatsappNumbers',
      '/api/chat/checkNumber',
      '/api/contact/check',
    ], inst, token, { number: num, numbers: [num] });
    if (!r || !r.ok) return { known: false };
    const d = r.data;
    const item = Array.isArray(d) ? d[0]
      : Array.isArray(d?.numbers) ? d.numbers[0]
      : Array.isArray(d?.data) ? d.data[0] : d;
    if (item && typeof item.exists === 'boolean') return { known: true, exists: item.exists };
    return { known: false };
  } catch { return { known: false }; }
}

/* ─────────────── Mensagens ─────────────── */

async function sendText(inst, token, number, message, extra = {}) {
  return _req('POST', `/api/message/text/${encodeURIComponent(inst)}`, token, {
    number: _num(number), message, linkPreview: false, ...extra,
  });
}

// Botoes quick-reply (max 3 — limite do WhatsApp). buttons: [{id, displayText}].
// GOTCHA validado ao vivo (2026-07-31): botao de URL NAO funciona — a Ryze
// converte tudo em buttonType RESPONSE (o clique gera webhook buttons_response
// com interactive.selectedButtonId; nunca abre navegador). Links vao no TEXTO.
async function sendButtons(inst, token, number, contentText, buttons) {
  return _req('POST', `/api/message/button/${encodeURIComponent(inst)}`, token, {
    number: _num(number),
    contentText,
    buttons: (buttons || []).slice(0, 3).map(b => ({ id: b.id, displayText: b.displayText })),
  });
}

async function sendAudio(inst, token, number, base64, mimetype = 'audio/ogg; codecs=opus') {
  const b64 = String(base64 || '').replace(/^data:[^;]+;base64,/, '');
  return _req('POST', `/api/message/media/${encodeURIComponent(inst)}`, token, {
    number: _num(number), mediaType: 'audio', mediaBase64: b64, mimetype,
  });
}

/* ─────────────── Parser do webhook de entrada ───────────────
 * Evento Ryze `message.exchange`. Defensivo: aceita variacoes de campo ate
 * cravarmos o shape real no cutover (a doc ja errou 'text' vs 'message').
 * Loga o raw na primeira mensagem real pra confirmar. */
function parseInbound(body) {
  // SHAPE REAL confirmado ao vivo (raw inbound 2026-07-31):
  // { event:"message.exchange",
  //   data:{ id, direction:"incoming"|"outgoing", timestamp:"ISO",
  //          chat:{jid,lid,name,type}, sender:{jid,lid,name}, recipient:{...},
  //          message:{ type:"text"|..., content, source:"api"|..., media,
  //                    location, contact, reaction, ... } },
  //   instanceData:{ baseUrl, instance, token } }
  // Fallbacks da doc mantidos por defesa (a doc ja divergiu do real).
  const event = body?.event || null;
  const instance = body?.instanceData?.instance || body?.instance || body?.instanceName || null;
  const d = body?.data || {};
  const m = d.message || {};
  const chat = d.chat || m.chat || {};
  const sender = d.sender || m.sender || {};
  const chatJid = chat.jid || chat.id || null;
  // Sender pode vir SO com @lid (numero oculto/privacidade). @lid NAO e
  // telefone — nunca fabricar jid canonico a partir dele; se o chat tiver o
  // jid real, usa o do chat.
  const rawJid = sender.jid || sender.id || chatJid || '';
  const jid = (String(rawJid).endsWith('@lid') && String(chatJid || '').endsWith('@s.whatsapp.net'))
    ? chatJid : rawJid;
  const number = String(jid).endsWith('@lid') ? null
    : (jid ? String(jid).split('@')[0].replace(/\D/g, '') : null);
  // status/recado, listas de transmissao e canais nao sao chat 1:1 do bot.
  const isBroadcast = /@broadcast|@newsletter/.test(String(chatJid || rawJid));
  // direction: 'incoming' = cliente falou; 'outgoing' = a PROPRIA conta enviou
  // (operador na mao OU eco da API — o `source` distingue).
  const fromMe = d.direction ? d.direction === 'outgoing' : !!(m.fromMe ?? d.fromMe);
  // timestamp real vem ISO-8601; o bot espera epoch em segundos.
  let ts = d.timestamp || m.timestamp || m.messageTimestamp || null;
  if (typeof ts === 'string') {
    const p = Date.parse(ts);
    ts = Number.isFinite(p) ? Math.floor(p / 1000) : null;
  }
  const media = m.media || m.audio || m.audioMessage || null;
  const textBody = (typeof m.content === 'string') ? m.content
    : ((m.text && (m.text.body ?? m.text)) ??
       (typeof m.conversation === 'string' ? m.conversation : null));
  const type = m.type || (media ? (media.type || 'media') : (textBody != null ? 'text' : null));
  return {
    event, instance, fromMe,
    // Origem do envio ('api' = eco de envio da propria API; distingue do
    // operador digitando na mao — confirmado no raw real).
    source: m.source || d.source || null,
    // chatJid = o CHAT (peer); em fromMe o sender e o dono, entao a pausa
    // humana deve usar o chatJid.
    chatJid,
    id: d.id || m.id || null,
    timestamp: ts,
    from: jid || null,
    number,
    name: sender.name || d.pushName || m.pushName || null,
    // Foto do remetente: a Ryze NAO tem endpoint sob demanda; quando o contato
    // tem foto visivel ela vem no proprio webhook. Capturada aqui e cacheada
    // na rota pro CRM usar (fetchAndStoreProfilePic).
    picUrl: sender.pictureUrl || sender.profilePicUrl || sender.imgUrl || null,
    type,
    // Clique em botao: type="buttons_response", content vazio, id do botao em
    // interactive.selectedButtonId (shape real capturado 2026-07-31).
    buttonId: m.interactive?.selectedButtonId || null,
    text: (typeof textBody === 'string') ? textBody : null,
    audioBase64: media ? (media.base64 || media.mediaBase64 || media.data || null) : null,
    audioUrl: media ? (media.url || null) : null,
    audioMime: media ? (media.mimeType || media.mimetype || null) : null,
    isGroup: chat.type === 'group' || String(chatJid || jid).includes('@g.us'),
    isBroadcast,
    raw: m,
  };
}

module.exports = {
  createInstance, deleteInstance, listAll, listAllFull, legacyState,
  connect, reconnect, logout, status, setWebhook, findWebhook,
  profilePic, numberExists,
  sendText, sendButtons, sendAudio, parseInbound,
  _num, BASE,
};
