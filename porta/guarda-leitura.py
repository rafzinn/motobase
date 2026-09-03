#!/usr/bin/env python3
# =========================================================================
# guarda-leitura.py — hook PreToolUse do modo LEITURA da porta
#
# O buraco que ele fecha: sem a janela master, só negar Write/Edit não basta.
# A porta libera `Bash` (no headless não existe diálogo de permissão), então
# sem este guarda qualquer pessoa da tailnet alteraria a VPS pelo shell —
# `echo x > arquivo` já bastava. Sem 2FA, o Claude da porta responde e lê;
# escrever, apagar, subir serviço ou dar deploy exige o modo master.
#
# Contrato do hook: recebe o JSON da chamada no stdin; sair com código 2
# NEGA a ferramenta e devolve o stderr como motivo pro modelo.
#
# LIMITE HONESTO: isto é lista negra sobre linha de shell — cobre o descuido
# e o oportunista, não um atacante determinado com criatividade (encoding,
# alias, binário exótico). A trava dura de verdade seria proibir Bash inteiro
# fora da janela master; a escolha foi manter leitura ampla (consultar banco
# e logs é metade do valor do chat).
# =========================================================================
import json
import re
import sys
import time

LOG = '/var/log/porta-guarda.log'

# Subcomandos que só LEEM — o resto do verbo é barrado por padrão.
# `exec` entra na lista: consultar banco e diagnosticar por dentro do
# container é metade do valor. O que roda LÁ DENTRO continua passando por
# todas as regras abaixo, porque a análise é sobre a linha inteira.
DOCKER_OK = {'ps', 'images', 'logs', 'inspect', 'stats', 'version', 'info', 'top', 'port', 'diff', 'exec'}
DOCKER_SUB_OK = {'service': {'ls', 'ps', 'inspect', 'logs'},
                 'stack': {'ls', 'ps', 'services'},
                 'node': {'ls', 'inspect'},
                 'secret': {'ls', 'inspect'},
                 'config': {'ls', 'inspect'},
                 'volume': {'ls', 'inspect'},
                 'network': {'ls', 'inspect'},
                 'system': {'df', 'info', 'events'}}
GIT_OK = {'status', 'log', 'diff', 'show', 'branch', 'remote', 'ls-files',
          'describe', 'rev-parse', 'blame', 'shortlog', 'tag'}
SYSTEMCTL_OK = {'status', 'is-active', 'is-enabled', 'show', 'cat', 'list-units',
                'list-unit-files', 'list-timers'}

REGRAS = [
    (r'(?<![0-9&])>>?', 'redirecionamento grava arquivo'),
    (r'\|\s*(tee|sponge)\b', 'tee/sponge grava arquivo'),
    # os delimitadores incluem aspas: `bash -c 'rm x'` tem que cair aqui também
    (r'(?:^|[;&|(\'"]\s*)(rm|rmdir|shred|mv|cp|dd|truncate|install|ln|mkdir|touch|mkfs|'
     r'chmod|chown|chgrp|setfacl|patch|unzip|tar|rsync)\b', 'comando que altera arquivo'),
    (r'\b(reboot|shutdown|halt|poweroff|init\s+[06]|kill|pkill|killall|'
     r'mount|umount|iptables|ufw|netplan|useradd|userdel|passwd|visudo|crontab)\b',
     'comando que mexe na máquina'),
    (r'\bsed\b[^;|&]*\s-i', 'sed -i edita no lugar'),
    (r'\b(perl|ruby)\b[^;|&]*\s-i', 'edição no lugar'),
    (r'\b(apt|apt-get|dpkg|snap|npm|npx|pnpm|yarn|pip|pip3)\b[^;|&]*\b'
     r'(install|remove|uninstall|purge|upgrade|update|add|link|publish)\b', 'gerenciador de pacote'),
    # nome de tabela vem com schema e aspas: app.clientes, "public"."x"
    (r'\b(insert\s+into|update\s+[\w."\']+\s+set|delete\s+from|drop\s+(table|schema|database|index|role)|'
     r'alter\s+(table|schema|system|role|database)|truncate\s+table|grant\s+|revoke\s+|'
     r'create\s+(table|schema|database|role|user|index|publication|extension))\b', 'SQL de escrita'),
    (r'\b(python3?|node|perl|ruby)\b[^;|&]*\s-[ce]\b[^;|&]*'
     r'(open\s*\([^)]*[\'"][wax]|\.write|writeFile|appendFile|os\.(remove|unlink|rename|system|makedirs)|'
     r'shutil\.|subprocess|child_process|execSync|fs\.(rm|unlink|mkdir))', 'interpretador gravando'),
    (r'\b(curl|wget)\b[^;|&]*(-X\s*(POST|PUT|PATCH|DELETE)|--data|--upload-file|\s-d\s|\s-[oO]\s)',
     'requisição de escrita ou download'),
    (r'\bgit\s+(push|commit|add|reset|checkout|switch|clean|rebase|merge|revert|stash|am|apply|config)\b',
     'git que altera repositório'),
    # script tem conteúdo opaco: `bash deploy.sh` não mostra o que vai fazer.
    # Comando inline (python3 -c "print(...)") continua liberado logo acima.
    (r'(?:^|[;&|(]\s*)(?:sudo\s+)?(bash|sh|zsh|python3?|node|perl|ruby)\s+[^\s-]\S*\.(sh|py|js|pl|rb)\b',
     'execução de script (conteúdo opaco)'),
    (r'(?:^|[;&|(]\s*)\./\S+', 'execução de script local'),
]


