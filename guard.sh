#!/usr/bin/env bash
# =============================================================================
#  🛡️ MOTOBASE GUARD — Módulo Blindagem
#
#  bash <(curl -fsSL https://get.motobot.com.br/guard)
#
#  O que servidor NENHUM deveria viver sem:
#   1. Firewall (só 22/80/443)          4. Atualizações de segurança automáticas
#   2. SSH endurecido (só chave)        5. BACKUP DIÁRIO → Cloudflare R2
#   3. fail2ban (bane força-bruta)      6. AUTO-COMMIT → GitHub privado (código offsite)
#   +  Swap (contra OOM)
#
#  Regra de ouro: backup que nunca foi RESTAURADO é esperança, não backup.
#  Por Rafael Ventura (github.com/rafzinn) × Fable 5.
# =============================================================================
set -euo pipefail

C0='\033[0m'; DIM='\033[2m'; BOLD='\033[1m'
RED='\033[38;5;203m'; AMB='\033[38;5;179m'; GRN='\033[38;5;108m'; CRM='\033[38;5;230m'
say(){ echo -e "$*"; }
ok(){ say "  ${GRN}✓${C0} $*"; }
info(){ say "  ${DIM}├─${C0} $*"; }
warn(){ say "  ${AMB}⚠${C0} $*"; }
die(){ say "\n  ${RED}✗ $*${C0}\n"; exit 1; }
ask(){ local __v=$1 __p=$2 __d=${3:-}; local r; read -rp "$(echo -e "  ${AMB}?${C0} ${__p}${__d:+ ${DIM}[$__d]${C0}}: ")" r; printf -v "$__v" '%s' "${r:-$__d}"; }
asktoken(){ local __v=$1 __p=$2; local r; read -rp "$(echo -e "  ${AMB}?${C0} ${__p} ${DIM}(cole aqui)${C0}: ")" r; printf -v "$__v" '%s' "$r"; }
read_masked(){ # $1=prompt; resultado em REPLY
  local prompt="$1" char value=""
  printf '%b' "  ${AMB}?${C0} ${prompt} ${DIM}(cole aqui)${C0}: " >&2
  while IFS= read -r -s -n 1 char; do
    [[ -z "$char" ]] && break
    case "$char" in
      $'\177'|$'\b') [[ -n "$value" ]] && { value="${value%?}"; printf '\b \b' >&2; } ;;
      *) value+="$char"; printf '*' >&2 ;;
    esac
  done
  printf '\n' >&2
  REPLY="$value"
}
asksecret(){ local __v=$1 __p=$2; read_masked "$__p"; printf -v "$__v" '%s' "$REPLY"; }

say ""
say "  ${RED}🛡️  ${BOLD}${CRM}MOTOBASE GUARD${C0} ${DIM}— módulo blindagem${C0}"
say ""
[[ $EUID -eq 0 ]] || die "Rode como root (sudo -i antes)."
command -v apt-get >/dev/null || die "Suporta Ubuntu/Debian (apt)."

# ── 1. Firewall ──────────────────────────────────────────────────────────────
say "${BOLD}[1/6] Firewall (UFW)${C0}"
apt-get install -y -qq ufw >/dev/null 2>&1 || true
ufw allow 22/tcp   >/dev/null
ufw allow 80/tcp   >/dev/null
ufw allow 443/tcp  >/dev/null
ufw --force enable >/dev/null
ok "Só as portas 22 (SSH), 80 e 443 (web) abertas. O resto: porta na cara."

# ── 2. SSH endurecido ────────────────────────────────────────────────────────
say "\n${BOLD}[2/6] SSH endurecido${C0}"
if [[ -s /root/.ssh/authorized_keys ]]; then
  ask HARD "Você já entra com CHAVE SSH. Desligar login por senha? (s/n)" "s"
  if [[ "$HARD" =~ ^[sS] ]]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    ok "Login por senha DESLIGADO — só quem tem a chave entra."
  else
    warn "Mantido login por senha (menos seguro)."
  fi
else
  warn "Nenhuma chave SSH em /root/.ssh/authorized_keys — NÃO desliguei a senha"
  warn "(senão você ficaria trancado pra fora). Configure uma chave e rode de novo."
fi

# ── 3. fail2ban ──────────────────────────────────────────────────────────────
say "\n${BOLD}[3/6] fail2ban${C0}"
apt-get install -y -qq fail2ban >/dev/null 2>&1
systemctl enable --now fail2ban >/dev/null 2>&1
ok "Robôs tentando adivinhar sua senha agora são banidos sozinhos."

# ── 4. Updates automáticos + swap ────────────────────────────────────────────
say "\n${BOLD}[4/6] Atualizações de segurança + swap${C0}"
apt-get install -y -qq unattended-upgrades >/dev/null 2>&1
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
ok "Patches de segurança do sistema se instalam sozinhos."
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
  ok "Swap de 2G criado — pico de memória não derruba mais o servidor."
