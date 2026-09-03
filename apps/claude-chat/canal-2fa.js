'use strict';
// ── Por onde sai o código de 4 dígitos do modo master ─────────────────────────
// A segunda prova tem que chegar por um canal DIFERENTE do chat. Ordem:
//   1. WhatsApp do dono (RyzeAPI, quando o bot de WhatsApp foi instalado e o
//      número do dono foi informado no wizard) — igual ao motobot_alerta.
//   2. Telegram (o bot dos alertas do watchdog, quando existe).
//   3. Arquivo na VPS (<PORTA_BASE>/codigo-master.txt, root-only): quem tem SSH
//      na máquina lê com `motobase codigo`. A chave SSH é a segunda prova.
const fs = require('fs');
const path = require('path');

const BASE = process.env.PORTA_BASE || '/opt/porta';
const DATA_DIR = process.env.DATA_DIR || '/data';
const ARQUIVO = path.join(BASE, 'codigo-master.txt');

function segredo(arquivo, env) {
  try { if (fs.existsSync(arquivo)) return fs.readFileSync(arquivo, 'utf8').trim(); } catch (e) {}
  return (process.env[env] || '').trim();
}
const RYZE = {
  base: (process.env.RYZE_BASE || 'https://ryzeapi.cloud').replace(/\/$/, ''),
  token: segredo('/run/secrets/ryze_account_token', 'RYZE_ACCOUNT_TOKEN'),
  inst: (process.env.WA_INST || '').trim(),
  numero: (process.env.DONO_WHATSAPP || '').replace(/\D/g, '')
};
const TG = { token: segredo('/run/secrets/tg_token', 'TG_TOKEN'), chat: (process.env.TG_CHAT || '').trim() };

function temWhatsapp() { return !!(RYZE.token && RYZE.inst && RYZE.numero); }
function temTelegram() { return !!TG.token; }
function canal() { return temWhatsapp() ? 'whatsapp' : (temTelegram() ? 'telegram' : 'arquivo'); }

let ultimoErroWa = '';
async function whatsapp(texto) {
  const r = await fetch(`${RYZE.base}/api/message/text/${encodeURIComponent(RYZE.inst)}`, {
    method: 'POST', headers: { 'content-type': 'application/json', token: RYZE.token },
    body: JSON.stringify({ number: RYZE.numero, message: texto, linkPreview: false }), signal: AbortSignal.timeout(15000)
  });
  if (!r.ok) {
    let corpo = ''; try { corpo = (await r.text()).replace(/\s+/g, ' ').slice(0, 160); } catch (e) {}
    ultimoErroWa = `Ryze HTTP ${r.status} na instância ${RYZE.inst}${corpo ? ': ' + corpo : ''}`;
    console.warn('[chat] 2FA WhatsApp falhou — ' + ultimoErroWa);
  }
  return r.ok;
}

// chat id do Telegram: o dono manda /start pro bot uma vez; descobrimos e guardamos
async function tgChat() {
  if (TG.chat) return TG.chat;
  const f = path.join(DATA_DIR, 'tg-chat.txt');
  try { const v = fs.readFileSync(f, 'utf8').trim(); if (v) { TG.chat = v; return v; } } catch (e) {}
  try {
    const r = await fetch(`https://api.telegram.org/bot${TG.token}/getUpdates`, { signal: AbortSignal.timeout(8000) });
    const j = await r.json();
    const m = JSON.stringify(j).match(/"chat":\{"id":(-?\d+)/);
    if (m) { TG.chat = m[1]; try { fs.writeFileSync(f, m[1]); } catch (e) {} return m[1]; }
  } catch (e) {}
  return '';
}
async function telegram(texto) {
  const chat = await tgChat();
  if (!chat) return false;
  const r = await fetch(`https://api.telegram.org/bot${TG.token}/sendMessage`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ chat_id: chat, text: texto }), signal: AbortSignal.timeout(10000)
  });
  return r.ok;
}
function arquivo(codigo) {
  try {
    fs.mkdirSync(BASE, { recursive: true });
    fs.writeFileSync(ARQUIVO, `${codigo}\n(codigo do modo master, vale 5 min, gerado em ${new Date().toISOString()})\n`, { mode: 0o600 });
    try { fs.chmodSync(ARQUIVO, 0o600); } catch (e) {}
    return true;
  } catch (e) { return false; }
}

// devolve { canal, ok, dica } — `dica` é o que o front mostra pro dono saber onde olhar.
// Ordem: WhatsApp → Telegram → arquivo na VPS. O arquivo é o plano B que SEMPRE existe:
// sem ele o dono ficava trancado fora do master quando o bot ainda não estava pareado.
async function enviarCodigo(codigo, projeto) {
  const texto = `${projeto}: ${codigo} e o codigo pra liberar o modo MASTER do chat por 3 horas. Vale 5 minutos. Se nao foi voce que pediu, ignore e troque a senha (motobase senha).`;
  const falhas = [];
  if (temWhatsapp()) {
    let ok = false; try { ok = await whatsapp(texto); } catch (e) { ultimoErroWa = e.message; }
    if (ok) return { canal: 'whatsapp', ok: true, dica: `enviado para o WhatsApp final ${RYZE.numero.slice(-4)}` };
    falhas.push('WhatsApp: ' + (ultimoErroWa || 'sem resposta') + ' (a instância está pareada em bot-admin?)');
  }
  if (temTelegram()) {
    let ok = false; try { ok = await telegram(texto); } catch (e) { falhas.push('Telegram: ' + e.message); }
    if (ok) return { canal: 'telegram', ok: true, dica: falhas.length ? falhas[0] + ' — foi pelo Telegram' : 'enviado pelo bot dos alertas' };
    if (!falhas.some(f => f.startsWith('Telegram'))) falhas.push('Telegram: sem chat id — mande /start pro bot dos alertas');
  }
  const ok = arquivo(codigo);
  const prefixo = falhas.length ? falhas.join(' · ') + ' — ' : '';
  return { canal: 'arquivo', ok, dica: ok ? prefixo + 'o código está na VPS: motobase codigo' : prefixo + 'e não consegui gravar o código na VPS (a pasta da porta está montada?)' };
}

// avisos de segurança (senha errada 3×, código errado 3×) — melhor esforço, nunca falha
async function avisar(texto) {
  try {
    if (temWhatsapp()) return await whatsapp(texto);
    if (temTelegram()) return await telegram(texto);
  } catch (e) {}
  return false;
}

module.exports = { canal, enviarCodigo, avisar, ARQUIVO };