def veredito(cmd, nivel=0):
    """Devolve o motivo da recusa, ou None se o comando pode passar."""
    # `docker exec <container> <comando>` é um comando dentro de outro: o que
    # roda lá dentro precisa passar pelas mesmas regras, senão `docker exec api
    # rm -rf /app` entrava como se fosse leitura.
    if nivel < 2:
        m = re.search(r'\bdocker\s+exec\s+((?:-\S+\s+)*)(\S+)\s+(.+)$', cmd, re.IGNORECASE)
        if m:
            dentro = veredito(m.group(3).strip(), nivel + 1)
            if dentro:
                return f'dentro do container: {dentro}'
    # tira do texto o que é redirecionamento inofensivo, senão a 1ª regra
    # barraria qualquer `2>&1` ou `>/dev/null` de um comando de leitura
    limpo = re.sub(r'2>&1|>&2|&?>\s*/dev/null', ' ', cmd)

    for padrao, motivo in REGRAS:
        if re.search(padrao, limpo, re.IGNORECASE):
            return motivo

    # docker/git/systemctl: allowlist de verbo, porque o mesmo binário lê e destrói
    for m in re.finditer(r'\bdocker\s+([a-z-]+)(?:\s+([a-z-]+))?', limpo, re.IGNORECASE):
        verbo, sub = m.group(1).lower(), (m.group(2) or '').lower()
        if verbo in DOCKER_SUB_OK:
            if sub not in DOCKER_SUB_OK[verbo]:
                return f'docker {verbo} {sub} altera a stack'
        elif verbo not in DOCKER_OK:
            return f'docker {verbo} não é comando de leitura'
    # pula as flags globais (`git -C /opt/app status`) antes de ler o verbo
    for m in re.finditer(r'\bgit\s+(?:-\S+\s+\S+\s+|--\S+\s+)*([a-z][a-z-]*)', limpo, re.IGNORECASE):
        if m.group(1).lower() not in GIT_OK:
            return f'git {m.group(1)} não é comando de leitura'
    for m in re.finditer(r'\bsystemctl\s+([a-z-]+)', limpo, re.IGNORECASE):
        if m.group(1).lower() not in SYSTEMCTL_OK:
            return f'systemctl {m.group(1)} mexe em serviço'
    return None


def main():
    try:
        ev = json.load(sys.stdin)
    except Exception:
        sys.exit(0)                      # sem payload legível: não é hora de adivinhar
    if ev.get('tool_name') != 'Bash':
        sys.exit(0)
    cmd = (ev.get('tool_input') or {}).get('command') or ''
    motivo = veredito(cmd)
    if not motivo:
        sys.exit(0)
    try:
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(f'{time.strftime("%Y-%m-%d %H:%M:%S")} NEGADO ({motivo}): {cmd[:300]}\n')
    except Exception:
        pass
    sys.stderr.write(
        f'Negado pelo modo leitura da porta: {motivo}. Sem o modo master a porta só lê. '
        'Diga ao dono o que faria e peça pra ele clicar em "Liberar master" no chat '
        '(senha mestra + código de 4 dígitos) — a janela dura 3 horas.\n')
    sys.exit(2)


if __name__ == '__main__':
    main()