else
  ok "Swap já existe."
fi

# ── 5. BACKUP DIÁRIO → Cloudflare R2 ────────────────────────────────────────
say "\n${BOLD}[5/6] Backup diário → Cloudflare R2${C0}"
say ""
say "  ${AMB}IMPORTANTE:${C0} o token de DNS usado na instalação-base ${BOLD}não funciona no R2${C0}."
say "  O R2 gera um ${BOLD}Access Key ID${C0} e um ${BOLD}Secret Access Key${C0} próprios para S3."
say ""
say "  1. Abra: ${BOLD}https://dash.cloudflare.com/?to=/:account/r2/overview${C0}"
say "  2. Ative o R2 e clique em ${BOLD}Create bucket${C0} → nome sugerido: ${BOLD}backups${C0}."
say "  3. Em Account Details, clique ${BOLD}Manage${C0} ao lado de API Tokens."
say "  4. ${BOLD}Create Account API token${C0} → Object Read & Write → apenas o bucket backups."
say "  5. Copie o Access Key ID, Secret Access Key e endpoint S3. O segredo só aparece uma vez."
say "  Guia oficial: ${BOLD}https://developers.cloudflare.com/r2/get-started/s3/${C0}"
say ""
ask WANTBK "Configurar o backup agora? (s/n)" "s"
if [[ "$WANTBK" =~ ^[sS] ]]; then
  asksecret R2_ENDPOINT "Endpoint S3 do R2 (oculto na gravação)"
  ask R2_BUCKET "Nome do bucket" "backups"
  asksecret R2_KEY "Access Key ID (não aparece ao digitar)"
  asksecret R2_SECRET "Secret Access Key (não aparece ao digitar)"
  apt-get install -y -qq awscli >/dev/null 2>&1 || pip3 install -q awscli 2>/dev/null || die "Não consegui instalar aws-cli."
  mkdir -p /opt/motobase-guard
  cat > /opt/motobase-guard/r2.env <<EOF
AWS_ACCESS_KEY_ID=${R2_KEY}
AWS_SECRET_ACCESS_KEY=${R2_SECRET}
AWS_DEFAULT_REGION=auto
R2_ENDPOINT=${R2_ENDPOINT}
R2_BUCKET=${R2_BUCKET}
EOF
  chmod 600 /opt/motobase-guard/r2.env

  cat > /opt/motobase-guard/backup.sh <<'EOS'
#!/usr/bin/env bash
# Espelha para o R2 os backups reais gerados pela Motobase em /var/backups.
set -euo pipefail
source /opt/motobase-guard/r2.env
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
S3="aws s3 --endpoint-url=${R2_ENDPOINT}"
log(){ echo "[$(date '+%F %T')] $*"; }

# Os jobs locais rodam até 03:25. Este upload começa às 04:00 e envia arquivos
# novos sem apagar do R2 quando a retenção local de 14 dias os remover.
[[ -d /var/backups ]] || { log "diretório /var/backups não existe"; exit 1; }
sent=$(find /var/backups -type f \( -name '*.sql.gz' -o -name '*.tar.gz' \) | wc -l)
if [[ $sent -gt 0 ]]; then
  $S3 sync /var/backups "s3://${R2_BUCKET}/motobase/" \
    --exclude '*' --include '*.sql.gz' --include '*.tar.gz' --only-show-errors
else
  log "nenhum backup local encontrado para enviar"
fi

# Retenção remota de 30 dias baseada na data de envio do objeto.
CUT=$(date -d '30 days ago' '+%Y-%m-%d')
$S3 ls "s3://${R2_BUCKET}/motobase/" --recursive 2>/dev/null | while read -r d _ _ k; do
  [[ "$d" < "$CUT" ]] && $S3 rm "s3://${R2_BUCKET}/$k" >/dev/null 2>&1
done
log "backup externo concluído (${sent} arquivo(s) verificados)"
EOS
  chmod +x /opt/motobase-guard/backup.sh
  ( crontab -l 2>/dev/null | grep -v motobase-guard/backup ; echo "0 4 * * * /opt/motobase-guard/backup.sh >> /var/log/motobase-backup.log 2>&1" ) | crontab -
  info "testando: subindo um arquivo de teste pro R2…"
  set +e
  source /opt/motobase-guard/r2.env; export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  echo "motobase guard $(date)" > /tmp/mb-test.txt
  aws s3 --endpoint-url="$R2_ENDPOINT" cp /tmp/mb-test.txt "s3://${R2_BUCKET}/teste-conexao.txt" >/dev/null 2>&1
  TESTOK=$?
  [[ $TESTOK -eq 0 ]] && aws s3 --endpoint-url="$R2_ENDPOINT" rm "s3://${R2_BUCKET}/teste-conexao.txt" >/dev/null 2>&1 || true
  rm -f /tmp/mb-test.txt
  set -e
  if [[ $TESTOK -eq 0 ]]; then ok "Backup configurado E TESTADO — todo dia às 04:00, retenção de 30 dias."
  else warn "Upload de teste falhou — confira endpoint/chaves e rode: /opt/motobase-guard/backup.sh"; fi
  say "  ${DIM}Lição da casa: 1x por mês, BAIXE um backup e restaure num container"
  say "  descartável. Backup que nunca restaurou é esperança, não backup.${C0}"
