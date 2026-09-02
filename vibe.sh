#!/usr/bin/env bash
# =============================================================================
#  ⚡ VIBE STACK — sua startup enxuta, em uma linha
#
#  bash <(curl -fsSL https://get.motobot.com.br/vibe)
#
#  Questionário único no início (com links de onde pegar cada credencial e
#  validação de formato) → o resto roda sozinho → prova real no final:
#    Docker Swarm → Traefik (HTTPS automático) → Postgres+pgvector → Redis
#    → Tailscale + Portainer + Beszel só-tailnet (gestão) → Claude Code autenticado
#    com CLAUDE.md da infra → moltbot (opcional) → backup diário.
#  As stacks nascem CRUAS: banco sem tabelas, produto do zero — você comanda.
#  Senhas fortes geradas na hora, guardadas como Docker secrets.
#
#  Uso avançado: --seed <nome>  aplica uma semente de projeto (DDL + CLAUDE.md
#  de seeds/<nome>/ no repo) por cima da base. --dry-run não toca o disco.
#  Rodar de novo é seguro: o que já existe é reaproveitado.
#
#  Por Rafael Ventura (github.com/rafzinn) × Fable 5.
# =============================================================================
set -euo pipefail
set -E

# ── blindagem de execução ────────────────────────────────────────────────────
# Servidor não tem quem responda diálogo: qualquer pergunta do apt (needrestart,
# debconf, "arquivo de configuração alterado") trava a instalação EM SILÊNCIO.
# Estas variáveis, mais o conf.d escrito no preflight, eliminam a classe inteira.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none
export UCF_FORCE_CONFOLD=1

# apt que ESPERA o lock em vez de morrer (VPS nova roda unattended-upgrades
# sozinha nos primeiros minutos) e que nunca pergunta sobre config.
APT="apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
# curl que insiste: um blip de DNS/TLS não derruba mais a instalação inteira.
CURL="curl -fsSL --connect-timeout 15 --max-time 300 --retry 4 --retry-delay 3 --retry-connrefused"

# transcrição completa — toda saída de comando é gravada para diagnóstico
LOG="/var/log/motobase-instalacao.log"
RUN_LIMITE_PADRAO=1200
RUN_ROTULO=""
RUN_LIMITE=""

RAW_BASE="https://raw.githubusercontent.com/rafzinn/motobase/main"
LARGURA=70

# ── paleta ───────────────────────────────────────────────────────────────────
C0='\033[0m'; DIM='\033[2m'; BOLD='\033[1m'
RED='\033[38;5;203m'; AMB='\033[38;5;179m'; GRN='\033[38;5;108m'
LRJ='\033[38;5;173m'      # laranja terracota (identidade)
LRJ_CLR='\033[38;5;180m'  # laranja claro (topo do degradê)
LRJ_ESC='\033[38;5;137m'  # laranja sombra (base do degradê)
CHIP='\033[48;5;173m\033[38;5;236m'   # etiqueta: fundo laranja, texto grafite

# ── tipografia do terminal ───────────────────────────────────────────────────
say(){ echo -e "$*"; }
regua(){ local n=${1:-$LARGURA}; printf '─%.0s' $(seq 1 "$n"); }

# confere se um nome DNS resolve pro IP esperado (avisa; propagação leva 1-2 min)
verificar_dns(){
  local nome="$1" alvo="$2" got
  got=$(getent hosts "$nome" 2>/dev/null | awk '{print $1}' | head -1 || true)
  if [[ "$got" == "$alvo" ]]; then ok "DNS ${nome} resolve certo ${DIM}(${alvo})${C0}"
  elif [[ -z "$got" ]]; then info "DNS ${nome} ainda não propagou ${DIM}(normal, 1-2 min)${C0}"
  else warn "DNS ${nome} resolve pra ${got}, esperado ${alvo} ${DIM}(propagando? aguarde e confira)${C0}"; fi
}

# Watchdog de telemetria: checa serviços/disco/memória e se home/chat/bot respondem;
# alerta no Telegram quando algo muda (com diagnóstico via OpenAI, se houver chave).
# Sobe só se o token do Telegram foi informado. É como o instalador nunca "acha"
# que está 100% sem estar — o watchdog vigia depois que ele sai.
instalar_watchdog(){
  ETAPA="watchdog de telemetria"
  [[ -z "${TGTOK:-}" ]] && return 0
  [[ "$DRY" == "--dry-run" ]] && { say "       ${DIM}[dry-run] instalaria o watchdog (timer 5min) + alerta Telegram${C0}"; return 0; }
  info "instalando o watchdog de telemetria (alerta no Telegram)…"
  mkdir -p "${D}/etc/motobase" "${D}/usr/local/sbin"
  {
    printf 'TG_TOKEN=%s\n' "$TGTOK"
    printf 'OPENAI_KEY=%s\n' "${OAKEY:-}"
    printf 'BASE_DOMAIN=%s\n' "${BASE_DOMAIN:-}"
    printf 'SLUG=%s\n' "$SLUG"
    printf 'PROJ_NAME=%s\n' "$PROJ_NAME"
  } > "${D}/etc/motobase/watchdog.env"
  chmod 600 "${D}/etc/motobase/watchdog.env"
  if ! $CURL "${RAW_BASE}/watchdog.sh" -o "${D}/usr/local/sbin/motobase-watchdog.sh" 2>/dev/null; then
    warn "não baixei o watchdog agora — a fundação segue; rode de novo pra tentar"; return 0
  fi
  chmod +x "${D}/usr/local/sbin/motobase-watchdog.sh"
  cat > "${D}/etc/systemd/system/motobase-watchdog.service" <<'UNIT'
[Unit]
Description=Motobase watchdog (telemetria + alerta Telegram)
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/motobase-watchdog.sh
UNIT
  cat > "${D}/etc/systemd/system/motobase-watchdog.timer" <<'UNIT'
[Unit]
Description=Roda o watchdog do Motobase a cada 5 min
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now motobase-watchdog.timer >/dev/null 2>&1 || true
  ok "Watchdog no ar ${DIM}(checa a cada 5 min · alerta no Telegram)${C0}"
  sub "envie ${BOLD}/start${C0} pro seu bot do Telegram UMA vez pra ativar os alertas"
  cred ""; cred "Watchdog: alerta no Telegram (mande /start pro bot uma vez)"
}

# Reconcilia DNS pro IP/TSIP ATUAIS a partir do estado salvo — SEM re-perguntar nada.
# É o conserto de 'troquei de IP' / 'registro velho' sem o aluno tocar no terminal.
reconciliar(){
  [[ $EUID -eq 0 ]] || die "Rode como root: sudo -i"
  [[ -r /etc/motobase/base.env ]] || die "Sem /etc/motobase/base.env — a fundação não terminou. Rode o instalador."
  # shellcheck disable=SC1091
  source /etc/motobase/base.env
  BASE_DOMAIN="${BASE_DOMAIN:-}"; SLUG="${BASE_SLUG:-}"; PROJ_NAME="${BASE_NAME:-$SLUG}"
  CFTOK=""; [[ -r /etc/motobase/cloudflare.token ]] && CFTOK="$(</etc/motobase/cloudflare.token)"
  IP=$(curl -fsS -4 --max-time 8 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  TSIP=$(tailscale ip -4 2>/dev/null | head -1 || true)
  say ""; say "  ${CHIP} RECONCILIAR ${C0} ${DIM}corrige os endereços pro IP atual desta VPS${C0}"; say ""
  ok "IP público ${BOLD}${IP}${C0} · tailnet ${BOLD}${TSIP:-—}${C0}"
  if [[ -z "$CFTOK" ]]; then
    warn "sem token Cloudflare salvo — não dá pra corrigir o DNS automaticamente"
    sub "reinstale com o token, ou ajuste os registros A na mão pro IP acima"
    return 0
  fi
  if [[ -z "$BASE_DOMAIN" ]]; then warn "sem domínio base salvo — nada de DNS a reconciliar"; return 0; fi
  # públicos → IP
  cf_dns_record "${BASE_DOMAIN}" "$IP" "público · home"
  cf_dns_record "www.${BASE_DOMAIN}" "$IP" "público · www"
  docker service inspect wabot_wabot >/dev/null 2>&1 && cf_dns_record "bot.${BASE_DOMAIN}" "$IP" "público · webhook do bot"
  # privados → TSIP
  if [[ -n "$TSIP" ]]; then
    cf_dns_record "portainer.${BASE_DOMAIN}" "$TSIP" "privado · Portainer"
    cf_dns_record "monitor.${BASE_DOMAIN}" "$TSIP" "privado · Beszel"
    docker service inspect chat_chat >/dev/null 2>&1 && cf_dns_record "chat.${BASE_DOMAIN}" "$TSIP" "privado · chat"
    docker service inspect wabot_wabot >/dev/null 2>&1 && cf_dns_record "bot-admin.${BASE_DOMAIN}" "$TSIP" "privado · pareamento do bot"
  fi
  say ""; info "conferindo a resolução (pode levar 1-2 min pra propagar)…"
  verificar_dns "${BASE_DOMAIN}" "$IP"
  [[ -n "$TSIP" ]] && verificar_dns "portainer.${BASE_DOMAIN}" "$TSIP"
  say ""; ok "Reconciliação concluída. Se algo ainda não abrir, aguarde 1-2 min (propagação)."
}

# espera o apt/dpkg liberar (VPS nova roda auto-update no 1º boot)
esperar_apt_livre(){
  command -v fuser >/dev/null 2>&1 || return 0
  local w=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [[ $w -eq 0 ]] && info "aguardando o apt liberar (atualização automática da VPS)…"
    sleep 5; w=$((w+5)); [[ $w -ge 600 ]] && break
  done
}

# ── Portainer: robustez aprendida a duras penas (02/09) ────────────────────
# A porta 9000 é mode:host — SÓ UM container consegue prendê-la. Um zumbi velho
# (de restart repetido) sequestra a porta e o lock do banco: token 403, admin
# "inexistente", reset que não abre o banco. Regra: nunca reiniciar o Portainer
# no fluxo; se precisar refazer, é stack rm + matar SOBRAS + volume limpo.
portainer_limpar(){
  docker stack rm portainer >/dev/null 2>&1 || true
  local w=0   # espera os containers SUMIREM (stack rm remove); teto: nunca trava
  while [[ -n "$(docker ps -a --filter name=portainer -q 2>/dev/null)" && $w -lt 60 ]]; do sleep 2; w=$((w+2)); done
  docker ps -a --filter name=portainer -q 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
  sleep 2
  docker volume rm portainer_pdata >/dev/null 2>&1 || true
  docker secret rm portainer_admin_pw >/dev/null 2>&1 || true
}
# secret com a senha salva (só cria se faltar; após portainer_limpar sempre falta)
portainer_secret_garantir(){
  docker secret inspect portainer_admin_pw >/dev/null 2>&1 \
    || printf '%s' "$1" | docker secret create portainer_admin_pw - >/dev/null 2>&1 || true
}
# PROVA REAL do login: POST /api/auth na 9000 (Portainer oficial, direto). "jwt" = entrou.
portainer_login_ok(){
  local r; r=$(curl -s -m 6 -X POST http://127.0.0.1:9000/api/auth -H 'content-type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"$1\"}" 2>/dev/null || true)
  [[ "$r" == *'"jwt"'* ]]
}
portainer_login_esperar(){ local i; for i in $(seq 1 30); do portainer_login_ok "$1" && return 0; sleep 3; done; return 1; }
# Conecta o Portainer ao Docker (environment 'local' via socket) — o Portainer novo
# NÃO cria sozinho quando o admin vem pronto (--admin-password-file). Idempotente.
portainer_ensure_env(){
  local pw="$1" jwt n i
  jwt=$(curl -s -m 8 -X POST http://127.0.0.1:9000/api/auth -H 'content-type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"$pw\"}" 2>/dev/null | grep -o '"jwt":"[^"]*' | cut -d'"' -f4)
  [[ -z "$jwt" ]] && return 1
  n=$(curl -s -m 6 http://127.0.0.1:9000/api/endpoints -H "Authorization: Bearer $jwt" 2>/dev/null | grep -o '"Id":' | wc -l)
  [[ "$n" -ge 1 ]] && return 0
  curl -s -m 10 -X POST http://127.0.0.1:9000/api/endpoints -H "Authorization: Bearer $jwt" \
    -F "Name=local" -F "EndpointCreationType=1" >/dev/null 2>&1
  for i in 1 2 3 4 5; do
    [[ "$(curl -s -m6 http://127.0.0.1:9000/api/endpoints -H "Authorization: Bearer $jwt" 2>/dev/null | grep -o '"Id":' | wc -l)" -ge 1 ]] && return 0
    sleep 2
  done
  return 1
}

# nível 1 — etapa
etapa(){ # $1=n/total  $2=título  $3=subtítulo (opcional)
  local n="$1" t="$2" s="${3:-}" vis fill
  vis=$(( 2 + 2 + ${#n} + 2 + ${#t} + 1 ))
  fill=$(( LARGURA - vis )); [[ $fill -lt 3 ]] && fill=3
  say ""
  say "  ${CHIP} ${n} ${C0} ${BOLD}${t}${C0} ${DIM}$(regua $fill)${C0}"
  [[ -n "$s" ]] && say "        ${DIM}${s}${C0}" || true
}

# nível 2 — itens da etapa
ok(){   say "     ${GRN}✓${C0} $*"; }
info(){ say "     ${DIM}·${C0} $*"; }
warn(){ say "     ${AMB}▲${C0} $*"; }
# nível 3 — detalhe pendurado no item
sub(){  say "       ${DIM}└ $*${C0}"; }
link(){ say "       ${DIM}└ onde pegar:${C0} ${LRJ}$1${C0}"; }

die(){ say "\n     ${RED}✗ $*${C0}\n"; exit 1; }
# nota: quem chama die() já teve a saída do comando gravada em $LOG
ask(){ local __v=$1 __p=$2 __d=${3:-}; local r
  read -rp "$(echo -e "     ${LRJ}?${C0} ${__p}${__d:+ ${DIM}[$__d]${C0}}: ")" r
  printf -v "$__v" '%s' "${r:-$__d}"; }
# Mantém o segredo fora da tela/gravação, mas dá feedback visual ao digitar ou colar.
# Não usar `read -s` simples: ele aceita o paste, porém parece que nada aconteceu.
read_masked(){ # $1=prompt; resultado em REPLY
  local prompt="$1" char value=""
  printf '%b' "     ${LRJ}?${C0} ${prompt} ${DIM}(cole aqui · Enter pula)${C0}: " >&2
  while IFS= read -r -s -n 1 char; do
    [[ -z "$char" ]] && break
    case "$char" in
      $'\177'|$'\b')
        [[ -n "$value" ]] && { value="${value%?}"; printf '\b \b' >&2; }
        ;;
      *) value+="$char"; printf '*' >&2 ;;
    esac
  done
  printf '\n' >&2
  REPLY="$value"
}
pw(){ openssl rand -base64 18 | tr -d '/+=' | head -c 20; }

swarm_secret(){
  local name="$1" value="$2"
  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] criaria Docker secret ${name}${C0}"
  else
    printf '%s' "$value" | docker secret create "$name" - >/dev/null
  fi
}

# bloco de destaque (avisos que o usuário PRECISA ler) — barra lateral, sem
# borda direita: fechar caixa com texto colorido exigiria contar bytes ANSI
caixa_abre(){ say ""; say "     ${AMB}▛$(regua $((LARGURA-6)))${C0}"; }
caixa_txt(){  say "     ${AMB}▌${C0} $*"; }
caixa_fecha(){ say "     ${AMB}▙$(regua $((LARGURA-6)))${C0}"; say ""; }

# Token fica mascarado com asteriscos; remove espaços acidentais do clipboard
# antes de validar para a colagem não falhar por caractere invisível.
# pergunta token com validação de formato; Enter pula
ask_tok(){ # $1=var $2=pergunta $3=regex $4=exemplo
  local v
  while true; do
    read_masked "$2"
    v="$REPLY"
    v="${v//$'\r'/}"; v="${v//$'\n'/}"; v="${v//$'\t'/}"; v="${v// /}"
    v="${v//$'\u00A0'/}"; v="${v//$'\u200B'/}"
    [[ -z "$v" ]] && break
    [[ "$v" =~ $3 ]] && break
    warn "esse valor não parece certo — esperado algo como: ${4}"
    sub "cola de novo, ou Enter pra pular"
  done
  printf -v "$1" '%s' "$v"
}

ETAPA="preparação"
on_err(){
  say ""
  say "  ${RED}✗ A instalação parou na etapa: ${BOLD}${ETAPA}${C0}"
  say "     ${DIM}Não entre em pânico: rode o MESMO comando de novo — tudo que já foi feito${C0}"
  say "     ${DIM}é reaproveitado e eu continuo do ponto certo. Se repetir o erro, mande${C0}"
  say "     ${DIM}o print da tela e o arquivo abaixo pra quem te deu este instalador.${C0}"
  say ""
  if [[ -s "${LOG:-}" ]]; then
    say "     ${DIM}Últimas linhas de ${LOG}:${C0}"
    tail -n 8 "$LOG" 2>/dev/null | sed 's/^/       /'
    say ""
  fi
}
trap on_err ERR

DRY=""; SEED=""; BASE_ONLY=""; REPAIR_BESZEL=""; RECONCILE=""; REPAIR_CHAT=""; SMOKE_FALHAS=0
while [[ $# -gt 0 ]]; do case "$1" in
  --dry-run) DRY="--dry-run" ;;
  --seed) SEED="${2:-}"; shift ;;
  --base) BASE_ONLY="1" ;;
  --repair-beszel) REPAIR_BESZEL="1" ;;
  --reconcile) RECONCILE="1" ;;
  --repair-chat) REPAIR_CHAT="1" ;;
  *) warn "argumento desconhecido: $1" ;;
