#!/usr/bin/env python3
# =========================================================================
# auth.py — 2FA do modo MASTER da porta (mesmo desenho da porta em produção)
#
# Abrir a janela master pede DUAS provas em canais DIFERENTES:
#   1. senha mestra   (algo que o dono SABE, digitada no chat)
#   2. código de 4    (algo que o dono RECEBE: WhatsApp, Telegram ou arquivo na VPS)
#
# Aqui mora só a criptografia e o estado. O chat (Node) lê e grava o MESMO
# cofre com scrypt idêntico (n=16384 r=8 p=1 dklen=32); quem obedece o modo
# é o porta.py (estado.json → total_ate).
#
# Guardado em <PORTA_BASE>/auth.json (0600, root): NUNCA a senha em texto —
# scrypt com salt por senha. O código de 4 dígitos também vai hasheado: ele
# vive 5 minutos e some depois de usado.
# =========================================================================
import hashlib
import hmac
import json
import os
import secrets
import time

AUTH = os.path.join(os.environ.get('PORTA_BASE', '/opt/porta'), 'auth.json')

SENHA_TENT_MAX = 3          # senhas erradas antes de travar
OTP_TENT_MAX = 3            # códigos errados antes de travar
LOCK_SEG = 15 * 60          # castigo depois de estourar as tentativas
OTP_TTL = 5 * 60            # o código vale 5 min
MASTER_TTL = 3 * 60 * 60    # a janela liberada dura 3 h


def _ler():
    try:
        with open(AUTH, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def _grava(d):
    # escrita atômica: um crash no meio não pode deixar o cofre pela metade
    tmp = AUTH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, AUTH)


def _hash(plain, salt_hex):
    return hashlib.scrypt(plain.encode('utf-8'), salt=bytes.fromhex(salt_hex),
                          n=16384, r=8, p=1, dklen=32).hex()


# ─── senha mestra ──────────────────────────────────────────────────────────
def definir_senha(plain):
    d = _ler()
    salt = secrets.token_hex(16)
    d['senha'] = {'salt': salt, 'hash': _hash(plain, salt), 'em': int(time.time())}
    d['falhas'] = 0
    d['lock_ate'] = 0
    _grava(d)


def tem_senha():
    return bool(_ler().get('senha'))


def bloqueado():
    """Segundos que faltam do castigo (0 = liberado pra tentar)."""
    return max(0, int(_ler().get('lock_ate', 0) - time.time()))


def checa_senha(plain):
    d = _ler()
    s = d.get('senha')
    if not s:
        return False
    ok = hmac.compare_digest(_hash(plain, s['salt']), s['hash'])
    if ok:
        d['falhas'] = 0
    else:
        d['falhas'] = int(d.get('falhas', 0)) + 1
        if d['falhas'] >= SENHA_TENT_MAX:
            d['lock_ate'] = time.time() + LOCK_SEG
            d['falhas'] = 0
    _grava(d)
    return ok


# ─── código de 4 dígitos ───────────────────────────────────────────────────
def gera_otp():
    """Sorteia, guarda o hash e devolve o código em claro — quem chama manda
    pro canal e esquece. `secrets`, não `random`: previsível aqui é furo."""
    code = '%04d' % secrets.randbelow(10000)
    d = _ler()
    salt = secrets.token_hex(8)
    d['otp'] = {'salt': salt, 'hash': _hash(code, salt),
                'exp': time.time() + OTP_TTL, 'tent': 0}
    _grava(d)
    return code


def checa_otp(code):
    """Devolve: ok | errado | expirado | travado."""
    d = _ler()
    o = d.get('otp')
    if not o:
        return 'expirado'
    if time.time() > o.get('exp', 0):
        d.pop('otp', None)
        _grava(d)
        return 'expirado'
    if hmac.compare_digest(_hash(str(code).strip(), o['salt']), o['hash']):
        d.pop('otp', None)
        d['falhas'] = 0
        _grava(d)
        return 'ok'
    o['tent'] = int(o.get('tent', 0)) + 1
    if o['tent'] >= OTP_TENT_MAX:
        d.pop('otp', None)
        d['lock_ate'] = time.time() + LOCK_SEG
        _grava(d)
        return 'travado'
    _grava(d)
    return 'errado'
