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
  say "     ${DIM}o print da tela pra quem te deu este instalador.${C0}"
  say ""
}
trap on_err ERR

DRY=""; SEED=""; BASE_ONLY=""
while [[ $# -gt 0 ]]; do case "$1" in
  --dry-run) DRY="--dry-run" ;;
  --seed) SEED="${2:-}"; shift ;;
  --base) BASE_ONLY="1" ;;
  *) warn "argumento desconhecido: $1" ;;
esac; shift; done

D=""   # prefixo de escrita: em dry-run, NADA toca o disco real
if [[ "$DRY" == "--dry-run" ]]; then D=$(mktemp -d); fi
run(){
  if [[ "$DRY" == "--dry-run" ]]; then
    if [[ "$*" == *"docker secret create"* ]]; then
      local secret_name
      secret_name=$(printf '%s' "$*" | sed -nE 's/.*docker secret create ([^ ]+).*/\1/p')
      say "       ${DIM}[dry-run] criaria Docker secret ${secret_name:-protegido}${C0}"
    else
      say "       ${DIM}[dry-run] $*${C0}"
    fi
  else
    eval "$@"
  fi
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
  say "   ${DIM}por Rafael Ventura × Fable 5${SEED:+  ·  semente: ${SEED}}${C0}"
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
    warn "Este servidor JÁ tem Docker Swarm ativo."
    ask GOON "Continuar mesmo assim? Vou pular o que já existir (s/n)" "n"
    [[ "$GOON" =~ ^[sS] ]] || die "Abortado com segurança — nada foi alterado."
  fi

  # semente (se pedida): baixa ANTES de perguntar qualquer coisa — falha cedo
  SEED_DIR=""
  if [[ -n "$SEED" ]]; then
    SEED_DIR=$(mktemp -d)
    curl -fsSL "${RAW_BASE}/seeds/${SEED}/CLAUDE.md" -o "${SEED_DIR}/CLAUDE.md" 2>/dev/null \
      || die "Semente '${SEED}' não encontrada no repo (seeds/${SEED}/)."
    curl -fsSL "${RAW_BASE}/seeds/${SEED}/ddl.sql" -o "${SEED_DIR}/ddl.sql" 2>/dev/null || true
    ok "Semente ${BOLD}${SEED}${C0} baixada$([[ -f ${SEED_DIR}/ddl.sql ]] && echo ' (com schema de banco)')"
  fi
}

# cria/atualiza o registro A na Cloudflare (nuvem cinza) — falha vira aviso, nunca derruba
cf_dns_auto(){
  cf_dns_record "$APP_DOMAIN" "$IP" "público · DNS only para emissão do HTTPS"
}

cf_dns_record(){
  local record_domain="$1" target_ip="$2" purpose="${3:-DNS only}"
  if [[ "$DRY" == "--dry-run" ]]; then
    say "       ${DIM}[dry-run] criaria o registro A ${record_domain} → ${target_ip} na Cloudflare (${purpose})${C0}"
    return 0
  fi
  local api="https://api.cloudflare.com/client/v4"
  local hdr="Authorization: Bearer ${CFTOK}"
  info "Cloudflare: procurando a zona do domínio…"
  local d="$record_domain" zid=""
  while [[ "$d" == *.* ]]; do
    zid=$(curl -fsS -H "$hdr" "${api}/zones?name=${d}&status=active" 2>/dev/null | grep -oP '"id":"\K[a-f0-9]{32}' | head -1 || true)
    [[ -n "$zid" ]] && break
    d="${d#*.}"
  done
  if [[ -z "$zid" ]]; then
    warn "não achei a zona de ${record_domain} nessa conta"
    sub "confere se o token tem a zona certa; por enquanto, crie o registro A manualmente"
    return 0
  fi
  local rid; rid=$(curl -fsS -H "$hdr" "${api}/zones/${zid}/dns_records?type=A&name=${record_domain}" 2>/dev/null | grep -oP '"id":"\K[a-f0-9]{32}' | head -1 || true)
  local body="{\"type\":\"A\",\"name\":\"${record_domain}\",\"content\":\"${target_ip}\",\"ttl\":300,\"proxied\":false}"
  local sucesso=""
  if [[ -n "$rid" ]]; then
    sucesso=$(curl -fsS -X PUT -H "$hdr" -H 'Content-Type: application/json' -d "$body" "${api}/zones/${zid}/dns_records/${rid}" 2>/dev/null | grep -o '"success":true' || true)
  else
    sucesso=$(curl -fsS -X POST -H "$hdr" -H 'Content-Type: application/json' -d "$body" "${api}/zones/${zid}/dns_records" 2>/dev/null | grep -o '"success":true' || true)
  fi
  if [[ -n "$sucesso" ]]; then
    ok "Registro A ${BOLD}${record_domain}${C0} → ${target_ip} criado na Cloudflare"
    sub "${purpose}"
  else
    warn "a Cloudflare recusou a alteração"
    sub "o token tem permissão 'Zone.DNS Edit' nessa zona? crie o registro A manualmente"
  fi
}