esac; shift; done

D=""   # prefixo de escrita: em dry-run, NADA toca o disco real
if [[ "$DRY" == "--dry-run" ]]; then D=$(mktemp -d); fi

# log: em dry-run vai pra arquivo temporário; se /var/log não aceitar, cai no /tmp
if [[ "$DRY" == "--dry-run" ]]; then LOG="$(mktemp)"
else touch "$LOG" 2>/dev/null || LOG="/tmp/motobase-instalacao.log"; fi
# gira enquanto o comando trabalha: nada de tela parada sem explicação
girinho(){ # $1=pid  $2=rótulo
  local pid="$1" rot="$2" i=0 t0=$SECONDS el ult
  local -a q=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  [[ -t 1 ]] || return 0
  while kill -0 "$pid" 2>/dev/null; do
    el=$(( SECONDS - t0 ))
    ult=$(tail -n 1 "$LOG" 2>/dev/null | tr -d '\r\n\t' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-38)
    printf "\r     ${LRJ}%s${C0} %s ${DIM}%02d:%02d${C0}  ${DIM}%s${C0}\033[K" \
      "${q[i++%10]}" "$rot" $((el/60)) $((el%60)) "$ult"
    sleep 0.3
  done
  printf "\r\033[K"
}

run(){
  if [[ "$DRY" == "--dry-run" ]]; then
    if [[ "$*" == *"docker secret create"* ]]; then
      local secret_name
      secret_name=$(printf '%s' "$*" | sed -nE 's/.*docker secret create ([^ ]+).*/\1/p')
      say "       ${DIM}[dry-run] criaria Docker secret ${secret_name:-protegido}${C0}"
    else
      say "       ${DIM}[dry-run] $*${C0}"
    fi
    RUN_ROTULO=""; RUN_LIMITE=""
    return 0
  fi
  local rot="${RUN_ROTULO:-trabalhando}" lim="${RUN_LIMITE:-$RUN_LIMITE_PADRAO}" rc=0 pid l marca
  RUN_ROTULO=""; RUN_LIMITE=""
  marca=$(wc -l < "$LOG" 2>/dev/null || echo 0)   # só mostrar a saída DESTE comando
  printf '\n--- %s | %s\n%s\n' "$(date '+%F %T')" "$rot" "$*" >>"$LOG" 2>/dev/null || true
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$lim" bash -c "$*" >>"$LOG" 2>&1 &
  else
    bash -c "$*" >>"$LOG" 2>&1 &
  fi
  pid=$!
  girinho "$pid" "$rot"
  wait "$pid" || rc=$?
  if [[ $rc -eq 124 ]]; then
    say ""
    warn "passou de $( [[ $lim -ge 60 ]] && echo "$((lim/60)) minutos" || echo "${lim}s" ) em: ${rot}"
    while IFS= read -r l; do sub "$l"; done < <(tail -n +$((marca+3)) "$LOG" 2>/dev/null | tail -n 6)
    die "Interrompi para não travar a instalação para sempre.
       Quase sempre é rede lenta ou espelho de pacotes fora do ar.
       Log completo: ${LOG}
       Rode o MESMO comando de novo — o que já subiu é reaproveitado."
  fi
  if [[ $rc -ne 0 ]]; then
    say ""
    warn "falhou: ${rot} ${DIM}(código ${rc})${C0}"
    while IFS= read -r l; do sub "$l"; done < <(tail -n +$((marca+3)) "$LOG" 2>/dev/null | tail -n 6)
    sub "log completo: ${LOG}"
  fi
  return $rc
}

TOTAL_STEPS=9
[[ -n "$BASE_ONLY" ]] && TOTAL_STEPS=8

banner(){
  say ""
  say "   ${LRJ_CLR}██╗   ██╗██╗██████╗ ███████╗${C0}"
  say "   ${LRJ_CLR}██║   ██║██║██╔══██╗██╔════╝${C0}"
  say "   ${LRJ}██║   ██║██║██████╔╝█████╗${C0}"
  say "   ${LRJ}╚██╗ ██╔╝██║██╔══██╗██╔══╝${C0}"
  say "   ${LRJ_ESC} ╚████╔╝ ██║██████╔╝███████╗${C0}"
  say "   ${LRJ_ESC}  ╚═══╝  ╚═╝╚═════╝ ╚══════╝${C0}"
  say ""
  say "   ${CHIP} M O T O B A S E ${C0}  ${BOLD}DO ZERO À BASE DA SUA STARTUP. EM UMA LINHA.${C0}"
  say "   ${DIM}Infra pronta para criar, publicar e crescer sem bagunça.${C0}"
  say "   ${DIM}por Rafael Ventura × Fable 5  ·  ${C0}${LRJ}rafaelventura.com.br${C0}${DIM}  ·  ${C0}${LRJ}github.com/rafzinn${C0}${DIM}${SEED:+  ·  semente: ${SEED}}${C0}"
  say "  ${DIM}$(regua $LARGURA)${C0}"
}

# ── checagens ────────────────────────────────────────────────────────────────
preflight(){
  ETAPA="checagens iniciais"
  etapa "0/${TOTAL_STEPS}" "PREPARAÇÃO" "conferindo se este servidor está apto"
  [[ $EUID -eq 0 ]] || die "Rode como root (digite: sudo -i  e depois rode o comando de novo)."
  command -v apt-get >/dev/null || die "Este instalador suporta Ubuntu/Debian (apt)."

  # sistema velho demais quebra o instalador do Docker
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    local major="${VERSION_ID%%.*}"
    case "${ID:-}" in
      ubuntu) [[ "${major:-0}" -ge 22 ]] || warn "Ubuntu ${VERSION_ID} é antigo — recomendo 22.04 ou 24.04; pode falhar." ;;
      debian) [[ "${major:-0}" -ge 11 ]] || warn "Debian ${VERSION_ID} é antigo — recomendo 11+; pode falhar." ;;
    esac
  fi

  # máquina fraca demais = sofrimento evitável
  local mem_mb; mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  [[ "$mem_mb" -gt 0 && "$mem_mb" -lt 1800 ]] && warn "Só ${mem_mb}MB de RAM — o mínimo confortável é 2GB (4GB ideal)." || true
  local disk_gb; disk_gb=$(df --output=avail -BG / 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  [[ "$disk_gb" -gt 0 && "$disk_gb" -lt 15 ]] && warn "Só ${disk_gb}GB livres no disco — o mínimo confortável é 20GB." || true

  IP=$(curl -fsS -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  ok "Servidor ${BOLD}$(hostname)${C0} — IP público ${BOLD}${IP}${C0}"
  ok "Sistema ${BOLD}${PRETTY_NAME:-Linux}${C0} · ${mem_mb}MB RAM · ${disk_gb}GB livres"

  # needrestart pergunta "quais serviços reiniciar?" depois de cada apt e, com a
  # saída silenciada, essa pergunta trava tudo sem aparecer na tela. Desarmado aqui.
  if [[ "$DRY" != "--dry-run" && -d /etc/needrestart ]]; then
    mkdir -p /etc/needrestart/conf.d
    printf '$nrconf{restart} = "a";\n$nrconf{kernelhints} = 0;\n' \
      > /etc/needrestart/conf.d/99-motobase.conf 2>/dev/null || true
  fi
  # GLOBAL: todo apt-get da máquina (o meu, o do get.docker.com, o do nodesource)
  # passa a ESPERAR o lock do dpkg até 10min em vez de falhar. Sem isso, os scripts
  # oficiais de terceiros — que rodam apt-get próprio — quebram quando o
  # unattended-upgrades da VPS nova está segurando o lock (falha do teste 01/09).
  if [[ "$DRY" != "--dry-run" ]]; then
    mkdir -p /etc/apt/apt.conf.d
    printf 'DPkg::Lock::Timeout "600";\n' > /etc/apt/apt.conf.d/99motobase-lock 2>/dev/null || true
  fi
  # e desliga os gatilhos de auto-update durante a instalação — assim o apt de
  # terceiros nunca disputa o lock no meio do caminho (a causa raiz do 01/09).
  if [[ "$DRY" != "--dry-run" ]]; then
    systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
  fi

  # VPS recém-criada costuma estar atualizando sozinha — espera o apt liberar
  if command -v fuser >/dev/null 2>&1; then
    local w=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
      [[ $w -eq 0 ]] && info "o servidor está terminando uma atualização automática — aguardando liberar…"
      sleep 5; w=$((w+5))
      [[ $w -ge 300 ]] && die "O apt está ocupado há 5 minutos. Espere um pouco e rode o comando de novo."
    done
  fi

  # porta 80/443 ocupada por outro servidor web (Apache/nginx pré-instalado) mata o Traefik
  if ! docker service ls --format '{{.Name}}' 2>/dev/null | grep -q '^traefik_traefik$'; then
    local p
    for p in 80 443; do
      if ss -ltn 2>/dev/null | grep -q ":${p} "; then
        die "A porta ${p} já está em uso por outro programa neste servidor.
       Provavelmente um Apache/nginx pré-instalado. Corrija com:
         systemctl disable --now apache2 nginx 2>/dev/null
       e rode o instalador de novo."
      fi
    done
  fi

  if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == "active" ]]; then
    # Swarm do PRÓPRIO Motobase (marca de instalação anterior) = retomada: segue sem
    # perguntar. Eu mesmo mando "rode o mesmo comando de novo" — não faz sentido
    # travar o aluno numa pergunta cujo padrão era [n] (Enter abortava). Só pergunta
    # se for um Swarm estranho, sem marca nossa.
    if [[ -f /var/log/motobase-instalacao.log || -d /etc/motobase || -f /opt/traefik/stack.yml ]]; then
      ok "Instalação anterior do Motobase encontrada — ${BOLD}retomando${C0}, pulo o que já existe"
    else
      warn "Este servidor JÁ tem Docker Swarm ativo (e não foi o Motobase que criou)."
      ask GOON "Continuar mesmo assim? Vou pular o que já existir (s/n)" "n"
      [[ "$GOON" =~ ^[sS] ]] || die "Abortado com segurança — nada foi alterado."
    fi
  fi

  # semente (se pedida): baixa ANTES de perguntar qualquer coisa — falha cedo
  SEED_DIR=""
  if [[ -n "$SEED" ]]; then
    SEED_DIR=$(mktemp -d)
    $CURL "${RAW_BASE}/seeds/${SEED}/CLAUDE.md" -o "${SEED_DIR}/CLAUDE.md" 2>/dev/null \
      || die "Semente '${SEED}' não encontrada no repo (seeds/${SEED}/)."
    $CURL "${RAW_BASE}/seeds/${SEED}/ddl.sql" -o "${SEED_DIR}/ddl.sql" 2>/dev/null || true
    ok "Semente ${BOLD}${SEED}${C0} baixada$([[ -f ${SEED_DIR}/ddl.sql ]] && echo ' (com schema de banco)')"
  fi
}

cf_dns_record(){
  local record_domain="$1" target_ip="$2" purpose="${3:-DNS only}"
  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] criaria o registro A ${record_domain} → ${target_ip} na Cloudflare (${purpose})${C0}"
    return 0
  fi
  if [[ -z "${CFTOK:-}" ]]; then
    warn "sem token Cloudflare — crie o registro A ${record_domain} → ${target_ip} manualmente"
    return 0
  fi
  local api="https://api.cloudflare.com/client/v4"
  local hdr="Authorization: Bearer ${CFTOK}"
  # zona (SEM status=active: pega zona recém-adicionada/pending também)
  local d="$record_domain" zid=""
  while [[ "$d" == *.* ]]; do
    zid=$(curl -fsS -H "$hdr" "${api}/zones?name=${d}" 2>/dev/null | grep -oP '"id":"\K[a-f0-9]{32}' | head -1 || true)
    [[ -n "$zid" ]] && break
    d="${d#*.}"
  done
  if [[ -z "$zid" ]]; then
    warn "não achei a zona de ${record_domain} na conta Cloudflare — crie o registro A manualmente"
    return 0
  fi
  # RECONCILIA pra UM registro só: apaga TODO A/AAAA/CNAME deste nome (duplicados,
  # IP morto de VPS antiga, CNAME velho) — mas NUNCA MX/TXT/NS (e-mail do cliente).
  # Depois cria um A limpo apontando pro alvo. Corrige a raiz do "apex no IP morto".
  local t rid ids
  for t in A AAAA CNAME; do
    ids=$(curl -fsS -H "$hdr" "${api}/zones/${zid}/dns_records?type=${t}&name=${record_domain}&per_page=100" 2>/dev/null | grep -oP '"id":"\K[a-f0-9]{32}' || true)
    for rid in $ids; do
      curl -fsS -X DELETE -H "$hdr" "${api}/zones/${zid}/dns_records/${rid}" >/dev/null 2>&1 || true
    done
  done
  local body="{\"type\":\"A\",\"name\":\"${record_domain}\",\"content\":\"${target_ip}\",\"ttl\":300,\"proxied\":false}"
  local resp; resp=$(curl -fsS -X POST -H "$hdr" -H 'Content-Type: application/json' -d "$body" "${api}/zones/${zid}/dns_records" 2>/dev/null || true)
  if [[ "$resp" == *'"success":true'* ]]; then
    ok "DNS ${BOLD}${record_domain}${C0} → ${target_ip} ${DIM}(${purpose})${C0}"
  else
    warn "Cloudflare recusou ${record_domain} → ${target_ip}"
    local msg; msg=$(printf '%s' "$resp" | grep -oP '"message":"\K[^"]*' | head -1)
    [[ -n "$msg" ]] && sub "motivo: ${msg}"
    sub "o token precisa de 'Zone.DNS Edit' (All zones) — ou crie o A manualmente"
  fi
}

