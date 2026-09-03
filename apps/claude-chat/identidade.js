'use strict';
// ── Quem está falando? Identidade pela TAILNET, sem tela de login ─────────────
// O chat só é alcançável pela tailnet (middleware do Traefik). O Traefik roda em
// portas host-mode, então X-Real-Ip é o IP tailnet real de quem conectou. A
// LocalAPI do tailscaled (socket unix, montado no container) diz de quem é esse
// IP: login (e-mail da conta Tailscale), nome e dispositivo. Nada de senha,
// nada de cookie — a identidade é a mesma que o Tailscale já provou.
//
// Sem o socket (instalação antiga, tailscale em container): todo mundo vira
// "tailnet" (anônimo compartilhado), como o chat era antes.
const fs = require('fs');
const http = require('http');

const SOCK = process.env.TAILSCALE_SOCK || '/var/run/tailscale/tailscaled.sock';
const OWNER_ENV = (process.env.OWNER_LOGIN || '').trim().toLowerCase();
const CACHE_MS = 60 * 1000;
const cache = new Map();          // ip → { t, dados }
const motivos = new Map();        // ip → por que o whois falhou (diagnóstico em /api/me)
let donoCache = { t: 0, login: '' };

function disponivel() { try { return fs.existsSync(SOCK); } catch (e) { return false; } }

function localapi(p) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      socketPath: SOCK, path: p, method: 'GET', timeout: 3000,
      headers: { Host: 'local-tailscaled.sock', 'Sec-Tailscale': 'localapi' }
    }, (r) => { let b = ''; r.on('data', c => { b += c; }); r.on('end', () => resolve({ status: r.statusCode, body: b })); });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.end();
  });
}

function clientIp(req) {
  let ip = (req.headers['x-real-ip'] || '').trim()
    || ((req.headers['x-forwarded-for'] || '').split(',')[0] || '').trim()
    || (req.socket && req.socket.remoteAddress) || '';
  if (ip.startsWith('::ffff:')) ip = ip.slice(7);
  return ip;
}

async function whois(ip) {
  if (!ip || !disponivel()) return null;
  const c = cache.get(ip);
  if (c && Date.now() - c.t < CACHE_MS) return c.dados;
  let dados = null, motivo = '';
  try {
    const addr = ip.includes(':') ? `[${ip}]:1` : `${ip}:1`;
    const r = await localapi('/localapi/v0/whois?addr=' + encodeURIComponent(addr));
    if (r.status === 200) {
      const j = JSON.parse(r.body);
      const u = j.UserProfile || {}; const n = j.Node || {};
      if (u.LoginName) dados = { login: String(u.LoginName).toLowerCase(), nome: u.DisplayName || u.LoginName, node: n.ComputedName || n.Name || '' };
      else motivo = 'whois sem LoginName';
    } else motivo = `whois HTTP ${r.status}: ${String(r.body).slice(0, 80)}`;
  } catch (e) { dados = null; motivo = 'socket do tailscale: ' + e.message; }
  if (!dados) { motivos.set(ip, motivo); console.warn(`[chat] identidade falhou para ${ip}: ${motivo}`); } else motivos.delete(ip);
  cache.set(ip, { t: Date.now(), dados });
  return dados;
}

// dono = a conta Tailscale que autenticou ESTA VPS (Self.UserID no status). Pode
// ser fixado por env (OWNER_LOGIN) — o instalador grava o que viu no tailscale.
async function dono() {
  if (OWNER_ENV) return OWNER_ENV;
  if (Date.now() - donoCache.t < 5 * 60 * 1000 && donoCache.login) return donoCache.login;
  try {
    const r = await localapi('/localapi/v0/status');
    if (r.status === 200) {
      const j = JSON.parse(r.body);
      const uid = j.Self && j.Self.UserID; const u = uid && j.User && j.User[String(uid)];
      if (u && u.LoginName) { donoCache = { t: Date.now(), login: String(u.LoginName).toLowerCase() }; return donoCache.login; }
    }
  } catch (e) {}
  return donoCache.login || '';
}

async function identificar(req) {
  const ip = clientIp(req);
  const w = await whois(ip);
  const d = await dono();
  if (w) return { ip, login: w.login, nome: w.nome, node: w.node, identidade: 'tailscale', dono: !!d && w.login === d };
  // sem identidade: todo mundo é "tailnet". Só é dono se o instalador NÃO fixou um
  // dono (senão qualquer anônimo viraria dono) — e mesmo assim o master exige 2FA.
  const motivo = !disponivel() ? 'socket do tailscale não montado no container' : (motivos.get(ip) || (ip ? 'IP fora da tailnet' : 'sem IP do cliente'));
  return { ip, login: 'tailnet', nome: 'tailnet', node: '', identidade: 'anonimo', dono: !d, motivo, dono_esperado: d || '' };
}

module.exports = { identificar, disponivel, clientIp, whois, dono };