else
  warn "Backup pulado — seu servidor segue com memória de peixe. Rode de novo quando quiser."
fi

# ── 6. AUTO-COMMIT → GitHub privado ──────────────────────────────────────────
say "\n${BOLD}[6/6] Código com cópia externa (GitHub privado, auto-commit)${C0}"
say ""
say "  ${DIM}Servidor morre. Disco morre. Código sem cópia externa morre junto.${C0}"
say ""
ask WANTGH "Configurar auto-commit do seu código pro GitHub? (s/n)" "s"
if [[ "$WANTGH" =~ ^[sS] ]]; then
  ask GH_USER "Seu usuário do GitHub"
  ask GH_AUTHOR "Nome de quem opera este servidor (aparece nos commits)" "$GH_USER"
  say "  ${DIM}Token: https://github.com/settings/personal-access-tokens/new"
  say "  GitHub → Settings → Developer settings → Fine-grained tokens"
  say "  → Generate: All repositories + Contents (RW) + Administration (RW)${C0}"
  asktoken GH_TOKEN "Cole o token"
  ask GH_DIR "Qual pasta versionar?" "/opt/projetos"
  ask GH_REPO "Nome do repositório privado" "meu-servidor"

  git config --global user.name  "$GH_AUTHOR"
  git config --global user.email "${GH_USER}@users.noreply.github.com"
  git config --global credential.helper store
  printf 'https://%s:%s@github.com\n' "$GH_USER" "$GH_TOKEN" > /root/.git-credentials
  chmod 600 /root/.git-credentials

  # cria o repo privado (idempotente: 422 se já existe)
  curl -s -X POST https://api.github.com/user/repos \
    -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"${GH_REPO}\",\"private\":true,\"description\":\"Backup automático do meu servidor (motobase guard)\"}" >/dev/null

  cd "$GH_DIR"
  [[ -d .git ]] || git init -q
  printf '*.log\n.env\n**/.env\n*credenciais*\n' > .gitignore
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/${GH_USER}/${GH_REPO}.git"
  git add -A && git commit -q -m "guard: baseline $(date '+%F %H:%M')" 2>/dev/null || true
  git branch -M main
  git push -q -u origin main 2>/dev/null && ok "Primeiro push feito: github.com/${GH_USER}/${GH_REPO} (privado)" \
    || warn "Push falhou — confere o token e rode: cd $GH_DIR && git push -u origin main"

  cat > /opt/motobase-guard/autocommit.sh <<EOS
#!/usr/bin/env bash
# Auto-commit com identificação: registra QUEM estava logado quando a mudança entrou.
cd "${GH_DIR}" || exit 0
git add -A
git diff --cached --quiet && exit 0
WHO=\$(who | awk '{print \$1"@"\$NF}' | sort -u | paste -sd' + ' - | tr -d '()')
git commit -q -m "auto: \$(date '+%F %H:%M') — por: \${WHO:-${GH_AUTHOR} (sem sessão ativa)}"
git push -q
EOS
  chmod +x /opt/motobase-guard/autocommit.sh
  ( crontab -l 2>/dev/null | grep -v motobase-guard/autocommit ; echo "*/30 * * * * /opt/motobase-guard/autocommit.sh >/dev/null 2>&1" ) | crontab -
  ok "Auto-commit a cada 30min, assinado: cada commit registra quem estava logado (usuário@IP)."
else
  warn "Auto-commit pulado."
fi

say "\n${GRN}${BOLD}════════════ SERVIDOR BLINDADO ════════════${C0}"
say ""
say "  ${BOLD}O que está de guarda agora:${C0}"
say "  🔥 Firewall fechado  ·  🔑 SSH duro  ·  🚫 fail2ban  ·  ♻ updates auto"
say "  💾 Backup diário no R2  ·  🐙 Código no GitHub  ·  🧠 Swap anti-OOM"
say ""
say "  ${DIM}O que NENHUM script faz por você: testar o restore. Marque no"
say "  calendário: 1x por mês, baixe e restaure. É o hábito que separa"
say "  quem tem backup de quem tem esperança.${C0}"
say ""
say "  🦀 ${DIM}github.com/rafzinn/motobase${C0}"
say ""
