'use strict';
// ── 2FA do modo MASTER — o MESMO cofre do porta/auth.py, lido e gravado daqui ──
// scrypt idêntico ao Python (n=16384, r=8, p=1, dklen=32, salt hex por senha),
// então `motobase senha` no host e o chat no container enxergam a mesma senha.
// Cofre: <PORTA_BASE>/auth.json (0600). NUNCA senha em texto; o código de 4
// dígitos também vai hasheado, vive 5 min e some depois de usado.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const BASE = process.env.PORTA_BASE || '/opt/porta';
const AUTH = path.join(BASE, 'auth.json');
const SENHA_TENT_MAX = 3;
const OTP_TENT_MAX = 3;
const LOCK_SEG = 15 * 60;
const OTP_TTL = 5 * 60;
const MASTER_TTL = 3 * 60 * 60;

const agora = () => Date.now() / 1000;   // segundos (float), igual ao time.time() do Python

function ler() {
  try { return JSON.parse(fs.readFileSync(AUTH, 'utf8')); } catch (e) { return {}; }
}
function grava(d) {
  const tmp = AUTH + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(d), { mode: 0o600 });
  try { fs.chmodSync(tmp, 0o600); } catch (e) {}
  fs.renameSync(tmp, AUTH);
}
function hash(plain, saltHex) {
  return crypto.scryptSync(Buffer.from(String(plain), 'utf8'), Buffer.from(saltHex, 'hex'), 32,
    { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }).toString('hex');
}
function iguais(a, b) {
  const x = Buffer.from(a, 'hex'), y = Buffer.from(b, 'hex');
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function definirSenha(plain) {
  const d = ler();
  const salt = crypto.randomBytes(16).toString('hex');
  d.senha = { salt, hash: hash(plain, salt), em: Math.floor(agora()) };
  d.falhas = 0; d.lock_ate = 0;
  grava(d);
}
function temSenha() { return !!ler().senha; }
function bloqueado() { return Math.max(0, Math.floor((ler().lock_ate || 0) - agora())); }

function checaSenha(plain) {
  const d = ler(); const s = d.senha;
  if (!s) return false;
  const ok = iguais(hash(plain, s.salt), s.hash);
  if (ok) d.falhas = 0;
  else {
    d.falhas = (d.falhas | 0) + 1;
    if (d.falhas >= SENHA_TENT_MAX) { d.lock_ate = agora() + LOCK_SEG; d.falhas = 0; }
  }
  grava(d);
  return ok;
}

function geraOtp() {
  const code = String(crypto.randomInt(0, 10000)).padStart(4, '0');
  const d = ler();
  const salt = crypto.randomBytes(8).toString('hex');
  d.otp = { salt, hash: hash(code, salt), exp: agora() + OTP_TTL, tent: 0 };
  grava(d);
  return code;
}
function checaOtp(code) {
  const d = ler(); const o = d.otp;
  if (!o) return 'expirado';
  if (agora() > (o.exp || 0)) { delete d.otp; grava(d); return 'expirado'; }
  if (iguais(hash(String(code).trim(), o.salt), o.hash)) { delete d.otp; d.falhas = 0; grava(d); return 'ok'; }
  o.tent = (o.tent | 0) + 1;
  if (o.tent >= OTP_TENT_MAX) { delete d.otp; d.lock_ate = agora() + LOCK_SEG; grava(d); return 'travado'; }
  grava(d);
  return 'errado';
}

module.exports = { definirSenha, temSenha, bloqueado, checaSenha, geraOtp, checaOtp, OTP_TTL, MASTER_TTL, LOCK_SEG, AUTH };