# ── etapa 1: questionário — TUDO de uma vez, depois o script trabalha sozinho ─
questionario(){
  ETAPA="questionário"
  etapa "1/${TOTAL_STEPS}" "QUESTIONÁRIO" "responde tudo agora e vai tomar um café · Enter pula credencial"

  while true; do
    ask PROJ_NAME "Nome da VPS ou cliente"
    SLUG=$(printf '%s' "${PROJ_NAME}" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' || true)
    SLUG=${SLUG:0:24}
    # nome de schema/serviço precisa começar com LETRA (Postgres recusa começar por número)
    [[ "$SLUG" =~ ^[a-z] ]] && break
    warn "o nome precisa ter letras (ex: 'Somos Um', 'minha startup')"
    sub "só números não dá pra nomear banco e serviços"
  done
  info "identificador técnico: ${BOLD}${SLUG}${C0} ${DIM}(banco, stacks, secrets)${C0}"

  say ""
  say "     ${BOLD}Cloudflare DNS${C0} ${DIM}— cria os endereços privados dos painéis${C0}"
  sub "conta nova: crie a conta, adicione o domínio e troque os nameservers no registrador"
  link "https://dash.cloudflare.com/sign-up"
  sub "espere o domínio aparecer como Active em Websites; depois crie o token abaixo"
  link "https://dash.cloudflare.com/"
  sub "My Profile → API Tokens → Create Token → modelo 'Edit zone DNS'"
  sub "Zone Resources: Include → ${BOLD}All zones${C0} — assim a VPS gerencia o DNS de TODOS os seus domínios (não só um)"
  sub "este token é SOMENTE para DNS; o R2 usa outro par de chaves no módulo /guard"
  link "https://dash.cloudflare.com/profile/api-tokens"
  while true; do
    ask_tok CFTOK "Token Cloudflare para editar DNS" '^[A-Za-z0-9_-]{30,60}$' "cfut_…"
    [[ -z "$CFTOK" || "$DRY" == "--dry-run" ]] && break
    local cf_status
    cf_status=$(curl -fsS --max-time 10 -H "Authorization: Bearer ${CFTOK}" \
      https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null \
      | grep -o '"status":"active"' || true)
    if [[ -n "$cf_status" ]]; then
      ok "Token Cloudflare válido e ativo"
      break
    fi
    warn "a Cloudflare não reconheceu esse token como ativo"
    sub "cole novamente; Enter pula e mostra como configurar o DNS manualmente"
  done

  while true; do
    ask BASE_DOMAIN "Domínio base da marca (ex: seusite.com.br)"
    BASE_DOMAIN=$(echo "$BASE_DOMAIN" | tr '[:upper:]' '[:lower:]' \
      | sed -e 's|^https\?://||' -e 's|/.*$||' | tr -d ' ')
    [[ "$BASE_DOMAIN" == *.* && "$BASE_DOMAIN" != *..* \
      && "$BASE_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])$ ]] && break
    warn "digite apenas o domínio principal, como meusite.com.br"
  done
  APP_DOMAIN=""
  if [[ -n "$BASE_ONLY" ]]; then
    info "nenhuma aplicação será criada agora"
    sub "quando criar um site ou WordPress, o endereço sugerido será nome-do-projeto.${BASE_DOMAIN}"
    if [[ -n "$CFTOK" ]]; then
      sub "a Cloudflare criará depois apenas portainer.${BASE_DOMAIN} e monitor.${BASE_DOMAIN}"
    else
      sub "sem token Cloudflare, os endereços privados dos painéis deverão ser criados manualmente depois"
    fi
  else
    while true; do
      ask APP_DOMAIN "Domínio completo do projeto" "${SLUG}.${BASE_DOMAIN}"
      APP_DOMAIN=$(echo "$APP_DOMAIN" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's|^https\?://||' -e 's|/.*$||' | tr -d ' ')
      [[ "$APP_DOMAIN" == *.* && "$APP_DOMAIN" != *..* \
        && "$APP_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])$ ]] && break
      warn "isso não parece um domínio (ex: app.meusite.com.br)"
    done
    if [[ -n "$CFTOK" ]]; then
      cf_dns_record "$APP_DOMAIN" "$IP" "público · DNS only para emissão do HTTPS"
    else
      caixa_abre
      caixa_txt "${BOLD}DNS NA MÃO, ENTÃO${C0}"
      caixa_txt "No painel do seu DNS, crie um registro tipo ${BOLD}A${C0} apontando"
      caixa_txt "${BOLD}${APP_DOMAIN}${C0} pro IP deste servidor: ${BOLD}${IP}${C0}"
      caixa_txt "${DIM}Na primeira emissão do HTTPS, deixe a nuvem CINZA (DNS only).${C0}"
      caixa_fecha
    fi
  fi

  local email_domain="$BASE_DOMAIN"
  ask LE_EMAIL "E-mail pro certificado HTTPS (Let's Encrypt)" "admin@${email_domain}"
  [[ "$LE_EMAIL" == *@* ]] || { warn "e-mail sem @ — usando admin@${email_domain}"; LE_EMAIL="admin@${email_domain}"; }

  say ""
  say "     ${BOLD}Painel de saúde (Beszel)${C0} ${DIM}— senha de acesso${C0}"
  sub "Enter = gero uma forte automática (fica em 'motobase acessos')"
  while true; do
    read_masked "     ${LRJ}?${C0} Senha do painel Beszel (mín. 10, ou Enter p/ automática): "
    BESZEL_ADMIN_PW="${REPLY//$'\r'/}"; BESZEL_ADMIN_PW="${BESZEL_ADMIN_PW// /}"
    [[ -z "$BESZEL_ADMIN_PW" ]] && { info "ok — senha automática"; break; }
    [[ ${#BESZEL_ADMIN_PW} -ge 10 ]] && { ok "senha do Beszel definida por você"; break; }
    warn "muito curta — o Beszel exige pelo menos 10 caracteres"
  done

  say ""
  say "     ${BOLD}Claude${C0} ${DIM}— opcional · programador da VPS + chat no navegador, no SEU plano Max${C0}"
  sub "no SEU computador rode ${BOLD}claude setup-token${C0} e cole o sk-ant-oat aqui"
  sub "um token só liga os dois: o Claude Code na VPS E o chat web — tudo na assinatura, sem custo de API"
  link "https://console.anthropic.com/settings/keys"
  ask_tok CLTOK "Setup-token do Claude (sk-ant-oat — liga o Claude Code E o chat, no seu plano)" '^sk-ant-' "sk-ant-oat01-…"

  say ""
  say "     ${BOLD}OpenAI${C0} ${DIM}— opcional · para aplicações que usam a API${C0}"
  sub "crie a conta, adicione faturamento e gere uma chave do projeto"
  link "https://platform.openai.com/settings/organization/billing/overview"
  link "https://platform.openai.com/api-keys"
  ask_tok OAKEY "Chave da OpenAI" '^sk-' "sk-proj-…"

  say ""
  say "     ${BOLD}RyzeAPI (WhatsApp)${C0} ${DIM}— opcional · pros bots de WhatsApp que você criar${C0}"
  sub "token da SUA conta Ryze (um só serve todos os números); Enter pula"
  link "https://ryzeapi.cloud"
  ask_tok RYZETOK "Token da conta Ryze" '^.{16,}$' "token da conta Ryze"

  say ""
  say "     ${BOLD}Telegram${C0} ${DIM}— opcional · bots e alertas de aplicações futuras${C0}"
  sub "fale com o @BotFather, mande /newbot e copie o token; Enter pula"
  link "https://t.me/BotFather"
  ask_tok TGTOK "Token do bot Telegram" '^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$' "1234567890:AAE…"

  say ""
  say "     ${BOLD}Tailscale${C0} ${DIM}— necessário · rede privada de gestão${C0}"
  sub "conta nova: entrar já cria sua Tailnet; em Keys clique 'Generate auth key'"
  sub "use chave de uso único, não efêmera; sem ela o instalador abre um link de login"
  link "https://login.tailscale.com/admin/settings/keys"
  sub "instale o Tailscale no SEU computador pra acessar os painéis privados:"
  say "       ${DIM}└ Windows:${C0} ${LRJ}https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe${C0}"
  say "       ${DIM}└ macOS:  ${C0} ${LRJ}https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg${C0}"
  ask_tok TSKEY "Auth key do Tailscale" '^tskey-' "tskey-auth-…"

  say ""
  QUER_MOLT="n"
  MOLT_TG=""
  if [[ -z "$BASE_ONLY" ]]; then
    ask QUER_MOLT "Instalar o moltbot (agente pessoal OpenClaw)? (s/n)" "n"
  fi
  if [[ -z "$BASE_ONLY" && "$QUER_MOLT" =~ ^[sS] ]]; then
    sub "um bot do Telegram só roda em UM servidor — se o seu moltbot atual já usa"
    sub "um bot em outra VPS, crie um bot NOVO no @BotFather pra este"
    ask_tok MOLT_TG "Token do bot Telegram do moltbot" '^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$' "1234567890:AAE…"
  fi

  say ""
  if [[ -n "$APP_DOMAIN" ]]; then
    info "conferindo propagação de ${APP_DOMAIN}…"
    local resolved; resolved=$(getent hosts "$APP_DOMAIN" | awk '{print $1}' | head -1 || true)
    if [[ "$resolved" == "$IP" ]]; then ok "DNS propagado: ${APP_DOMAIN} → ${IP}"
    elif [[ -n "$resolved" ]]; then warn "${APP_DOMAIN} resolve pra ${resolved} (esperava ${IP})"; sub "se a nuvem laranja da Cloudflare está ligada, é normal"
    else warn "ainda não resolve"; sub "o HTTPS pode falhar na 1ª tentativa e se corrigir sozinho depois"
    fi
  fi

  # conferência final — errou algo? refaz sem dó
  local m
  say ""
  say "  ${DIM}$(regua $LARGURA)${C0}"
  say "     ${BOLD}CONFERE AÍ${C0}"
  say "       ${DIM}base ·······${C0} ${PROJ_NAME}  ${DIM}(${SLUG})${C0}"
  say "       ${DIM}domínio base ·${C0} ${BASE_DOMAIN}"
  if [[ -n "$APP_DOMAIN" ]]; then
    say "       ${DIM}projeto ·····${C0} https://${APP_DOMAIN}"
  else
    say "       ${DIM}aplicação ··${C0} ${DIM}nenhuma criada agora${C0}"
  fi
  say "       ${DIM}e-mail ·····${C0} ${LE_EMAIL}"
  m="${DIM}pulado${C0}"; [[ -n "$CFTOK" ]] && m="informado ${DIM}(DNS automático)${C0}"; say "       ${DIM}cloudflare ·${C0} ${m}"
  m="${DIM}pulado${C0}"; [[ -n "$CLTOK" ]] && m="informado"; say "       ${DIM}claude ·····${C0} ${m}"
  m="${DIM}pulado${C0}"; [[ -n "$OAKEY" ]] && m="informado";  say "       ${DIM}openai ·····${C0} ${m}"
  m="${DIM}pulado${C0}"; [[ -n "$TGTOK" ]] && m="informado";  say "       ${DIM}telegram ···${C0} ${m}"
  m="${DIM}login por link${C0}"; [[ -n "$TSKEY" ]] && m="informado"; say "       ${DIM}tailscale ··${C0} ${m}"
  if [[ -z "$BASE_ONLY" ]]; then
    m="não"; [[ "$QUER_MOLT" =~ ^[sS] ]] && m="sim"; say "       ${DIM}moltbot ····${C0} ${m}"
  fi
  say "  ${DIM}$(regua $LARGURA)${C0}"
  ask CONF "Tudo certo? (s = bora / n = responder de novo)" "s"
  [[ "$CONF" =~ ^[sS] ]] || { questionario; return; }

  CRED="${D}/root/${SLUG}-credenciais.txt"
  mkdir -p "${D}/root"
  : > "$CRED"; chmod 600 "$CRED"
  cred(){ echo "$*" >> "$CRED"; }
  cred "══════ ${PROJ_NAME} — credenciais geradas em $(date '+%d/%m/%Y %H:%M') ══════"
  cred "Servidor: $(hostname)  IP: ${IP}"
  cred "Domínio base: ${BASE_DOMAIN}"
  [[ -n "$APP_DOMAIN" ]] && cred "Projeto: https://${APP_DOMAIN}" || cred "Aplicação: nenhuma criada nesta instalação"
  if [[ -n "$CFTOK" ]]; then
    # fonte única do token Cloudflare: arquivo root-only (o Claude da VPS usa daqui)
    mkdir -p "${D}/root/.config/cloudflare"; chmod 700 "${D}/root/.config/cloudflare"
    printf '%s\n' "$CFTOK" > "${D}/root/.config/cloudflare/token"
    chmod 600 "${D}/root/.config/cloudflare/token"
    cred "Cloudflare: token da API em /root/.config/cloudflare/token (FONTE ÚNICA — não copiar)"
  fi
  ok "Questionário completo — ${DIM}daqui pra frente é comigo${C0}"
}

# ── etapa 2: docker + swarm ──────────────────────────────────────────────────
docker_swarm(){
  ETAPA="Docker + Swarm"
  etapa "2/${TOTAL_STEPS}" "DOCKER + SWARM" "o motor que roda tudo, com auto-restart"
  if ! command -v jq >/dev/null || ! command -v openssl >/dev/null; then
    info "instalando utilitários básicos…"
    RUN_ROTULO="instalando utilitários base"
    run "$APT update && $APT install ca-certificates curl jq openssl"
  fi
  # Segurança do host desde o primeiro dia. A blindagem definitiva do SSH fica
  # para depois que o aluno validar a entrada privada pela Tailnet.
  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] instalaria fail2ban e atualizações de segurança automáticas${C0}"
  else
    $APT update -qq >/dev/null 2>&1 || true
    $APT install -qq fail2ban unattended-upgrades >/dev/null 2>&1 || true
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
    # MOTD limpa: tira a propaganda do login do Ubuntu (ESM, news, "N updates",
    # release-upgrade). Deixa o "reboot required" (aviso legítimo) e o header.
    chmod -x /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news \
             /etc/update-motd.d/88-esm-announce /etc/update-motd.d/90-updates-available \
             /etc/update-motd.d/91-release-upgrade /etc/update-motd.d/91-contract-ua-esm-status \
             /etc/update-motd.d/95-hwe-eol >/dev/null 2>&1 || true
    systemctl disable --now motd-news.timer >/dev/null 2>&1 || true
    [[ -f /etc/default/motd-news ]] && sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news >/dev/null 2>&1 || true
    : > /etc/motd 2>/dev/null || true
    ok "Proteção do host: fail2ban + atualizações de segurança automáticas · login limpo"
    sub "SSH por senha continua só até você validar o acesso privado e rodar 'motobase preparar-ssh'"
  fi
  if ! command -v docker >/dev/null; then
    RUN_ROTULO="instalando o Docker (script oficial)"
    if ! run "$CURL https://get.docker.com | sh"; then
      # quase sempre é o lock do apt disputado pelo auto-update: espera e tenta 1x mais
      warn "1ª tentativa do Docker falhou — aguardando o apt e tentando de novo…"
      esperar_apt_livre
      RUN_ROTULO="instalando o Docker (2ª tentativa)"
      run "$CURL https://get.docker.com | sh" \
        || die "Não foi possível instalar o Docker após 2 tentativas. Veja o log (${LOG}) e rode o MESMO comando de novo — o que já subiu é reaproveitado."
    fi
  fi
  command -v docker >/dev/null || die "O instalador terminou, mas o comando docker não apareceu. Veja /tmp/motobase-docker-install.log e rode o mesmo comando de novo."
  ok "Docker $(docker --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo instalado)"
  if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]]; then
    RUN_ROTULO="iniciando o Docker Swarm"
LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1); [[ -n "$LOCAL_IP" ]] || LOCAL_IP="$IP"
    run "docker swarm init --advertise-addr ${LOCAL_IP}"
  fi
  ok "Swarm ativo"
  sub "se um serviço cair, o Swarm sobe outro sozinho"
  RUN_ROTULO="criando a rede interna"
  docker network inspect web >/dev/null 2>&1 || run "docker network create -d overlay --attachable web"
  ok "Rede overlay ${BOLD}web${C0}"
}

# ── etapa 3: traefik ─────────────────────────────────────────────────────────
traefik_stack(){
  ETAPA="Traefik (HTTPS)"
  etapa "3/${TOTAL_STEPS}" "TRAEFIK" "o porteiro: HTTPS automático pra todo serviço novo"
  if docker service ls --format '{{.Name}}' 2>/dev/null | grep -q '^traefik_traefik$'; then
    ok "Traefik já existe neste Swarm — mantendo o que está no ar"
    return
  fi
  mkdir -p "${D}/opt/traefik" && touch "${D}/opt/traefik/acme.json" && chmod 600 "${D}/opt/traefik/acme.json"
  # Middleware tailnet-only via FILE PROVIDER (não via labels do Traefik — isso dava
  # "port is missing" e o middleware nunca registrava, deixando chat/bot em 404).
  # Faixas: localhost + privadas do Docker (o Traefik enxerga o cliente como IP
  # interno) + CGNAT da tailnet. Genérico: vale em qualquer VPS. A isolação real
  # vem do DNS apontar chat/bot pro IP da TAILNET (só a tailnet alcança 100.x).
  mkdir -p "${D}/opt/traefik/dynamic"
  cat > "${D}/opt/traefik/dynamic/middlewares.yml" <<'DYN'
http:
  middlewares:
    tailnet-only:
      ipWhiteList:
        sourceRange:
          - 127.0.0.1/32
          - 10.0.0.0/8
          - 172.16.0.0/12
          - 192.168.0.0/16
          - 100.64.0.0/10
DYN
  # DNS-01 (Cloudflare) — necessário pra emitir HTTPS de serviços SÓ-tailnet
  # (HTTP-01 não alcança um IP privado). Só entra se o wizard coletou o token CF.
  local TRAEFIK_DNS01_CMD="" TRAEFIK_DNS01_ENV=""
  if [[ -n "${CFTOK:-}" ]]; then
    TRAEFIK_DNS01_CMD=$'\n      - --certificatesresolvers.ledns.acme.email='"${LE_EMAIL}"$'\n      - --certificatesresolvers.ledns.acme.storage=/acme.json\n      - --certificatesresolvers.ledns.acme.dnschallenge.provider=cloudflare\n      - --certificatesresolvers.ledns.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53'
    TRAEFIK_DNS01_ENV=$'\n    environment:\n      - CF_DNS_API_TOKEN='"${CFTOK}"
  fi
  cat > "${D}/opt/traefik/stack.yml" <<EOF
version: "3.8"
services:
  traefik:
    image: traefik:v2.11${TRAEFIK_DNS01_ENV}
    command:
      - --providers.docker=true
      - --providers.docker.swarmMode=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=web
      - --providers.file.directory=/etc/traefik/dynamic
      - --providers.file.watch=true
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --certificatesresolvers.le.acme.email=${LE_EMAIL}
      - --certificatesresolvers.le.acme.storage=/acme.json
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web${TRAEFIK_DNS01_CMD}
    ports:
      # host mode: Traefik enxerga o IP REAL do cliente (sem isso, allowlist de IP não funciona)
      - { target: 80, published: 80, mode: host }
      - { target: 443, published: 443, mode: host }
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/traefik/acme.json:/acme.json
      - /opt/traefik/dynamic:/etc/traefik/dynamic:ro
    networks: [web]
    deploy:
      placement: { constraints: [node.role == manager] }
networks:
  web: { external: true }
EOF
  RUN_ROTULO="subindo o Traefik (HTTPS)"
  run "docker stack deploy --detach=true -c /opt/traefik/stack.yml traefik"
  ok "Traefik no ar"
  sub "certificado Let's Encrypt emitido sozinho quando o domínio apontar pra cá"
}

# ── etapa 4: banco + redis (CRUS — schema é com você e o Claude) ─────────────
dados_stack(){
  ETAPA="banco de dados"
  etapa "4/${TOTAL_STEPS}" "DADOS" "Postgres com pgvector + Redis, fora do alcance da internet"
  local PGP RDP; PGP=$(pw); RDP=$(pw)
  if ! docker secret inspect "${SLUG}_pg_password" >/dev/null 2>&1; then
    swarm_secret "${SLUG}_pg_password" "$PGP"
  else
    warn "secret ${SLUG}_pg_password já existe — mantendo a senha atual"
    PGP="(já existia — veja o registro anterior)"
  fi
  if ! docker secret inspect "${SLUG}_redis_password" >/dev/null 2>&1; then
    swarm_secret "${SLUG}_redis_password" "$RDP"
  else
    warn "secret ${SLUG}_redis_password já existe — mantendo a senha atual"
  fi
  mkdir -p "${D}/opt/${SLUG}"
  cat > "${D}/opt/${SLUG}/stack.yml" <<EOF
version: "3.8"
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/${SLUG}_pg_password
      POSTGRES_DB: ${SLUG}
    secrets: [${SLUG}_pg_password]
    volumes: [pgdata:/var/lib/postgresql/data]
    networks: [internal]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U postgres -d ${SLUG}"]
      interval: 15s
      timeout: 5s
      retries: 5
  redis:
    image: redis:7-alpine
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass \"\$\$(cat /run/secrets/${SLUG}_redis_password)\""]
    secrets: [${SLUG}_redis_password]
    volumes: [redisdata:/data]
    networks: [internal]
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"\$\$(cat /run/secrets/${SLUG}_redis_password)\" ping | grep -qx PONG"]
      interval: 15s
      timeout: 5s
      retries: 5
networks:
  internal: { driver: overlay, attachable: true }
secrets:
  ${SLUG}_pg_password: { external: true }
  ${SLUG}_redis_password: { external: true }
volumes: { pgdata: {}, redisdata: {} }
EOF
  RUN_ROTULO="subindo Postgres e Redis"
  run "docker stack deploy --detach=true -c /opt/${SLUG}/stack.yml ${SLUG}"
  ok "Postgres ${BOLD}${SLUG}_postgres${C0} · Redis ${BOLD}${SLUG}_redis${C0}"
  sub "rede interna '${SLUG}_internal' — banco e redis não ficam expostos na web"
  cred ""; cred "Postgres: host ${SLUG}_postgres:5432  db ${SLUG}  user postgres"
  cred "  senha: ${PGP}  (fonte de verdade: docker secret ${SLUG}_pg_password)"
  cred "Redis: host ${SLUG}_redis:6379 (rede interna; senha no secret ${SLUG}_redis_password)"
  banco_pronto
}

banco_pronto(){
  ETAPA="preparação do banco"
  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] habilitaria pgvector${SEED:+ e aplicaria o schema da semente '${SEED}'}${C0}"
    [[ -n "$SEED" ]] && { ok "Schema da semente ${BOLD}${SEED}${C0} aplicado"; return; }
  else
    info "aguardando o Postgres subir…"
    local i=0 CID=""
    # A imagem oficial sobe um Postgres TEMPORÁRIO (só socket unix) pra rodar o init
    # e o DERRUBA ("terminating connection due to administrator command") antes de
    # subir o definitivo. pg_isready no socket vê o temporário e o SQL morre no meio
    # (falha real 02/09). Só o servidor definitivo escuta TCP: readiness = TCP.
    until CID=$(docker ps -q -f name="${SLUG}_postgres" | head -1) && [[ -n "$CID" ]] \
      && docker exec "$CID" pg_isready -h 127.0.0.1 -U postgres -d "${SLUG}" >/dev/null 2>&1; do
      i=$((i+1)); [[ $i -gt 90 ]] && die "Postgres não subiu em 3 minutos — rode o comando de novo; se repetir, veja: docker service ps ${SLUG}_postgres"
      sleep 2
    done
    # e mesmo assim: o SQL de preparação tenta até 5x (rede/timing), nunca morre na 1ª
    local t=0
    until docker exec "$CID" psql -h 127.0.0.1 -U postgres -d "${SLUG}" -c "create extension if not exists vector;" >/dev/null 2>&1; do
      t=$((t+1)); [[ $t -ge 5 ]] && die "Postgres subiu mas não aceitou o SQL de preparação após 5 tentativas — rode o comando de novo"
      sleep 3
    done
    if [[ -n "$SEED" && -f "${SEED_DIR}/ddl.sql" ]]; then
      sed "s/{{SLUG}}/${SLUG}/g" "${SEED_DIR}/ddl.sql" > "/opt/${SLUG}/ddl.sql"
      docker exec -i "$CID" psql -h 127.0.0.1 -U postgres -d "${SLUG}" -v ON_ERROR_STOP=1 < "/opt/${SLUG}/ddl.sql" >/dev/null
      ok "Schema da semente ${BOLD}${SEED}${C0} aplicado"
      sub "DDL guardado em /opt/${SLUG}/ddl.sql"
      return
    fi
  fi
  ok "Banco ${BOLD}${SLUG}${C0} pronto, pgvector habilitado"
  sub "sem tabelas: o schema nasce do SEU produto"
}

# ── etapa 5: secrets da aplicação (já respondidos no questionário) ───────────
app_secrets(){
  ETAPA="secrets da aplicação"
  etapa "5/${TOTAL_STEPS}" "SECRETS" "segredos guardados pelo Swarm, nunca em texto no código"
  if [[ -n "$TGTOK" ]] && ! docker secret inspect "${SLUG}_tg_token" >/dev/null 2>&1; then
    swarm_secret "${SLUG}_tg_token" "$TGTOK"
    ok "${SLUG}_tg_token"
  fi
  if [[ -n "$OAKEY" ]] && ! docker secret inspect "${SLUG}_openai_key" >/dev/null 2>&1; then
    swarm_secret "${SLUG}_openai_key" "$OAKEY"
    ok "${SLUG}_openai_key"
  fi
  if [[ -n "$BASE_ONLY" ]]; then
    cred ""; cred "Secrets da fundação no Swarm: ${SLUG}_pg_password${TGTOK:+, ${SLUG}_tg_token}${OAKEY:+, ${SLUG}_openai_key}"
    ok "Credenciais opcionais da fundação guardadas"
    sub "nenhuma aplicação foi criada"
    return
  fi
  local JWTS; JWTS=$(pw)$(pw)
  if ! docker secret inspect "${SLUG}_jwt_secret" >/dev/null 2>&1; then
    swarm_secret "${SLUG}_jwt_secret" "$JWTS"
    ok "${SLUG}_jwt_secret ${DIM}(login/sessões da sua app)${C0}"
  fi
  cred ""; cred "Secrets no Swarm: ${SLUG}_pg_password, ${SLUG}_jwt_secret${TGTOK:+, ${SLUG}_tg_token}${OAKEY:+, ${SLUG}_openai_key}"
  cred "  (cadastrar depois: printf '%s' 'VALOR' | docker secret create NOME -)"

  # template da stack da aplicação — deploy quando a API existir
  cat > "${D}/opt/${SLUG}/app.yml" <<EOF
version: "3.8"
services:
  api:
    image: ${SLUG}-api:latest
    environment:
      APP_DOMAIN: ${APP_DOMAIN}
      PG_HOST: ${SLUG}_postgres
      REDIS_URL: redis://${SLUG}_redis:6379
    secrets: [${SLUG}_pg_password, ${SLUG}_jwt_secret, ${SLUG}_tg_token, ${SLUG}_openai_key]
    networks: [${SLUG}_internal, web]
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.routers.${SLUG}.rule=Host(\`${APP_DOMAIN}\`)
        - traefik.http.routers.${SLUG}.entrypoints=websecure
        - traefik.http.routers.${SLUG}.tls.certresolver=le
        - traefik.http.services.${SLUG}.loadbalancer.server.port=3000
        # ── rota de ADMIN (descomentar quando existir /admin na API) ──
        # Só-tailnet via middleware definido no Traefik. priority=2000 evita
        # que um router com PathPrefix genérico roube as chamadas do admin.
        # - traefik.http.routers.${SLUG}-adm.rule=Host(\`${APP_DOMAIN}\`) && PathPrefix(\`/admin\`)
        # - traefik.http.routers.${SLUG}-adm.entrypoints=websecure
        # - traefik.http.routers.${SLUG}-adm.tls.certresolver=le
        # - traefik.http.routers.${SLUG}-adm.middlewares=tailnet-only
        # - traefik.http.routers.${SLUG}-adm.priority=2000
        # - traefik.http.routers.${SLUG}-adm.service=${SLUG}
networks:
  ${SLUG}_internal: { external: true }
  web: { external: true }
secrets:
  ${SLUG}_pg_password: { external: true }
  ${SLUG}_jwt_secret: { external: true }
  ${SLUG}_tg_token: { external: true }
  ${SLUG}_openai_key: { external: true }
EOF
  ok "Template da app em ${BOLD}/opt/${SLUG}/app.yml${C0}"
  sub "deploy quando a API existir: docker stack deploy -c /opt/${SLUG}/app.yml ${SLUG}-app"
}

# ── etapa 6: tailscale + gestão só-tailnet ───────────────────────────────────
tailscale_gestao(){
  ETAPA="Tailscale + gestão"
  etapa "6/${TOTAL_STEPS}" "TAILSCALE" "painéis de gestão fora da internet pública"
  info "Portainer e Beszel só abrem com o Tailscale ligado no SEU dispositivo"
  if ! command -v tailscale >/dev/null; then
    info "instalando Tailscale (script oficial)…"
    RUN_ROTULO="instalando o Tailscale"
    run "$CURL https://tailscale.com/install.sh | sh"
  fi
  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] tailscale up${TSKEY:+ --authkey=***}${C0}"; TSIP="100.x.y.z"
  else
    if [[ -n "$TSKEY" ]]; then
      # auth key expirada/errada NÃO derruba a instalação: cai pro login por link
      tailscale up --authkey="$TSKEY" 2>/dev/null || {
        warn "a auth key não foi aceita (expirada?) — indo pro login por link"
        say "     ${AMB}→ abra o link abaixo e autorize este servidor na sua tailnet:${C0}"
        tailscale up
      }
    else
      say "     ${AMB}→ abra o link abaixo e autorize este servidor na sua tailnet:${C0}"
      tailscale up
    fi
    TSIP=$(tailscale ip -4 2>/dev/null | head -1 || true)
    [[ -n "$TSIP" ]] || die "Tailscale não subiu — rode 'tailscale up' manualmente e depois o instalador de novo."
  fi
  ok "Servidor na tailnet: ${BOLD}${TSIP}${C0}"

  PORTAINER_URL="http://${TSIP}:9000"
  BESZEL_URL="http://${TSIP}:8090"
  if [[ -n "$CFTOK" && -n "$BASE_DOMAIN" ]]; then
    local portainer_host="portainer.${BASE_DOMAIN}" monitor_host="monitor.${BASE_DOMAIN}"
    cf_dns_record "$portainer_host" "$TSIP" "privado · acessível somente conectado à Tailnet"
    cf_dns_record "$monitor_host" "$TSIP" "privado · acessível somente conectado à Tailnet"
    PORTAINER_URL="http://${portainer_host}:9000"
    BESZEL_URL="http://${monitor_host}:8090"
  fi

  # Portainer OFICIAL: socket direto, porta 9000 host-mode, travado no firewall pra tailnet
  mkdir -p "${D}/opt/${SLUG}" "${D}/usr/local/sbin" "${D}/etc/systemd/system"
  cat > "${D}/opt/${SLUG}/portainer.yml" <<'EOF'
version: "3.8"
services:
  portainer:
    image: portainer/portainer-ce:latest
    command: --admin-password-file /run/secrets/portainer_admin_pw
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - pdata:/data
    secrets: [portainer_admin_pw]
    ports:
      - { target: 9000, published: 9000, mode: host }
    deploy:
      placement: { constraints: [node.role == manager] }
volumes:
  pdata:
secrets:
  portainer_admin_pw: { external: true }
EOF
  # ── Portainer: admin já criado, login VERIFICADO, auto-conserto ──────────
  # O aluno não cola comando: o instalador PROVA que o login funciona antes de seguir.
  if [[ "$DRY" == "--dry-run" ]]; then
    RUN_ROTULO="subindo o Portainer"
    run "docker stack deploy --detach=true -c /opt/${SLUG}/portainer.yml portainer"
  else
    mkdir -p "${D}/etc/motobase" 2>/dev/null || true
    if [[ -r "${D}/etc/motobase/portainer-admin.env" ]]; then
      # instalação anterior saudável: mantém a senha salva
      # shellcheck disable=SC1090
      source "${D}/etc/motobase/portainer-admin.env"
      PORTAINER_PW="${PORTAINER_ADMIN_PASSWORD:-}"
    else
      # fresco OU quebrado (stack de versão antiga sem credencial salva): zera e recria limpo
      if docker service inspect portainer_portainer >/dev/null 2>&1; then
        info "Portainer de uma versão anterior sem credencial salva — refazendo do zero (sem zumbi)…"
        portainer_limpar
      fi
      PORTAINER_PW=$(pw)$(pw)
      printf 'PORTAINER_ADMIN_USER=admin\nPORTAINER_ADMIN_PASSWORD=%q\n' "$PORTAINER_PW" > "${D}/etc/motobase/portainer-admin.env"
      chmod 600 "${D}/etc/motobase/portainer-admin.env"
    fi
    portainer_secret_garantir "$PORTAINER_PW"
    RUN_ROTULO="subindo o Portainer"
    run "docker stack deploy --detach=true -c /opt/${SLUG}/portainer.yml portainer"
    info "verificando o login do Portainer (prova real)…"
    if ! portainer_login_esperar "$PORTAINER_PW"; then
      warn "Portainer subiu mas o login não respondeu — refazendo do zero (zumbi ou volume sujo)…"
      portainer_limpar
      portainer_secret_garantir "$PORTAINER_PW"
      RUN_ROTULO="subindo o Portainer (2ª vez, limpo)"
      run "docker stack deploy --detach=true -c /opt/${SLUG}/portainer.yml portainer"
      portainer_login_esperar "$PORTAINER_PW" \
        || die "O Portainer não aceitou o login nem após refazer do zero. Veja: docker service logs portainer_portainer"
    fi
    ok "Portainer: login do admin ${BOLD}verificado${C0} ${DIM}($(docker ps --filter name=portainer_portainer -q | wc -l) container)${C0}"
    info "conectando o Portainer ao Docker…"
    if portainer_ensure_env "$PORTAINER_PW"; then ok "Portainer: environment ${BOLD}local${C0} conectado ${DIM}(enxerga os containers)${C0}"
    else warn "environment não conectou — em Environments → Add → Docker (Socket) você conecta em 2 cliques"; fi
  fi

  # Porta publicada pelo Docker IGNORA o ufw — o trinco de verdade é na chain
  # DOCKER-USER, e precisa sobreviver a reboot (script + unit systemd).
  cat > "${D}/usr/local/sbin/gestao-lockdown.sh" <<'EOF'
#!/usr/bin/env bash
# Trava portas de GESTÃO pra aceitarem só tailnet (100.64/10) e localhost.
set -e
PORTS="9000 8090 18789"   # Portainer · Beszel · moltbot — só pela tailnet
iptables -N GESTAO-TAILNET 2>/dev/null || true
iptables -F GESTAO-TAILNET
for p in $PORTS; do
  iptables -A GESTAO-TAILNET -p tcp --dport "$p" -s 100.64.0.0/10 -j RETURN
  iptables -A GESTAO-TAILNET -p tcp --dport "$p" -s 127.0.0.0/8    -j RETURN
  iptables -A GESTAO-TAILNET -p tcp --dport "$p" -j DROP
done
iptables -C DOCKER-USER -j GESTAO-TAILNET 2>/dev/null || iptables -I DOCKER-USER 1 -j GESTAO-TAILNET
iptables -C INPUT -j GESTAO-TAILNET 2>/dev/null || iptables -I INPUT 1 -j GESTAO-TAILNET
EOF
  chmod +x "${D}/usr/local/sbin/gestao-lockdown.sh"
  cat > "${D}/etc/systemd/system/gestao-lockdown.service" <<EOF
[Unit]
Description=${PROJ_NAME} - trava portas de gestao pra tailnet
After=docker.service tailscaled.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gestao-lockdown.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  RUN_ROTULO="ativando o firewall de gestão"
  run "systemctl daemon-reload && systemctl enable --now gestao-lockdown.service"
  ok "Firewall de gestão ativo ${DIM}(persistente a reboot)${C0}"
  sub "do IP público as portas 9000/8090/18789 nem respondem — só pela tailnet"

  [[ "$DRY" != "--dry-run" ]] && sleep 8
  ok "Portainer: ${BOLD}${PORTAINER_URL}${C0}"
  sub "admin já criado — usuário ${BOLD}admin${C0}, senha em ${BOLD}motobase acessos${C0} (sem setup-token)"
  cred ""; cred "Portainer (gestão, só-tailnet): ${PORTAINER_URL}"
  cred "  login: admin"
  cred "  senha: ${PORTAINER_PW:-veja motobase acessos}"
  cred "IP tailnet do servidor: ${TSIP}"

  beszel_stack
  home_stack
  instalar_claude_chat
  instalar_wa_bot
}

# ── Beszel: painel leve de CPU, RAM, disco, rede e containers ─────────────────
beszel_stack(){
  ETAPA="Beszel"
  local version="0.18.8" dir="${D}/opt/${SLUG}/beszel"
  local admin_file="${D}/etc/motobase/beszel-admin.env"
  local token_state="${D}/etc/motobase/beszel-agent-token-mode"
  local admin_email="${LE_EMAIL}" admin_password="" auth="" key="" token=""
  mkdir -p "$dir" "${D}/etc/motobase"

  if [[ -r "$admin_file" ]]; then
    # shellcheck disable=SC1090
    source "$admin_file"
    admin_email="${BESZEL_ADMIN_EMAIL:-$admin_email}"
    admin_password="${BESZEL_ADMIN_PASSWORD:-}"
  fi
  # senha escolhida no wizard tem prioridade sobre a automática (mas não sobre
  # um admin_file já gravado numa instalação anterior — idempotência).
  [[ -z "$admin_password" ]] && admin_password="${BESZEL_ADMIN_PW:-}"
  if [[ -z "$admin_password" ]]; then
    admin_password="$(pw)$(pw)"
    {
      printf 'BESZEL_ADMIN_EMAIL=%q\n' "$admin_email"
      printf 'BESZEL_ADMIN_PASSWORD=%q\n' "$admin_password"
    } > "$admin_file"
    chmod 600 "$admin_file"
  fi

  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] criaria Beszel Hub + Agent ${version}${C0}"
    say "       ${DIM}[dry-run] registraria o Agent automaticamente no Hub${C0}"
    write_beszel_stack "$dir/stack.yml" "$version"
    ok "Beszel: ${BOLD}${BESZEL_URL}${C0} ${DIM}(simulação)${C0}"
    cred ""; cred "Beszel (saúde, só-tailnet): ${BESZEL_URL}"
    cred "  login: ${admin_email}"
    cred "  senha inicial: ${admin_password}"
    return
  fi

  # O primeiro boot recebe credenciais por um arquivo temporário. Depois que a
  # conta existe, o deploy final remove a senha do serviço e do stack.yml.
  if ! docker service inspect beszel_hub >/dev/null 2>&1; then
    local init_stack; init_stack=$(mktemp)
    cat > "$init_stack" <<EOF
version: "3.8"
services:
  hub:
    image: henrygd/beszel:${version}
    environment:
      APP_URL: ${BESZEL_URL}
      USER_EMAIL: ${admin_email}
      USER_PASSWORD: ${admin_password}
      CHECK_UPDATES: "false"
    volumes: [hub_data:/beszel_data]
    ports:
      - { target: 8090, published: 8090, mode: host }
    deploy:
      placement: { constraints: [node.role == manager] }
volumes:
  hub_data: {}
EOF
    chmod 600 "$init_stack"
    docker stack deploy --detach=true -c "$init_stack" beszel >/dev/null
    rm -f "$init_stack"
  fi

  info "configurando o painel e registrando esta VPS…"
  local i=0
  until curl -fsS --max-time 3 "http://127.0.0.1:8090/api/health" >/dev/null 2>&1; do
    i=$((i+1)); [[ $i -gt 30 ]] && { warn "Beszel Hub demorou a responder — a fundação segue; conserte depois com --repair-beszel"; return 0; }
    sleep 3
  done

  # Token temporário vive só na memória do Hub e morre quando ele reinicia.
  # Esta marca também migra instalações feitas por versões antigas do wizard.
  local renew_agent_secrets=0 wait=0 token_response="" requested_token="" token_active="" token_permanent=""
  [[ -r "$token_state" && "$(<"$token_state")" == "permanent-v1" ]] || renew_agent_secrets=1
  if [[ "$renew_agent_secrets" -eq 1 ]]; then
    info "atualizando o registro persistente do Beszel Agent…"
    if docker service inspect beszel_agent >/dev/null 2>&1; then
      docker service rm beszel_agent >/dev/null
      until ! docker service inspect beszel_agent >/dev/null 2>&1; do
        wait=$((wait+1)); [[ $wait -gt 20 ]] && { warn "Beszel Agent antigo não parou — a fundação segue; conserte depois com --repair-beszel"; return 0; }
        sleep 1
      done
    fi
    docker secret rm beszel_agent_key >/dev/null 2>&1 || true
    docker secret rm beszel_agent_token >/dev/null 2>&1 || true
  fi

  if ! docker secret inspect beszel_agent_key >/dev/null 2>&1 \
    || ! docker secret inspect beszel_agent_token >/dev/null 2>&1; then
    _bz_auth(){ curl -fsS --max-time 10 -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg identity "$admin_email" --arg password "$admin_password" '{identity:$identity,password:$password}')" \
      "http://127.0.0.1:8090/api/collections/users/auth-with-password" 2>/dev/null | jq -r '.token // empty'; }
    auth=$(_bz_auth)
    if [[ -z "$auth" ]]; then
      # volume remendado: o env USER_* é ignorado quando já existe conta. Força a senha
      # salva no admin (superuser) e no user via CLI oficial do PocketBase — auto-conserto.
      local bz_cid; bz_cid=$(docker ps -q -f name=beszel_hub | head -1)
      if [[ -n "$bz_cid" ]]; then
        info "Beszel com conta antiga — regravando a senha do painel (superuser upsert)…"
        docker exec "$bz_cid" /beszel superuser upsert "$admin_email" "$admin_password" >/dev/null 2>&1 || true
        sleep 2; auth=$(_bz_auth)
      fi
    fi
    [[ -n "$auth" ]] || { warn "Beszel não aceitou o login automático — a fundação segue; conserte depois com --repair-beszel"; return 0; }
    key=$(curl -fsS --max-time 10 -H "Authorization: ${auth}" \
      "http://127.0.0.1:8090/api/beszel/getkey" | jq -r '.key // empty')
    requested_token=$(openssl rand -hex 32)
    token_response=$(curl -fsS --max-time 10 -H "Authorization: ${auth}" \
      "http://127.0.0.1:8090/api/beszel/universal-token?enable=1&permanent=1&token=${requested_token}")
    token=$(jq -r '.token // empty' <<<"$token_response")
    token_active=$(jq -r '.active // false' <<<"$token_response")
    token_permanent=$(jq -r '.permanent // false' <<<"$token_response")
    [[ -n "$key" && "$token" == "$requested_token" && "$token_active" == true && "$token_permanent" == true ]] \
      || { warn "Beszel não confirmou o token do Agent — a fundação segue; conserte depois com --repair-beszel"; return 0; }
    docker secret inspect beszel_agent_key >/dev/null 2>&1 \
      || printf '%s' "$key" | docker secret create beszel_agent_key -
    docker secret inspect beszel_agent_token >/dev/null 2>&1 \
      || printf '%s' "$token" | docker secret create beszel_agent_token -
  fi

  write_beszel_stack "$dir/stack.yml" "$version"
  docker stack deploy --detach=true -c "/opt/${SLUG}/beszel/stack.yml" beszel >/dev/null
  if [[ -z "$auth" ]]; then
    auth=$(curl -fsS --max-time 10 -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg identity "$admin_email" --arg password "$admin_password" \
        '{identity:$identity,password:$password}')" \
      "http://127.0.0.1:8090/api/collections/users/auth-with-password" | jq -r '.token // empty')
  fi
  i=0
  until curl -fsS --max-time 5 -H "Authorization: ${auth}" \
    "http://127.0.0.1:8090/api/collections/systems/records?perPage=100" \
    | jq -e --arg name "$SLUG" 'any(.items[]; .name == $name)'; do
    i=$((i+1)); [[ $i -gt 20 ]] && { warn "Beszel Agent ainda não apareceu no painel — a fundação continuará normalmente"; sub "investigar: docker service logs beszel_agent --tail 80"; return 0; }
    sleep 3
  done
  printf 'permanent-v1\n' > "$token_state"
  chmod 600 "$token_state"
  ok "Beszel Hub + Agent instalados"
  ok "Esta VPS apareceu no painel como ${BOLD}${SLUG}${C0}"
  ok "Painel de saúde: ${BOLD}${BESZEL_URL}${C0}"
  sub "CPU, RAM, disco, rede e containers · acesso somente pela Tailnet"
  cred ""; cred "Beszel (saúde, só-tailnet): ${BESZEL_URL}"
  cred "  login: ${admin_email}"
  cred "  senha inicial: ${admin_password}"
}

write_beszel_stack(){
  local target="$1" version="$2"
  cat > "$target" <<EOF
version: "3.8"
services:
  hub:
    image: henrygd/beszel:${version}
    environment:
      APP_URL: ${BESZEL_URL}
      CHECK_UPDATES: "false"
    volumes: [hub_data:/beszel_data]
    ports:
      - { target: 8090, published: 8090, mode: host }
    healthcheck:
      test: ["CMD", "/beszel", "health", "--url", "http://localhost:8090"]
      interval: 120s
      start_period: 10s
      timeout: 5s
    deploy:
      placement: { constraints: [node.role == manager] }
  agent:
    image: henrygd/beszel-agent:${version}
    environment:
      HUB_URL: http://127.0.0.1:8090
      KEY_FILE: /run/secrets/beszel_agent_key
      TOKEN_FILE: /run/secrets/beszel_agent_token
      SYSTEM_NAME: ${SLUG}
      DISABLE_SSH: "true"
    secrets: [beszel_agent_key, beszel_agent_token]
    volumes:
      - agent_data:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [hostnet]
    deploy:
      mode: global
      placement: { constraints: [node.role == manager] }
secrets:
  beszel_agent_key: { external: true }
  beszel_agent_token: { external: true }
networks:
  hostnet:
    external: true
    name: host
volumes:
  hub_data: {}
  agent_data: {}
EOF
  chmod 600 "$target"
}

# ── home: página pública de boas-vindas no domínio raiz ──────────────────────
# Fundação nova nasce com uma tela no ar em BASE_DOMAIN (marca Motobase + nome do
# projeto), com o DNS ligado automaticamente pelo token Cloudflare do wizard.
# Enquanto o aluno não publica o produto dele, o root não fica vazio/erro.
home_stack(){
  ETAPA="página de boas-vindas"
  [[ -z "${BASE_DOMAIN:-}" ]] && { info "sem domínio base — pulo a home pública"; return 0; }
  info "publicando a página de boas-vindas em ${BASE_DOMAIN}…"

  # DNS público (DNS-only p/ o Traefik emitir o HTTPS via HTTP-01)
  if [[ -n "${CFTOK:-}" ]]; then
    cf_dns_record "$BASE_DOMAIN" "$IP" "público · home de boas-vindas"
    cf_dns_record "www.${BASE_DOMAIN}" "$IP" "público · alias www da home"
  else
    caixa_abre
    caixa_txt "${BOLD}DNS DA HOME NA MÃO${C0}"
    caixa_txt "Crie registros ${BOLD}A${C0} de ${BOLD}${BASE_DOMAIN}${C0} e ${BOLD}www.${BASE_DOMAIN}${C0}"
    caixa_txt "apontando pro IP deste servidor: ${BOLD}${IP}${C0}"
    caixa_fecha
  fi

  mkdir -p "${D}/opt/home"
  local home_ok=1
  $CURL "${RAW_BASE}/templates/home/index.html" -o "${D}/opt/home/index.html" 2>/dev/null || home_ok=0
  $CURL "${RAW_BASE}/templates/home/favicon.svg" -o "${D}/opt/home/favicon.svg" 2>/dev/null || home_ok=0
  if [[ $home_ok -eq 0 ]]; then
    warn "não consegui baixar a home agora — o root fica sem página"
    sub "pra publicar depois: rode o mesmo comando de novo"
    return 0
  fi
  # nome do projeto no lugar do placeholder
  # substitui o nome com escape de \ & / — nome com esses caracteres não quebra o sed
  local pn_safe; pn_safe=$(printf '%s' "$PROJ_NAME" | sed -e 's/[\\&/]/\\&/g')
  sed -i "s/{{PROJ_NAME}}/${pn_safe}/g" "${D}/opt/home/index.html"

  cat > "${D}/opt/home/home.yml" <<HOMEYML
version: "3.8"
services:
  home:
    image: nginx:alpine
    volumes:
      - /opt/home:/usr/share/nginx/html:ro
    networks: [web]
    deploy:
      placement: { constraints: [node.role == manager] }
      labels:
        - traefik.enable=true
        - "traefik.http.routers.home.rule=Host(\`${BASE_DOMAIN}\`) || Host(\`www.${BASE_DOMAIN}\`)"
        - traefik.http.routers.home.entrypoints=websecure
        - traefik.http.routers.home.tls.certresolver=le
        - traefik.http.services.home.loadbalancer.server.port=80
networks:
  web:
    external: true
HOMEYML
  RUN_ROTULO="subindo a home de boas-vindas"
  run "docker stack deploy --detach=true -c /opt/home/home.yml home" || { warn "a home falhou ao subir — a fundação segue; rode de novo pra tentar"; return 0; }
  ok "Home no ar: ${BOLD}https://${BASE_DOMAIN}${C0}"
  sub "HTTPS emitido em ~1 min; enquanto propaga o DNS, pode dar erro de certificado"
}

# ── chat Claude: só sobe se o aluno deu uma API KEY (sk-ant-api) ──────────────
# Fonte baixada do repo e construída aqui (sem Docker Hub). Atrás da tailnet,
# HTTPS por DNS-01 (chat.DOMÍNIO → IP tailnet). A chave vira Docker secret.
instalar_claude_chat(){
  ETAPA="chat Claude"
  # o chat roda o Claude Code por baixo (plano Max) — precisa do SETUP-TOKEN (sk-ant-oat),
  # o MESMO que autentica o Claude Code. Sem custo de API, é a assinatura do dono.
  if [[ "${CLTOK:-}" != sk-ant-oat* ]]; then
    if [[ -n "${CLTOK:-}" ]]; then
      warn "chat NÃO instalado — o chat usa a assinatura (plano Max), que precisa do setup-token sk-ant-oat…"
      sub "no SEU computador rode 'claude setup-token' e cole o sk-ant-oat; a API key (sk-ant-api) não serve pro chat"
    fi
    return 0
  fi
  if [[ -z "${BASE_DOMAIN:-}" || -z "${CFTOK:-}" || -z "${TSIP:-}" ]]; then
    info "chat Claude pulado — precisa de domínio base, token Cloudflare e tailnet ativa"
    return 0
  fi
  info "instalando o chat Claude em chat.${BASE_DOMAIN} (só pela tailnet)…"

  # DNS privado (IP tailnet) — HTTPS sai por DNS-01, não precisa ser público
  cf_dns_record "chat.${BASE_DOMAIN}" "$TSIP" "privado · chat Claude, só pela tailnet"

  # fonte do repo → build local
  mkdir -p "${D}/opt/claude-chat/public"
  local chat_ok=1
  for f in package.json server.js Dockerfile .dockerignore; do
    $CURL "${RAW_BASE}/apps/claude-chat/${f}" -o "${D}/opt/claude-chat/${f}" 2>/dev/null || chat_ok=0
  done
  $CURL "${RAW_BASE}/apps/claude-chat/public/index.html" -o "${D}/opt/claude-chat/public/index.html" 2>/dev/null || chat_ok=0
  if [[ $chat_ok -eq 0 ]]; then
    warn "não consegui baixar o app do chat — pulei; rode o mesmo comando de novo pra tentar"
    return 0
  fi

  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] construiria motobase/claude-chat:local e subiria a stack chat${C0}"
    ok "chat Claude: ${BOLD}https://chat.${BASE_DOMAIN}${C0} ${DIM}(simulação)${C0}"
    return 0
  fi

  RUN_ROTULO="construindo a imagem do chat"
  run "docker build -t motobase/claude-chat:local /opt/claude-chat" || { warn "build do chat falhou — a fundação segue; rode de novo pra tentar"; return 0; }

  # setup-token (assinatura) como secret — idempotente
  if ! docker secret inspect claude_oauth_token >/dev/null 2>&1; then
    printf '%s' "$CLTOK" | docker secret create claude_oauth_token - >/dev/null       && sub "setup-token gravado no secret claude_oauth_token"       || warn "não consegui criar o secret do setup-token"
  fi

  cat > "${D}/opt/claude-chat/chat.yml" <<CHATYML
version: "3.8"
services:
  chat:
    image: motobase/claude-chat:local
    environment:
      - MODEL=sonnet
      - APP_TITLE=Claude
    secrets: [claude_oauth_token]
    volumes: [claude_chat_data:/data]
    networks: [web]
    deploy:
      placement: { constraints: [node.role == manager] }
      labels:
        - traefik.enable=true
        - "traefik.http.routers.chat.rule=Host(\`chat.${BASE_DOMAIN}\`)"
        - traefik.http.routers.chat.entrypoints=websecure
        - traefik.http.routers.chat.tls.certresolver=ledns
        - traefik.http.routers.chat.middlewares=tailnet-only@file
        - traefik.http.services.chat.loadbalancer.server.port=3000
secrets:
  claude_oauth_token: { external: true }
volumes:
  claude_chat_data:
networks:
  web: { external: true }
CHATYML
  RUN_ROTULO="subindo o chat Claude"
  run "docker stack deploy --detach=true -c /opt/claude-chat/chat.yml chat" || { warn "deploy do chat falhou — a fundação segue"; return 0; }
  ok "Chat Claude no ar: ${BOLD}https://chat.${BASE_DOMAIN}${C0}"
  sub "só abre com o Tailscale ligado · seletor Opus/Sonnet/Haiku/Fable · custo por resposta"
  cred ""; cred "Chat Claude (só-tailnet): https://chat.${BASE_DOMAIN}"
}

# ── bot WhatsApp base: sobe se houver token Ryze + chave OpenAI ───────────────
# Assistente de WhatsApp genérico (RyzeAPI + OpenAI, padrão do Motobot), pronto
# pra ser "recheado" por cliente. Webhook PÚBLICO (a Ryze precisa alcançar);
# pareamento e admin SÓ pela tailnet. O bot auto-registra a instância no boot.
instalar_wa_bot(){
  ETAPA="bot WhatsApp base"
  if [[ -z "${RYZETOK:-}" ]]; then return 0; fi
  if [[ "${OAKEY:-}" != sk-* ]]; then
    info "bot WhatsApp pulado — precisa da chave OpenAI (o cérebro do bot é OpenAI)"
    return 0
  fi
  if [[ -z "${BASE_DOMAIN:-}" || -z "${CFTOK:-}" || -z "${TSIP:-}" ]]; then
    info "bot WhatsApp pulado — precisa de domínio base, token Cloudflare e tailnet"
    return 0
  fi
  local INST_NAME; INST_NAME=$(printf '%s' "${SLUG}bot" | tr -cd '[:alnum:]')
  info "instalando o bot WhatsApp base (instância ${INST_NAME})…"

  # DNS: webhook público + pareamento só-tailnet
  cf_dns_record "bot.${BASE_DOMAIN}" "$IP" "público · webhook do bot (a Ryze precisa alcançar)"
  cf_dns_record "bot-admin.${BASE_DOMAIN}" "$TSIP" "privado · pareamento do bot, só pela tailnet"

  mkdir -p "${D}/opt/wa-bot/lib"
  local bot_ok=1
  for f in package.json server.js Dockerfile .dockerignore; do
    $CURL "${RAW_BASE}/apps/wa-bot/${f}" -o "${D}/opt/wa-bot/${f}" 2>/dev/null || bot_ok=0
  done
  $CURL "${RAW_BASE}/apps/wa-bot/lib/wa.js" -o "${D}/opt/wa-bot/lib/wa.js" 2>/dev/null || bot_ok=0
  if [[ $bot_ok -eq 0 ]]; then
    warn "não consegui baixar o bot — pulei; rode o mesmo comando de novo"
    return 0
  fi

  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] construiria o bot e subiria a stack wabot${C0}"
    ok "bot WhatsApp: ${BOLD}https://bot-admin.${BASE_DOMAIN}${C0} ${DIM}(simulação)${C0}"
    return 0
  fi

  RUN_ROTULO="construindo a imagem do bot"
  run "docker build -t motobase/wa-bot:local /opt/wa-bot" || { warn "build do bot falhou — a fundação segue; rode de novo pra tentar"; return 0; }

  # segredos: Ryze, OpenAI e o token do webhook (gerado aqui)
  docker secret inspect ryze_account_token >/dev/null 2>&1 || printf '%s' "$RYZETOK" | docker secret create ryze_account_token - >/dev/null 2>&1
  docker secret inspect openai_api_key >/dev/null 2>&1 || printf '%s' "$OAKEY" | docker secret create openai_api_key - >/dev/null 2>&1
  local WHTOK; WHTOK=$(pw)$(pw)
  docker secret inspect wa_webhook_token >/dev/null 2>&1 || printf '%s' "$WHTOK" | docker secret create wa_webhook_token - >/dev/null 2>&1

  cat > "${D}/opt/wa-bot/wabot.yml" <<WABOTYML
version: "3.8"
services:
  wabot:
    image: motobase/wa-bot:local
    environment:
      - RYZE_INSTANCE=${INST_NAME}
      - WA_WEBHOOK_URL=https://bot.${BASE_DOMAIN}/webhook/wa
      - MODEL=gpt-4o-mini
      - SYSTEM_PROMPT=Você é um assistente de atendimento no WhatsApp. Responda em português do Brasil, de forma curta, clara e cordial.
    secrets: [ryze_account_token, openai_api_key, wa_webhook_token]
    volumes: [wabot_data:/data]
    networks: [web]
    deploy:
      placement: { constraints: [node.role == manager] }
      labels:
        - traefik.enable=true
        # webhook PÚBLICO (só o path /webhook) — a Ryze precisa POSTar aqui
        - "traefik.http.routers.wabot-hook.rule=Host(\`bot.${BASE_DOMAIN}\`) && PathPrefix(\`/webhook\`)"
        - traefik.http.routers.wabot-hook.entrypoints=websecure
        - traefik.http.routers.wabot-hook.tls.certresolver=le
        - traefik.http.routers.wabot-hook.service=wabot
        # pareamento/admin — SÓ pela tailnet
        - "traefik.http.routers.wabot-admin.rule=Host(\`bot-admin.${BASE_DOMAIN}\`)"
        - traefik.http.routers.wabot-admin.entrypoints=websecure
        - traefik.http.routers.wabot-admin.tls.certresolver=ledns
        - traefik.http.routers.wabot-admin.middlewares=tailnet-only@file
        - traefik.http.routers.wabot-admin.service=wabot
        - traefik.http.services.wabot.loadbalancer.server.port=3000
secrets:
  ryze_account_token: { external: true }
  openai_api_key: { external: true }
  wa_webhook_token: { external: true }
volumes:
  wabot_data:
networks:
  web: { external: true }
WABOTYML
  RUN_ROTULO="subindo o bot WhatsApp"
  run "docker stack deploy --detach=true -c /opt/wa-bot/wabot.yml wabot" || { warn "deploy do bot falhou — a fundação segue"; return 0; }
  ok "Bot WhatsApp no ar ${DIM}(base, esperando o número)${C0}"
  sub "PAREAR: abra ${BOLD}https://bot-admin.${BASE_DOMAIN}${C0} com o Tailscale ligado e escaneie o QR"
  cred ""; cred "Bot WhatsApp — pareamento (só-tailnet): https://bot-admin.${BASE_DOMAIN}"
  cred "  webhook público: https://bot.${BASE_DOMAIN}/webhook/wa"
}

# ── etapa 7: claude code — o programador mora aqui ───────────────────────────
claude_code(){
  ETAPA="Claude Code"
  etapa "7/${TOTAL_STEPS}" "CLAUDE CODE" "o programador desta VPS, pronto pra receber ordens"
  if ! command -v node >/dev/null || [[ "$(node -v 2>/dev/null | grep -oP '\d+' | head -1)" -lt 20 ]]; then
    info "instalando Node.js 22 (NodeSource)…"
    RUN_ROTULO="instalando o Node.js 22"
    run "$CURL https://deb.nodesource.com/setup_22.x | bash - && $APT install nodejs"
  fi
  ok "Node $(node -v 2>/dev/null || echo '(dry-run)')"

  # git + gh: FERRAMENTA de versionamento. A credencial NÃO é pedida aqui —
  # 'gh auth login' faz login pelo navegador (device flow), sem colar segredo no terminal.
  if ! command -v git >/dev/null || ! command -v gh >/dev/null; then
    info "instalando git e GitHub CLI…"
    RUN_ROTULO="instalando o git"
    run "$APT install git || true"
    if ! command -v gh >/dev/null; then
      RUN_ROTULO="instalando o GitHub CLI"
      run "$CURL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && echo 'deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list \
        && $APT update && $APT install gh || true"
    fi
  fi
  if [[ "$DRY" != "--dry-run" ]] && command -v git >/dev/null; then
    git config --global user.name "${PROJ_NAME}" >/dev/null 2>&1 || true
    git config --global user.email "${LE_EMAIL}" >/dev/null 2>&1 || true
    git config --global init.defaultBranch main >/dev/null 2>&1 || true
  fi
  if command -v gh >/dev/null; then
    ok "git + GitHub CLI prontos"
    sub "pra versionar: gh auth login — login pelo navegador, sem colar token"
  else
    warn "GitHub CLI não instalou agora — depois: apt-get install -y gh"
  fi

  if ! command -v claude >/dev/null; then
    info "instalando Claude Code…"
    # falha aqui NÃO derruba a infra — dá pra instalar depois
    RUN_ROTULO="instalando o Claude Code"
    run "npm install -g @anthropic-ai/claude-code" \
      || warn "não consegui instalar o Claude Code agora — depois rode: npm install -g @anthropic-ai/claude-code"
  fi
  command -v claude >/dev/null && ok "Claude Code $(claude --version 2>/dev/null | head -1 || echo instalado)" || true

  # credencial: setup-token (sk-ant-oat…) vira CLAUDE_CODE_OAUTH_TOKEN; chave API vira ANTHROPIC_API_KEY
  mkdir -p "${D}/etc/profile.d"
  if [[ -n "$CLTOK" ]]; then
    local VARNAME="ANTHROPIC_API_KEY"
    [[ "$CLTOK" == sk-ant-oat* ]] && VARNAME="CLAUDE_CODE_OAUTH_TOKEN"
    printf 'export %s=%q\n' "$VARNAME" "$CLTOK" > "${D}/etc/profile.d/claude-cred.sh"
    chmod 600 "${D}/etc/profile.d/claude-cred.sh"
    ok "Credencial gravada ${DIM}(${VARNAME})${C0}"
    sub "sessões novas de shell já nascem autenticadas"
  else
    warn "sem token do Claude — rode ${BOLD}claude${C0} uma vez e faça login pelo link"
  fi

  # CLAUDE.md: o Claude desta VPS nasce SABENDO a infra (e o projeto, se houver semente)
  mkdir -p "${D}/opt"
  if [[ -n "$SEED" && -f "${SEED_DIR}/CLAUDE.md" ]]; then
    sed -e "s/{{SLUG}}/${SLUG}/g" -e "s/{{PROJ_NAME}}/${PROJ_NAME}/g" \
        -e "s/{{APP_DOMAIN}}/${APP_DOMAIN}/g" -e "s/{{DATA}}/$(date '+%Y-%m-%d')/g" \
        "${SEED_DIR}/CLAUDE.md" > "${D}/opt/CLAUDE.md"
    ok "CLAUDE.md da semente ${BOLD}${SEED}${C0} semeado em /opt"
    sub "o Claude daqui já nasce sabendo o projeto inteiro"
  else
    cat > "${D}/opt/CLAUDE.md" <<EOF
# ${PROJ_NAME} — VPS (vibe stack, instalada em $(date '+%Y-%m-%d') via get.motobot.com.br/vibe)

Infra pronta; o PRODUTO começa do zero — pergunte ao dono o que ele quer construir
antes de criar qualquer coisa.

## Infra desta VPS (NÃO reinspecionar — instalada pelo vibe.sh)
- Docker Swarm + Traefik v2.11 (rede \`web\`, portas host-mode, certresolver \`le\`).
  NUNCA \`docker restart\`/\`docker stop\` em serviço Swarm (o Swarm sobe substituto e o
  reiniciado vira zumbi) — usar \`docker service update --force <svc>\`.
- Banco: \`${SLUG}_postgres\` (Postgres 16 + pgvector habilitado, db \`${SLUG}\`, SEM tabelas —
  desenhar o schema junto com o dono antes de criar). Rede interna \`${SLUG}_internal\`.
- Redis: \`${SLUG}_redis\` (cache/filas/sessões, AOF e senha ligados; secret \`${SLUG}_redis_password\`).
- Saúde: Beszel em \`${BESZEL_URL:-http://<ip-tailnet>:8090}\` (CPU, RAM, disco, rede e containers; só-tailnet).
- Secrets no Swarm (fonte única, NUNCA copiar valor em texto plano): ${SLUG}_pg_password,
  ${SLUG}_redis_password, ${SLUG}_jwt_secret${TGTOK:+, ${SLUG}_tg_token}${OAKEY:+, ${SLUG}_openai_key}. Ler em runtime via /run/secrets/.
- Aplicações: nenhuma publicada ainda. Crie um site ou WordPress pelo comando principal da
  Motobase; cada projeto recebe sua própria stack, domínio e backup sem reinstalar esta base.
- Gestão SÓ-TAILNET: Portainer :9000${QUER_MOLT:+, moltbot :18789} (lockdown na chain DOCKER-USER + unit
  gestao-lockdown; porta publicada pelo Docker ignora ufw). Rota /admin da app: middleware
  \`tailnet-only\` + priority 2000 (exemplo comentado no app.yml).
- Backup: pg_dump diário 03:10 → /var/backups/${SLUG} (retenção 14d). Offsite: guard
  (bash <(curl -fsSL https://get.motobot.com.br/guard)).

## Versionamento (fazer no PRIMEIRO código que existir)
- git e GitHub CLI já instalados. NÃO existe token guardado aqui — autenticar com
  \`gh auth login\` (login pelo navegador, device flow, escopo mínimo).
- Depois: \`gh repo create ${SLUG} --private --source=. --remote=origin --push\`.
- Commitar cedo e sempre; .gitignore deve excluir .env, credenciais e dumps.
  NUNCA commitar segredo — segredo vive em docker secret.

## Postura
- Commitar mudanças relevantes (git) e reportar resultado real, inclusive falhas.
- Segredo novo = docker secret; nunca hardcode, nunca .env commitado.
EOF
    ok "CLAUDE.md da infra semeado em /opt"
    sub "o Claude daqui já nasce sabendo o servidor"
  fi
  # gestão futura de DNS: o Claude da VPS precisa saber onde mora o token
  if [[ -n "$CFTOK" ]]; then
    cat >> "${D}/opt/CLAUDE.md" <<EOF

## Cloudflare (DNS deste projeto)
- Token da API (permissão Zone.DNS Edit): **/root/.config/cloudflare/token** (root-only, FONTE ÚNICA — ler em runtime, nunca copiar pra env/arquivo/código).
- Uso: \`curl -H "Authorization: Bearer \$(cat /root/.config/cloudflare/token)" https://api.cloudflare.com/client/v4/zones\`
- Regra: mudanças de DNS são ação pública — executar quando o dono pedir e reportar o resultado real.
EOF
  fi
  cred ""; cred "Claude Code: instalado${CLTOK:+, autenticado} — abrir com 'claude' dentro de /opt"
}

# ── etapa 8: moltbot (agente pessoal) ────────────────────────────────────────
moltbot_stack(){
  ETAPA="moltbot"
  etapa "8/9" "MOLTBOT" "agente pessoal (OpenClaw) — opcional"
  [[ "$QUER_MOLT" =~ ^[sS] ]] || { info "pulado ${DIM}(instale depois rodando o script de novo)${C0}"; return; }
  [[ "$(uname -m)" != "x86_64" ]] && warn "processador $(uname -m): a imagem do moltbot pode não existir pra essa arquitetura" || true
  local GWTOK; GWTOK=$(pw)$(pw)
  mkdir -p "${D}/opt/${SLUG}"
  cat > "${D}/opt/${SLUG}/moltbot.yml" <<EOF
version: "3.8"
services:
  moltbot:
    image: moltbot/moltbot:latest
    environment:
      # mesma env com DOIS nomes: o código lê CLAWDBOT_, o resto do mundo fala OPENCLAW_
      CLAWDBOT_GATEWAY_TOKEN: ${GWTOK}
      CLAWDBOT_GATEWAY_REMOTE_TOKEN: ${GWTOK}
      OPENCLAW_GATEWAY_TOKEN: ${GWTOK}${OAKEY:+
      OPENAI_API_KEY: ${OAKEY}}
    volumes:
      - moltbot_config:/root/.clawdbot
      - moltbot_workspace:/root/openclaw_workspace
    ports:
      # gateway/painel SÓ pela tailnet (porta travada na DOCKER-USER junto com o Portainer)
      - { target: 18789, published: 18789, mode: host }
    networks: [web]
    deploy:
      placement: { constraints: [node.role == manager] }
networks:
  web: { external: true }
volumes:
  moltbot_config:
  moltbot_workspace:
EOF
  chmod 600 "${D}/opt/${SLUG}/moltbot.yml"   # contém token/chave — root-only
  RUN_ROTULO="subindo o moltbot"
  run "docker stack deploy --detach=true -c /opt/${SLUG}/moltbot.yml moltbot" || { warn "moltbot falhou — a fundação segue"; return 0; }
  ok "Moltbot no ar: ${BOLD}http://${TSIP:-<ip-tailnet>}:18789${C0}"
  sub "gateway token oculto e salvo no arquivo de credenciais"
  sub "1º acesso: o browser vira device 'Pending' — aprove com:"
  sub "docker exec -it \$(docker ps -q -f name=moltbot_moltbot) clawdbot devices approve <requestId>"
  if [[ -n "$MOLT_TG" ]]; then
    sub "conectar o Telegram depois usando o token salvo no arquivo de credenciais"
    sub "depois: docker service update --force moltbot_moltbot (NUNCA docker restart)"
  fi
  cred ""; cred "Moltbot (gestão, só-tailnet): http://${TSIP:-<ip-tailnet>}:18789"
  cred "  gateway token (CONTROLE TOTAL — não compartilhar): ${GWTOK}"
  [[ -n "$MOLT_TG" ]] && cred "  bot Telegram: token informado (conectar via 'clawdbot channels add')" || true
}

# ── etapa 9: backup ──────────────────────────────────────────────────────────
backup_cron(){
  ETAPA="backup"
  local step=9
  [[ -n "$BASE_ONLY" ]] && step=8
  etapa "${step}/${TOTAL_STEPS}" "BACKUP" "dump do banco todo dia, desde o dia um"
  mkdir -p "${D}/var/backups/${SLUG}" "${D}/opt/${SLUG}"
  cat > "${D}/opt/${SLUG}/backup.sh" <<EOF
#!/usr/bin/env bash
# backup diário do banco do ${PROJ_NAME} (retenção 14 dias)
set -euo pipefail
CID=\$(docker ps -q -f name=${SLUG}_postgres | head -1)
[[ -n "\$CID" ]] || { echo "postgres fora do ar"; exit 1; }
DEST=/var/backups/${SLUG}
docker exec "\$CID" pg_dump -U postgres -d ${SLUG} | gzip > "\${DEST}/${SLUG}-\$(date +%F).sql.gz"
find "\$DEST" -name '${SLUG}-*.sql.gz' -mtime +14 -delete
EOF
  chmod +x "${D}/opt/${SLUG}/backup.sh"
  # /etc/cron.d em vez de 'crontab -': não depende de crontab pré-existente (VM/VPS virgem não tem)
  mkdir -p "${D}/etc/cron.d"
  printf '10 3 * * * root /opt/%s/backup.sh >> /var/log/%s-backup.log 2>&1\n' "$SLUG" "$SLUG" > "${D}/etc/cron.d/${SLUG}-backup"
  chmod 644 "${D}/etc/cron.d/${SLUG}-backup"
  if [[ "$DRY" != "--dry-run" ]]; then
    command -v cron >/dev/null 2>&1 || $APT install cron >/dev/null 2>&1 || true
    systemctl enable --now cron >/dev/null 2>&1 || true
    if "${D}/opt/${SLUG}/backup.sh" >/dev/null 2>&1; then
      local first_backup
      first_backup=$(find "${D}/var/backups/${SLUG}" -maxdepth 1 -name '*.sql.gz' -type f 2>/dev/null | sort | tail -1 || true)
      if [[ -n "$first_backup" ]] && gzip -t "$first_backup" 2>/dev/null; then
        ok "Primeiro backup local criado e validado"
      else
        warn "O primeiro backup não pôde ser validado"; sub "investigar: /opt/${SLUG}/backup.sh"
      fi
    else
      warn "O primeiro backup falhou"; sub "investigar: /opt/${SLUG}/backup.sh"
    fi
  fi
  ok "pg_dump diário às 03:10 → /var/backups/${SLUG}"
  sub "retenção 14 dias · agendado em /etc/cron.d/${SLUG}-backup"
  warn "backup LOCAL não salva de disco morto — rode também a blindagem com envio pra nuvem:"
  sub "bash <(curl -fsSL https://get.motobot.com.br/guard)"
}

# ── prova real: conferir que tudo REALMENTE subiu ────────────────────────────
prova_real(){
  ETAPA="prova real"
  [[ "$DRY" == "--dry-run" ]] && return 0
  say ""
  say "  ${CHIP} PROVA REAL ${C0} ${DIM}$(regua $((LARGURA-16)))${C0}"
  local esperados="traefik_traefik ${SLUG}_postgres ${SLUG}_redis portainer_portainer beszel_hub beszel_agent"
  [[ -n "${BASE_DOMAIN:-}" ]] && esperados="$esperados home_home"
  [[ "${CLTOK:-}" == sk-ant-oat* && -n "${BASE_DOMAIN:-}" && -n "${CFTOK:-}" && -n "${TSIP:-}" ]] && esperados="$esperados chat_chat"
  [[ -n "${RYZETOK:-}" && "${OAKEY:-}" == sk-* && -n "${BASE_DOMAIN:-}" && -n "${CFTOK:-}" ]] && esperados="$esperados wabot_wabot"
  [[ "$QUER_MOLT" =~ ^[sS] ]] && esperados="$esperados moltbot_moltbot"
  local tent=0 pendentes="" s rep have want
  while true; do
    pendentes=""
    for s in $esperados; do
      rep=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | awk -v s="$s" '$1==s{print $2}')
      have="${rep%%/*}"; want="${rep##*/}"; want="${want%% *}"
      [[ -n "$rep" && "$have" == "$want" && "$have" != "0" ]] || pendentes="$pendentes $s"
    done
    [[ -z "$pendentes" ]] && break
    tent=$((tent+1))
    [[ $tent -gt 18 ]] && break   # ~90s de paciência
    sleep 5
  done
  # LOGIN DE VERDADE nos painéis — é o que o aluno vai fazer; "serviço de pé" não basta
  if [[ -r /etc/motobase/portainer-admin.env ]]; then
    # shellcheck disable=SC1091
    source /etc/motobase/portainer-admin.env
    local nport; nport=$(docker ps --filter name=portainer_portainer -q 2>/dev/null | wc -l)
    if portainer_login_ok "${PORTAINER_ADMIN_PASSWORD:-}" && [[ "$nport" == "1" ]]; then
      ok "Portainer: login admin ${BOLD}OK${C0} ${DIM}(1 container, environment conectado)${C0}"
    else
      warn "Portainer: login do admin ${BOLD}FALHOU${C0} ${DIM}(containers: ${nport})${C0}"
      sub "rode o mesmo comando de novo — ele refaz o Portainer limpo e verifica"
    fi
  fi
  if [[ -r /etc/motobase/beszel-admin.env ]]; then
    # shellcheck disable=SC1091
    source /etc/motobase/beszel-admin.env
    local btok; btok=$(curl -s -m 6 -X POST -H 'content-type: application/json' \
      -d "{\"identity\":\"${BESZEL_ADMIN_EMAIL:-}\",\"password\":\"${BESZEL_ADMIN_PASSWORD:-}\"}" \
      "http://127.0.0.1:8090/api/collections/users/auth-with-password" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)
    if [[ -n "$btok" ]]; then ok "Beszel: login admin ${BOLD}OK${C0}"
    else warn "Beszel: login do admin ${BOLD}FALHOU${C0}"; sub "rode: bash <(curl -fsSL https://get.motobot.com.br) --repair-beszel"; fi
  fi
  for s in $esperados; do
    rep=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | awk -v s="$s" '$1==s{print $2}')
    have="${rep%%/*}"; want="${rep##*/}"; want="${want%% *}"
    if [[ -n "$rep" && "$have" == "$want" && "$have" != "0" ]]; then ok "${s} ${DIM}${rep}${C0}"
    else warn "${s} ainda não está de pé ${DIM}(${rep:-não existe})${C0}"; sub "investigar: docker service ps ${s} --no-trunc"
    fi
  done
  # banco responde e (se semente) tabelas existem
  local CID; CID=$(docker ps -q -f name="${SLUG}_postgres" | head -1)
  if [[ -n "$CID" ]] && docker exec "$CID" pg_isready -U postgres >/dev/null 2>&1; then
    local nt; nt=$(docker exec "$CID" psql -U postgres -d "${SLUG}" -tAc \
      "select count(*) from information_schema.tables where table_schema='${SLUG}'" 2>/dev/null | tr -d ' ')
    if [[ -n "$SEED" ]]; then ok "Banco respondendo ${DIM}${nt:-?} tabelas no schema ${SLUG}${C0}"
    else ok "Banco respondendo ${DIM}schema virgem, como planejado${C0}"
    fi
  else
    warn "banco não respondeu ao teste"; sub "investigar: docker service ps ${SLUG}_postgres"
  fi
  command -v claude >/dev/null && ok "Claude Code no PATH" || warn "Claude Code não encontrado no PATH"

  # ── SMOKE PONTA A PONTA: os endereços REALMENTE respondem? ────────────────
  # Bate em 127.0.0.1 com o Host certo: testa ROTA + MIDDLEWARE + BACKEND de uma
  # vez, sem depender de DNS propagar nem do Tailscale (source 127.0.0.1 passa no
  # tailnet-only). É o que impede o instalador de dizer "100%" sem ser verdade.
  _smoke_hit(){ curl -sk -m 8 -o /dev/null -w '%{http_code}' -H "Host: $1" "https://127.0.0.1${2:-/}" 2>/dev/null || echo 000; }
  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    local hc; hc=$(_smoke_hit "$BASE_DOMAIN" "/")
    [[ "$hc" == 200 ]] && ok "Home responde de verdade ${DIM}(HTTP $hc)${C0}" || { warn "Home NÃO responde ${DIM}(HTTP $hc)${C0}"; SMOKE_FALHAS=$((SMOKE_FALHAS+1)); }
  fi
  if docker service inspect chat_chat >/dev/null 2>&1; then
    local cc; cc=$(_smoke_hit "chat.${BASE_DOMAIN}" "/")
    [[ "$cc" =~ ^(200|304|401)$ ]] && ok "Chat responde de verdade ${DIM}(HTTP $cc · middleware ok)${C0}" || { warn "Chat NÃO responde ${DIM}(HTTP $cc — rota/middleware)${C0}"; SMOKE_FALHAS=$((SMOKE_FALHAS+1)); }
  fi
  if docker service inspect wabot_wabot >/dev/null 2>&1; then
    local pc; pc=$(_smoke_hit "bot-admin.${BASE_DOMAIN}" "/")
    [[ "$pc" == 200 ]] && ok "Pareamento do bot responde ${DIM}(HTTP $pc)${C0}" || { warn "Pareamento do bot NÃO responde ${DIM}(HTTP $pc)${C0}"; SMOKE_FALHAS=$((SMOKE_FALHAS+1)); }
    local wc; wc=$(_smoke_hit "bot.${BASE_DOMAIN}" "/webhook/wa")
    [[ "$wc" != 000 && "$wc" != 404 ]] && ok "Webhook do bot roteado ${DIM}(HTTP $wc)${C0}" || { warn "Webhook do bot NÃO roteado ${DIM}(HTTP $wc)${C0}"; SMOKE_FALHAS=$((SMOKE_FALHAS+1)); }
  fi
  if [[ "$SMOKE_FALHAS" -eq 0 ]]; then ok "${BOLD}Smoke de ponta a ponta: tudo respondeu${C0}"
  else warn "${BOLD}Smoke: ${SMOKE_FALHAS} verificação(ões) falharam${C0} — o resumo NÃO vai dizer 100%"; fi
}

# ── resumo ───────────────────────────────────────────────────────────────────
# Painel único de acessos: escreve /etc/motobase/acessos.txt com TODOS os links e
# portas certos (IP da tailnet pros painéis — não oscila; domínio pra home/chat/bot).
# O aluno nunca adivinha link nem porta: 'motobase acessos' relê este arquivo.
gerar_acessos_txt(){
  [[ "$DRY" == "--dry-run" ]] && return 0
  local f="${D}/etc/motobase/acessos.txt"; mkdir -p "${D}/etc/motobase"
  local chat_on="" bot_on=""
  [[ "${CLTOK:-}" == sk-ant-oat* && -n "${BASE_DOMAIN:-}" && -n "${CFTOK:-}" && -n "${TSIP:-}" ]] && chat_on=1
  [[ -n "${RYZETOK:-}" && "${OAKEY:-}" == sk-* && -n "${BASE_DOMAIN:-}" && -n "${CFTOK:-}" && -n "${TSIP:-}" ]] && bot_on=1
  {
    echo "ACESSOS — ${PROJ_NAME}"
    echo
    echo "PUBLICOS (abrem de qualquer lugar):"
    [[ -n "${BASE_DOMAIN:-}" ]] && printf '  Home ............. https://%s\n' "$BASE_DOMAIN"
    echo
    echo "PRIVADOS (so com o Tailscale LIGADO no seu computador):"
    printf '  Portainer ........ http://%s:9000      (gestao dos containers)\n' "${TSIP:-<ip-tailnet>}"
    printf '  Beszel ........... http://%s:8090      (saude da VPS)\n' "${TSIP:-<ip-tailnet>}"
    [[ -n "$chat_on" ]] && printf '  Chat Claude ...... https://chat.%s\n' "$BASE_DOMAIN"
    [[ -n "$bot_on" ]]  && printf '  Parear o bot ..... https://bot-admin.%s   (escaneie o QR)\n' "$BASE_DOMAIN"
    echo
    echo "LOGINS (o comando 'motobase acessos' mostra as senhas):"
    echo "  Portainer: usuario 'admin'"
    [[ -r "${D}/etc/motobase/beszel-admin.env" ]] && { # shellcheck disable=SC1090
      source "${D}/etc/motobase/beszel-admin.env"; printf "  Beszel:    e-mail '%s'\n" "${BESZEL_ADMIN_EMAIL:-}"; }
    [[ -n "$bot_on" ]] && echo "  Bot: pareie escaneando o QR (nao tem senha)"
    echo
    echo "Dica: se um endereco der 'DNS nao encontrado', espere 1-2 min (propagacao) e recarregue."
  } > "$f"
  chmod 600 "$f" 2>/dev/null || true
}

resumo(){
  ETAPA="resumo final"
  say ""
  if [[ "${SMOKE_FALHAS:-0}" -eq 0 ]]; then
    say "  ${GRN}$(regua $LARGURA)${C0}"
    say "  ${GRN}${BOLD}  ${PROJ_NAME^^} PRONTO — TUDO VERIFICADO, 100% NO AR${C0}"
    say "  ${GRN}$(regua $LARGURA)${C0}"
  else
    say "  ${AMB}$(regua $LARGURA)${C0}"
    say "  ${AMB}${BOLD}  ${PROJ_NAME^^} INSTALADO — ${SMOKE_FALHAS} PENDÊNCIA(S) A CONFERIR${C0}"
    say "  ${AMB}$(regua $LARGURA)${C0}"
    say "     ${DIM}veja os ▲ acima. rode ${BOLD}motobase reconciliar${C0}${DIM} (corrige DNS/IP) e depois recarregue.${C0}"
  fi
  say ""
  say "     ${DIM}domínio base ·${C0} ${BOLD}${BASE_DOMAIN}${C0}"
  if [[ -n "$APP_DOMAIN" ]]; then
    say "     ${DIM}projeto ······${C0} ${BOLD}https://${APP_DOMAIN}${C0} ${DIM}(no ar quando a sua app subir)${C0}"
  else
    say "     ${DIM}aplicação ····${C0} ${DIM}nenhuma criada — use o mesmo curl para criar um site ou WordPress${C0}"
  fi
  say "     ${DIM}banco ········${C0} ${SLUG}_postgres ${DIM}(db ${SLUG}, pgvector${SEED:+, schema '${SEED}'})${C0} · fila ${SLUG}_redis"
  say ""
  gerar_acessos_txt
  say "  ${CHIP} ACESSOS — abra e use ${C0}"
  say ""
  if [[ "$DRY" != "--dry-run" && -r "${D}/etc/motobase/acessos.txt" ]]; then
    while IFS= read -r _l; do say "     ${_l}"; done < "${D}/etc/motobase/acessos.txt"
  fi
  say ""
  say "       ${DIM}└ senhas: ${BOLD}motobase acessos${C0}${DIM} · isto tudo de novo a qualquer hora${C0}"
  say ""
  say "  ${CHIP} PRÓXIMO PASSO ${C0}"
  say ""
  say "     ${LRJ}${BOLD}cd /opt && claude${C0}"
  say "       ${DIM}└ o CLAUDE.md daqui já apresenta o servidor pra ele — é só mandar construir${C0}"
  say ""
  say "  ${CHIP} ACESSOS SIMPLES ${C0}"
  say ""
  say "     ${LRJ}${BOLD}motobase acessos${C0}"
  say "       ${DIM}└ usuário e senha do Portainer e do Beszel (admin já criado — sem setup-token)${C0}"
  say "     ${LRJ}${BOLD}motobase preparar-ssh${C0}"
  say "       ${DIM}└ prepara o acesso seguro; teste-o antes de usar 'motobase blindar-ssh'${C0}"
  say ""
  # || true: sob set -e, um [[ ]] falso como última linha da função derruba o script
  [[ "$DRY" == "--dry-run" ]] && warn "foi um dry-run: nada foi alterado no servidor (escritas em ${D})" || true
}

# Atalhos curtos para o aluno não precisar decorar comandos Docker nem caminhos.
motobase_helpers(){
  [[ "$DRY" == "--dry-run" ]] && return
  cat > /usr/local/bin/motobase <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-ajuda}" in
  reconciliar)
    exec bash <(curl -fsSL https://get.motobot.com.br) --reconcile
    ;;
  chat)
    exec bash <(curl -fsSL https://get.motobot.com.br) --repair-chat
    ;;
  acessos)
    [[ -r /etc/motobase/acessos.txt ]] && { cat /etc/motobase/acessos.txt; echo; echo "─── SENHAS ───"; }
    if [[ -r /etc/motobase/portainer-admin.env ]]; then
      # shellcheck disable=SC1091
      source /etc/motobase/portainer-admin.env
      printf 'Portainer  admin / %s\n' "$PORTAINER_ADMIN_PASSWORD"
    fi
    if [[ -r /etc/motobase/beszel-admin.env ]]; then
      # shellcheck disable=SC1091
      source /etc/motobase/beszel-admin.env
      printf 'Beszel     %s / %s\n' "$BESZEL_ADMIN_EMAIL" "$BESZEL_ADMIN_PASSWORD"
    fi
    [[ -r /etc/motobase/acessos.txt || -r /etc/motobase/portainer-admin.env ]] || { echo "Acessos não encontrados — a instalação terminou?" >&2; exit 1; }
    ;;
  preparar-ssh)
    [[ -s /root/.ssh/authorized_keys ]] || {
      echo "Não há chave pública em /root/.ssh/authorized_keys." >&2
      echo "Entre primeiro com uma chave SSH; por segurança, nada foi alterado." >&2
      exit 1
    }
    id -u mbadmin >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups sudo mbadmin
    install -d -m 700 -o mbadmin -g mbadmin /home/mbadmin/.ssh
    install -m 600 -o mbadmin -g mbadmin /root/.ssh/authorized_keys /home/mbadmin/.ssh/authorized_keys
    printf 'mbadmin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-motobase-admin
    chmod 440 /etc/sudoers.d/90-motobase-admin
    visudo -cf /etc/sudoers.d/90-motobase-admin >/dev/null
    host=$(tailscale ip -4 2>/dev/null | head -1 || true)
    echo "Acesso seguro preparado para o usuário: mbadmin"
    echo "Abra OUTRO terminal e teste antes de blindar:"
    echo "  ssh mbadmin@${host:-<ip-tailnet>}"
    echo "Depois do teste bem-sucedido, rode: motobase blindar-ssh"
    ;;
  blindar-ssh)
    [[ -s /home/mbadmin/.ssh/authorized_keys ]] || {
      echo "Primeiro rode 'motobase preparar-ssh' e teste a entrada como mbadmin." >&2; exit 1;
    }
    echo "Isto bloqueará senha, login SSH direto como root e SSH fora da Tailnet."
    read -r -p "Digite BLINDAR somente se você JÁ testou 'ssh mbadmin@<ip-tailnet>': " answer
    [[ "$answer" == BLINDAR ]] || { echo "Cancelado. Nada foi alterado."; exit 0; }
    install -d -m 755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-motobase-tailnet.conf <<'CONF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
    if ! sshd -t; then
      rm -f /etc/ssh/sshd_config.d/99-motobase-tailnet.conf
      echo "A configuração SSH falhou na validação; nada foi aplicado." >&2; exit 1
    fi
    cat > /usr/local/sbin/motobase-ssh-tailnet.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
iptables -N MOTOBASE-SSH-TAILNET 2>/dev/null || true
iptables -F MOTOBASE-SSH-TAILNET
iptables -A MOTOBASE-SSH-TAILNET -p tcp --dport 22 -s 100.64.0.0/10 -j ACCEPT
iptables -A MOTOBASE-SSH-TAILNET -p tcp --dport 22 -s 127.0.0.0/8 -j ACCEPT
iptables -A MOTOBASE-SSH-TAILNET -p tcp --dport 22 -j DROP
iptables -C INPUT -j MOTOBASE-SSH-TAILNET 2>/dev/null || iptables -I INPUT 1 -j MOTOBASE-SSH-TAILNET
SCRIPT
    chmod 700 /usr/local/sbin/motobase-ssh-tailnet.sh
    cat > /etc/systemd/system/motobase-ssh-tailnet.service <<'UNIT'
[Unit]
Description=Motobase - SSH somente pela Tailnet
After=tailscaled.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/motobase-ssh-tailnet.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now motobase-ssh-tailnet.service
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    echo "Blindagem concluída: entre apenas como 'mbadmin' pela Tailnet e use sudo quando precisar."
    ;;
  ajuda|-h|--help)
    cat <<'HELP'
Motobase — atalhos de acesso

  motobase acessos           Mostra usuário e senha do painel Beszel
  motobase preparar-ssh      Cria o usuário seguro mbadmin a partir da sua chave SSH
  motobase blindar-ssh       Desliga senha/root e libera SSH somente pela Tailnet (após testar mbadmin)
HELP
    ;;
  *)
    echo "Comando desconhecido. Use: motobase ajuda" >&2
    exit 2
    ;;
esac
EOF
  chmod 700 /usr/local/bin/motobase
}

registrar_base(){
  [[ "$DRY" == "--dry-run" || -z "$BASE_ONLY" ]] && return 0
  mkdir -p /etc/motobase /opt/projetos
  {
    printf 'BASE_NAME=%q\n' "$PROJ_NAME"
    printf 'BASE_SLUG=%q\n' "$SLUG"
    printf 'BASE_DOMAIN=%q\n' "$BASE_DOMAIN"
    printf 'LE_EMAIL=%q\n' "$LE_EMAIL"
    printf 'TAILSCALE_IP=%q\n' "${TSIP:-}"
    printf 'PORTAINER_URL=%q\n' "${PORTAINER_URL:-http://${TSIP:-}:9000}"
    printf 'BESZEL_URL=%q\n' "${BESZEL_URL:-http://${TSIP:-}:8090}"
    printf 'CERT_RESOLVER=%q\n' "le"
    printf 'INSTALLED_AT=%q\n' "$(date -Iseconds)"
  } > /etc/motobase/base.env
  chmod 600 /etc/motobase/base.env
  # token Cloudflare guardado root-only: permite reconciliar o DNS automaticamente
  # se a VPS trocar de IP, SEM o aluno re-colar nada (é a conta do dono da VPS).
  if [[ -n "${CFTOK:-}" ]]; then
    printf '%s' "$CFTOK" > /etc/motobase/cloudflare.token
    chmod 600 /etc/motobase/cloudflare.token
  fi
  touch /etc/motobase/projects.tsv
  chmod 600 /etc/motobase/projects.tsv
  motobase_helpers
  ok "Fundação registrada — nas próximas execuções este curl abre o gerenciador"
}

if [[ -n "$RECONCILE" ]]; then
  cred(){ :; }
  reconciliar
  exit 0
fi

if [[ -n "$REPAIR_CHAT" ]]; then
  [[ $EUID -eq 0 ]] || die "Rode como root: sudo -i"
  [[ -r /etc/motobase/base.env ]] || die "Sem /etc/motobase/base.env — a fundação não terminou. Rode o instalador."
  # shellcheck disable=SC1091
  source /etc/motobase/base.env
  PROJ_NAME="${BASE_NAME:-}"; SLUG="${BASE_SLUG:-}"; BASE_DOMAIN="${BASE_DOMAIN:-}"
  TSIP="${TAILSCALE_IP:-$(tailscale ip -4 2>/dev/null | head -1 || true)}"
  IP=$(curl -fsS -4 --max-time 8 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  CFTOK=""; [[ -r /etc/motobase/cloudflare.token ]] && CFTOK="$(</etc/motobase/cloudflare.token)"
  say ""; say "  ${CHIP} ADICIONAR O CHAT ${C0} ${DIM}liga o chat web no seu plano Max${C0}"; say ""
  sub "no SEU computador rode ${BOLD}claude setup-token${C0} e cole o token FINAL (sk-ant-oat…)"
  sub "ATENÇÃO: o código de autorização do navegador NÃO é o token — o token sai DEPOIS de colar o código de volta no terminal"
  ask_tok CLTOK "Setup-token do Claude (sk-ant-oat)" '^sk-ant-oat' "sk-ant-oat01-…"
  [[ "$CLTOK" == sk-ant-oat* ]] || die "Isso não é um setup-token (tem que começar com sk-ant-oat). Gere com 'claude setup-token'."
  [[ -n "$CFTOK" && -n "$BASE_DOMAIN" && -n "$TSIP" ]] || die "Faltam domínio base, token Cloudflare salvo ou tailnet — o chat precisa dos três."
  cred(){ :; }
  instalar_claude_chat
  say ""; ok "Pronto. Abra ${BOLD}https://chat.${BASE_DOMAIN}${C0} com o Tailscale ligado."
  exit 0
fi

if [[ -n "$REPAIR_BESZEL" ]]; then
  [[ $EUID -eq 0 ]] || die "Rode como root: sudo -i"
  if [[ -r /etc/motobase/base.env ]]; then
    # shellcheck disable=SC1091
    source /etc/motobase/base.env
    PROJ_NAME="$BASE_NAME"; SLUG="$BASE_SLUG"; APP_DOMAIN=""
    TSIP="${TAILSCALE_IP:-}"
  else
    # A instalação pode ter parado antes de registrar o estado final.
    SLUG=$(docker service ls --format '{{.Name}}' 2>/dev/null | sed -n 's/_postgres$//p' | head -1 || true)
    [[ -n "$SLUG" ]] || die "Não encontrei a base instalada para reparar o Beszel."
    PROJ_NAME="$SLUG"; APP_DOMAIN=""; LE_EMAIL=""
    TSIP=$(tailscale ip -4 2>/dev/null | head -1 || true)
  fi
  PORTAINER_URL="${PORTAINER_URL:-http://${TSIP}:9000}"
  BESZEL_URL="${BESZEL_URL:-http://${TSIP}:8090}"
  cred(){ :; }
  beszel_stack
  motobase_helpers
  exit 0
fi

banner
preflight
questionario

# ── acompanhamento ao vivo: quem não quer ficar no limbo abre outro terminal ──
if [[ "$DRY" != "--dry-run" ]]; then
  say ""
  say "  ${CHIP} AO VIVO ${C0} ${DIM}$(regua $((LARGURA-14)))${C0}"
  say "     Cada etapa mostra um ${LRJ}spinner${C0} com o tempo e a última linha do que roda."
  say "     Quer ver TUDO em tempo real? Abra ${BOLD}outro terminal${C0} na VPS e rode:"
  say "       ${LRJ}tail -f ${LOG}${C0}"
  say ""
fi

docker_swarm
traefik_stack
dados_stack
app_secrets
tailscale_gestao
claude_code
[[ -z "$BASE_ONLY" ]] && moltbot_stack
backup_cron
instalar_watchdog
prova_real
registrar_base
resumo