# ── etapa 1: questionário — TUDO de uma vez, depois o script trabalha sozinho ─
questionario(){
  ETAPA="questionário"
  etapa "1/${TOTAL_STEPS}" "QUESTIONÁRIO" "responde tudo agora e vai tomar um café · Enter pula credencial"

  while true; do
    ask PROJ_NAME "Nome do projeto/startup"
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
  say "     ${BOLD}Cloudflare DNS${C0} ${DIM}— cria os subdomínios enquanto o restante instala${C0}"
  sub "conta nova: crie a conta, adicione o domínio e troque os nameservers no registrador"
  link "https://dash.cloudflare.com/sign-up"
  sub "espere o domínio aparecer como Active em Websites; depois crie o token abaixo"
  link "https://dash.cloudflare.com/"
  sub "My Profile → API Tokens → Create Token → modelo 'Edit zone DNS'"
  sub "Zone Resources: Include → Specific zone → selecione o domínio do cliente"
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

  BASE_DOMAIN=""; SUBDOMAIN=""
  if [[ -n "$CFTOK" ]]; then
    while true; do
      ask BASE_DOMAIN "Domínio principal na Cloudflare (ex: seusite.com.br)"
      BASE_DOMAIN=$(echo "$BASE_DOMAIN" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's|^https\?://||' -e 's|/.*$||' | tr -d ' ')
      [[ "$BASE_DOMAIN" == *.* && "$BASE_DOMAIN" != *..* \
        && "$BASE_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])$ ]] && break
      warn "digite o domínio principal da zona, como meusite.com.br"
    done
    while true; do
      ask SUBDOMAIN "Subdomínio personalizado desta VPS" "$SLUG"
      SUBDOMAIN=$(echo "$SUBDOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
      [[ "$SUBDOMAIN" != *..* && "$SUBDOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && break
      warn "use letras, números, pontos ou hífens, sem começar/terminar com hífen"
    done
    APP_DOMAIN="${SUBDOMAIN}.${BASE_DOMAIN}"
    info "endereço escolhido: ${BOLD}https://${APP_DOMAIN}${C0}"
    cf_dns_auto
  else
    while true; do
      ask APP_DOMAIN "Domínio completo do projeto (ex: app.seudominio.com.br)"
      APP_DOMAIN=$(echo "$APP_DOMAIN" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's|^https\?://||' -e 's|/.*$||' | tr -d ' ')
      [[ "$APP_DOMAIN" == *.* && "$APP_DOMAIN" != *..* \
        && "$APP_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])$ ]] && break
      warn "isso não parece um domínio (ex: app.meusite.com.br)"
    done
    caixa_abre
    caixa_txt "${BOLD}DNS NA MÃO, ENTÃO${C0}"
    caixa_txt ""
    caixa_txt "No painel do seu DNS, crie um registro tipo ${BOLD}A${C0} apontando"
    caixa_txt "${BOLD}${APP_DOMAIN}${C0} pro IP deste servidor: ${BOLD}${IP}${C0}"
    caixa_txt ""
    caixa_txt "${DIM}Na primeira emissão do HTTPS, deixe a nuvem CINZA (DNS only).${C0}"
    caixa_fecha
  fi

  local email_domain="${BASE_DOMAIN:-${APP_DOMAIN#*.}}"
  ask LE_EMAIL "E-mail pro certificado HTTPS (Let's Encrypt)" "admin@${email_domain}"
  [[ "$LE_EMAIL" == *@* ]] || { warn "e-mail sem @ — usando admin@${email_domain}"; LE_EMAIL="admin@${email_domain}"; }

  say ""
  say "     ${BOLD}Claude${C0} ${DIM}— opcional · o programador desta VPS${C0}"
  sub "jeito fácil: rode 'claude setup-token' no SEU computador e cole aqui"
  link "https://console.anthropic.com/settings/keys"
  ask_tok CLTOK "Token do Claude" '^sk-ant-' "sk-ant-oat01-… ou sk-ant-api03-…"

  say ""
  say "     ${BOLD}OpenAI${C0} ${DIM}— opcional · para aplicações que usam a API${C0}"
  sub "crie a conta, adicione faturamento e gere uma chave do projeto"
  link "https://platform.openai.com/settings/organization/billing/overview"
  link "https://platform.openai.com/api-keys"
  ask_tok OAKEY "Chave da OpenAI" '^sk-' "sk-proj-…"

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
  info "conferindo propagação de ${APP_DOMAIN}…"
  local resolved; resolved=$(getent hosts "$APP_DOMAIN" | awk '{print $1}' | head -1 || true)
  if [[ "$resolved" == "$IP" ]]; then ok "DNS propagado: ${APP_DOMAIN} → ${IP}"
  elif [[ -n "$resolved" ]]; then warn "${APP_DOMAIN} resolve pra ${resolved} (esperava ${IP})"; sub "se a nuvem laranja da Cloudflare está ligada, é normal"
  else warn "ainda não resolve"; sub "o HTTPS pode falhar na 1ª tentativa e se corrigir sozinho depois"
  fi

  # conferência final — errou algo? refaz sem dó
  local m
  say ""
  say "  ${DIM}$(regua $LARGURA)${C0}"
  say "     ${BOLD}CONFERE AÍ${C0}"
  say "       ${DIM}projeto ····${C0} ${PROJ_NAME}  ${DIM}(${SLUG})${C0}"
  say "       ${DIM}domínio ····${C0} https://${APP_DOMAIN}"
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
  cred "Projeto: https://${APP_DOMAIN}"
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
    run "apt-get update >/dev/null 2>&1 && apt-get install -y ca-certificates curl jq openssl >/dev/null 2>&1"
  fi
  if ! command -v docker >/dev/null; then
    info "instalando Docker (script oficial)…"
    run "curl -fsSL https://get.docker.com | sh >/dev/null 2>&1"
  fi
  ok "Docker $(docker --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo instalado)"
  if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]]; then
    run "docker swarm init --advertise-addr ${IP} >/dev/null"
  fi
  ok "Swarm ativo"
  sub "se um serviço cair, o Swarm sobe outro sozinho"
  docker network inspect web >/dev/null 2>&1 || run "docker network create -d overlay --attachable web >/dev/null"
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
  cat > "${D}/opt/traefik/stack.yml" <<EOF
version: "3.8"
services:
  traefik:
    image: traefik:v2.11
    command:
      - --providers.docker=true
      - --providers.docker.swarmMode=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=web
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --certificatesresolvers.le.acme.email=${LE_EMAIL}
      - --certificatesresolvers.le.acme.storage=/acme.json
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
    ports:
      # host mode: Traefik enxerga o IP REAL do cliente (sem isso, allowlist de IP não funciona)
      - { target: 80, published: 80, mode: host }
      - { target: 443, published: 443, mode: host }
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/traefik/acme.json:/acme.json
    networks: [web]
    deploy:
      placement: { constraints: [node.role == manager] }
      labels:
        # middleware pronto pra rotas de gestão: só tailnet (100.64/10) e localhost passam
        - traefik.http.middlewares.tailnet-only.ipwhitelist.sourcerange=127.0.0.1/32,100.64.0.0/10
networks:
  web: { external: true }
EOF
  run "docker stack deploy --detach=true -c /opt/traefik/stack.yml traefik >/dev/null 2>&1"
  ok "Traefik no ar"
  sub "certificado Let's Encrypt emitido sozinho quando o domínio apontar pra cá"
}

# ── etapa 4: banco + redis (CRUS — schema é com você e o Claude) ─────────────
dados_stack(){
  ETAPA="banco de dados"
  etapa "4/${TOTAL_STEPS}" "DADOS" "Postgres com pgvector + Redis, fora do alcance da internet"
  local PGP; PGP=$(pw)
  if ! docker secret inspect "${SLUG}_pg_password" >/dev/null 2>&1; then
    swarm_secret "${SLUG}_pg_password" "$PGP"
  else
    warn "secret ${SLUG}_pg_password já existe — mantendo a senha atual"
    PGP="(já existia — veja o registro anterior)"
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
  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes
    volumes: [redisdata:/data]
    networks: [internal]
networks:
  internal: { driver: overlay, attachable: true }
secrets:
  ${SLUG}_pg_password: { external: true }
volumes: { pgdata: {}, redisdata: {} }
EOF
  run "docker stack deploy --detach=true -c /opt/${SLUG}/stack.yml ${SLUG} >/dev/null 2>&1"
  ok "Postgres ${BOLD}${SLUG}_postgres${C0} · Redis ${BOLD}${SLUG}_redis${C0}"
  sub "rede interna '${SLUG}_internal' — banco e redis não ficam expostos na web"
  cred ""; cred "Postgres: host ${SLUG}_postgres:5432  db ${SLUG}  user postgres"
  cred "  senha: ${PGP}  (fonte de verdade: docker secret ${SLUG}_pg_password)"
  cred "Redis: host ${SLUG}_redis:6379 (rede interna, sem senha)"
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
    until CID=$(docker ps -q -f name="${SLUG}_postgres" | head -1) && [[ -n "$CID" ]] \
      && docker exec "$CID" pg_isready -U postgres >/dev/null 2>&1; do
      i=$((i+1)); [[ $i -gt 60 ]] && die "Postgres não subiu em 2 minutos — rode o comando de novo; se repetir, veja: docker service ps ${SLUG}_postgres"
      sleep 2
    done
    docker exec "$CID" psql -U postgres -d "${SLUG}" -c "create extension if not exists vector;" >/dev/null
    if [[ -n "$SEED" && -f "${SEED_DIR}/ddl.sql" ]]; then
      sed "s/{{SLUG}}/${SLUG}/g" "${SEED_DIR}/ddl.sql" > "/opt/${SLUG}/ddl.sql"
      docker exec -i "$CID" psql -U postgres -d "${SLUG}" -v ON_ERROR_STOP=1 < "/opt/${SLUG}/ddl.sql" >/dev/null
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
    run "curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1"
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
    TSIP=$(tailscale ip -4 2>/dev/null | head -1)
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

  # Portainer: publicado APENAS na porta 9000 host-mode, travado no firewall pra tailnet
  mkdir -p "${D}/opt/${SLUG}" "${D}/usr/local/sbin" "${D}/etc/systemd/system"
  cat > "${D}/opt/${SLUG}/portainer.yml" <<'EOF'
version: "3.8"
services:
  agent:
    image: portainer/agent:latest
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks: [agent]
    deploy: { mode: global }
  portainer:
    image: portainer/portainer-ce:latest
    command: -H tcp://tasks.agent:9001 --tlsskipverify
    volumes: [pdata:/data]
    networks: [agent]
    ports:
      - { target: 9000, published: 9000, mode: host }
    deploy:
      placement: { constraints: [node.role == manager] }
networks:
  agent: { driver: overlay, attachable: true }
volumes:
  pdata:
EOF
  run "docker stack deploy --detach=true -c /opt/${SLUG}/portainer.yml portainer >/dev/null 2>&1"

  # Porta publicada pelo Docker IGNORA o ufw — o trinco de verdade é na chain
  # DOCKER-USER, e precisa sobreviver a reboot (script + unit systemd).
  cat > "${D}/usr/local/sbin/gestao-lockdown.sh" <<'EOF'
#!/usr/bin/env bash
# Trava portas de GESTÃO pra aceitarem só tailnet (100.64/10) e localhost.
set -e
PORTS="9000 8090 18789"   # 9000=Portainer · 8090=Beszel · 18789=moltbot
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
  run "systemctl daemon-reload && systemctl enable --now gestao-lockdown.service >/dev/null 2>&1"
  ok "Firewall de gestão ativo ${DIM}(persistente a reboot)${C0}"
  sub "do IP público as portas 9000/8090/18789 nem respondem — só pela tailnet"

  # Portainer novo pode exigir um setup token. Não o imprimimos automaticamente
  # para que instalações gravadas nunca exponham credenciais na tela.
  [[ "$DRY" != "--dry-run" ]] && sleep 8
  ok "Portainer: ${BOLD}${PORTAINER_URL}${C0}"
  sub "crie o admin em ATÉ 5 MIN — expirou? docker service update --force portainer_portainer"
  sub "se pedir 'setup token': docker service logs portainer_portainer 2>&1 | grep -i token"
  cred ""; cred "Portainer (gestão, só-tailnet): ${PORTAINER_URL}"
  cred "IP tailnet do servidor: ${TSIP}"

  beszel_stack
}

# ── Beszel: painel leve de CPU, RAM, disco, rede e containers ─────────────────
beszel_stack(){
  ETAPA="Beszel"
  local version="0.18.8" dir="${D}/opt/${SLUG}/beszel"
  local admin_file="${D}/etc/motobase/beszel-admin.env"
  local admin_email="${LE_EMAIL}" admin_password="" auth="" key="" token=""
  mkdir -p "$dir" "${D}/etc/motobase"

  if [[ -r "$admin_file" ]]; then
    # shellcheck disable=SC1090
    source "$admin_file"
    admin_email="${BESZEL_ADMIN_EMAIL:-$admin_email}"
    admin_password="${BESZEL_ADMIN_PASSWORD:-}"
  fi
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
    i=$((i+1)); [[ $i -gt 30 ]] && die "Beszel Hub não respondeu em 90 segundos — veja: docker service ps beszel_hub"
    sleep 3
  done

  if ! docker secret inspect beszel_agent_key >/dev/null 2>&1 \
    || ! docker secret inspect beszel_agent_token >/dev/null 2>&1; then
    auth=$(curl -fsS --max-time 10 -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg identity "$admin_email" --arg password "$admin_password" \
        '{identity:$identity,password:$password}')" \
      "http://127.0.0.1:8090/api/collections/users/auth-with-password" | jq -r '.token // empty')
    [[ -n "$auth" ]] || die "Beszel não aceitou o login automático. Credenciais preservadas em /etc/motobase/beszel-admin.env."
    key=$(curl -fsS --max-time 10 -H "Authorization: ${auth}" \
      "http://127.0.0.1:8090/api/beszel/getkey" | jq -r '.key // empty')
    token=$(curl -fsS --max-time 10 -H "Authorization: ${auth}" \
      "http://127.0.0.1:8090/api/beszel/universal-token?enable=1" | jq -r '.token // empty')
    [[ -n "$key" && -n "$token" ]] || die "Beszel não forneceu a chave de registro do Agent. Rode o instalador novamente."
    docker secret inspect beszel_agent_key >/dev/null 2>&1 \
      || printf '%s' "$key" | docker secret create beszel_agent_key - >/dev/null
    docker secret inspect beszel_agent_token >/dev/null 2>&1 \
      || printf '%s' "$token" | docker secret create beszel_agent_token - >/dev/null
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
    | jq -e --arg name "$SLUG" 'any(.items[]; .name == $name)' >/dev/null 2>&1; do
    i=$((i+1)); [[ $i -gt 20 ]] && die "Beszel Agent iniciou, mas não apareceu no painel em 60 segundos — veja: docker service logs beszel_agent"
    sleep 3
  done
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

# ── etapa 7: claude code — o programador mora aqui ───────────────────────────
claude_code(){
  ETAPA="Claude Code"
  etapa "7/${TOTAL_STEPS}" "CLAUDE CODE" "o programador desta VPS, pronto pra receber ordens"
  if ! command -v node >/dev/null || [[ "$(node -v 2>/dev/null | grep -oP '\d+' | head -1)" -lt 20 ]]; then
    info "instalando Node.js 22 (NodeSource)…"
    run "curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 && apt-get install -y nodejs >/dev/null 2>&1"
  fi
  ok "Node $(node -v 2>/dev/null || echo '(dry-run)')"

  # git + gh: FERRAMENTA de versionamento. A credencial NÃO é pedida aqui —
  # 'gh auth login' faz login pelo navegador (device flow), sem colar segredo no terminal.
  if ! command -v git >/dev/null || ! command -v gh >/dev/null; then
    info "instalando git e GitHub CLI…"
    run "apt-get install -y git >/dev/null 2>&1 || true"
    if ! command -v gh >/dev/null; then
      run "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1 \
        && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && echo 'deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list \
        && apt-get update >/dev/null 2>&1 && apt-get install -y gh >/dev/null 2>&1 || true"
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
    run "npm install -g @anthropic-ai/claude-code >/dev/null 2>&1" \
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
- Redis: \`${SLUG}_redis\` (cache/filas/sessões, AOF ligado).
- Saúde: Beszel em \`${BESZEL_URL:-http://<ip-tailnet>:8090}\` (CPU, RAM, disco, rede e containers; só-tailnet).
- Secrets no Swarm (fonte única, NUNCA copiar valor em texto plano): ${SLUG}_pg_password,
  ${SLUG}_jwt_secret${TGTOK:+, ${SLUG}_tg_token}${OAKEY:+, ${SLUG}_openai_key}. Ler em runtime via /run/secrets/.
- App: template pronto em /opt/${SLUG}/app.yml (imagem \`${SLUG}-api\`, porta 3000,
  host ${APP_DOMAIN}); deploy: \`docker stack deploy -c /opt/${SLUG}/app.yml ${SLUG}-app\`.
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
  run "docker stack deploy --detach=true -c /opt/${SLUG}/moltbot.yml moltbot >/dev/null 2>&1"
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
    command -v cron >/dev/null 2>&1 || apt-get install -y cron >/dev/null 2>&1 || true
    systemctl enable --now cron >/dev/null 2>&1 || true
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
  local esperados="traefik_traefik ${SLUG}_postgres ${SLUG}_redis portainer_portainer portainer_agent beszel_hub beszel_agent"
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
}

# ── resumo ───────────────────────────────────────────────────────────────────
resumo(){
  ETAPA="resumo final"
  say ""
  say "  ${GRN}$(regua $LARGURA)${C0}"
  say "  ${GRN}${BOLD}  FUNDAÇÃO DO ${PROJ_NAME^^} PRONTA${C0}"
  say "  ${GRN}$(regua $LARGURA)${C0}"
  say ""
  say "     ${DIM}projeto ······${C0} ${BOLD}https://${APP_DOMAIN}${C0} ${DIM}(no ar quando a sua app subir)${C0}"
  say "     ${DIM}gestão ·······${C0} ${BOLD}${PORTAINER_URL:-http://<ip-tailnet>:9000}${C0} ${DIM}(Portainer — só com Tailscale)${C0}"
  say "     ${DIM}saúde ········${C0} ${BOLD}${BESZEL_URL:-http://<ip-tailnet>:8090}${C0} ${DIM}(Beszel — só com Tailscale)${C0}"
  say "     ${DIM}banco ········${C0} ${SLUG}_postgres ${DIM}(db ${SLUG}, pgvector${SEED:+, schema '${SEED}'})${C0}"
  say "     ${DIM}fila/sessão ··${C0} ${SLUG}_redis"
  say "     ${DIM}credenciais ··${C0} ${BOLD}/root/${SLUG}-credenciais.txt${C0}"
  say "       ${DIM}└ chmod 600 — anote num gerenciador de senhas e apague o arquivo${C0}"
  say ""
  say "  ${CHIP} PRÓXIMO PASSO ${C0}"
  say ""
  say "     ${LRJ}${BOLD}cd /opt && claude${C0}"
  say "       ${DIM}└ o CLAUDE.md daqui já apresenta o servidor pra ele — é só mandar construir${C0}"
  say ""
  # || true: sob set -e, um [[ ]] falso como última linha da função derruba o script
  [[ "$DRY" == "--dry-run" ]] && warn "foi um dry-run: nada foi alterado no servidor (escritas em ${D})" || true
}

registrar_base(){
  [[ "$DRY" == "--dry-run" || -z "$BASE_ONLY" ]] && return 0
  mkdir -p /etc/motobase /opt/projetos
  {
    printf 'BASE_NAME=%q\n' "$PROJ_NAME"
    printf 'BASE_SLUG=%q\n' "$SLUG"
    printf 'BASE_DOMAIN=%q\n' "$APP_DOMAIN"
    printf 'LE_EMAIL=%q\n' "$LE_EMAIL"
    printf 'TAILSCALE_IP=%q\n' "${TSIP:-}"
    printf 'PORTAINER_URL=%q\n' "${PORTAINER_URL:-http://${TSIP:-}:9000}"
    printf 'BESZEL_URL=%q\n' "${BESZEL_URL:-http://${TSIP:-}:8090}"
    printf 'CERT_RESOLVER=%q\n' "le"
    printf 'INSTALLED_AT=%q\n' "$(date -Iseconds)"
  } > /etc/motobase/base.env
  chmod 600 /etc/motobase/base.env
  touch /etc/motobase/projects.tsv
  chmod 600 /etc/motobase/projects.tsv
  ok "Fundação registrada — nas próximas execuções este curl abre o gerenciador"
}

banner
preflight
questionario
docker_swarm
traefik_stack
dados_stack
app_secrets
tailscale_gestao
claude_code
[[ -z "$BASE_ONLY" ]] && moltbot_stack
backup_cron
prova_real
registrar_base
resumo
