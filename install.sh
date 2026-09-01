#!/usr/bin/env bash
# =============================================================================
#  MOTOBASE — do zero à base da sua startup, em uma linha.
#
#  bash <(curl -fsSL https://get.motobot.com.br)
#
#  Primeira execução: instala a fundação pela vibe.sh em modo --base.
#  Próximas execuções: abre o gerenciador para criar projetos independentes.
# =============================================================================
set -Eeuo pipefail

# nenhum diálogo pode aparecer numa instalação de servidor: sem alguém pra
# responder, o apt trava em silêncio e a instalação morre sem explicação.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none
APT="apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

RAW_BASE="https://raw.githubusercontent.com/rafzinn/motobase/main"
STATE_REAL="/etc/motobase"
PROJECTS_REAL="/opt/projetos"
DRY=""
ACTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --status) ACTION="status" ;;
    --repair-beszel) ACTION="repair-beszel" ;;
    --site) ACTION="site" ;;
    --wordpress) ACTION="wordpress" ;;
    --help|-h) ACTION="help" ;;
    *) printf 'Argumento desconhecido: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$DRY" ]]; then
  DRY_ROOT=$(mktemp -d)
  STATE_DIR="${DRY_ROOT}${STATE_REAL}"
  PROJECTS_DIR="${DRY_ROOT}${PROJECTS_REAL}"
  CRON_DIR="${DRY_ROOT}/etc/cron.d"
  BACKUPS_DIR="${DRY_ROOT}/var/backups"
else
  STATE_DIR="$STATE_REAL"
  PROJECTS_DIR="$PROJECTS_REAL"
  CRON_DIR="/etc/cron.d"
  BACKUPS_DIR="/var/backups"
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C0='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
  ORANGE='\033[38;5;173m'; AMBER='\033[38;5;179m'
  GREEN='\033[38;5;108m'; RED='\033[38;5;203m'
else
  C0=''; BOLD=''; DIM=''; ORANGE=''; AMBER=''; GREEN=''; RED=''
fi

say(){ printf '%b\n' "$*"; }
ok(){ say "  ${GREEN}✓${C0} $*"; }
info(){ say "  ${DIM}·${C0} $*"; }
warn(){ say "  ${AMBER}▲${C0} $*"; }
die(){ say "\n  ${RED}✗ $*${C0}\n" >&2; exit 1; }
pw(){ openssl rand -base64 24 | tr -d '/+=' | head -c 28; }

run(){
  if [[ -n "$DRY" ]]; then
    say "  ${DIM}[simulação] $*${C0}"
  else
    "$@"
  fi
}

ask(){
  local target="$1" prompt="$2" default="${3:-}" input_value=""
  read -r -p "$(printf '%b' "  ${ORANGE}?${C0} ${prompt}${default:+ ${DIM}[${default}]${C0}}: ")" input_value || true
  printf -v "$target" '%s' "${input_value:-$default}"
}

read_masked(){ # $1=prompt; resultado em REPLY
  local prompt="$1" char value=""
  printf '%b' "  ${ORANGE}?${C0} ${prompt} ${DIM}(cole aqui · Enter pula)${C0}: " >&2
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

ask_secret(){
  local target="$1" prompt="$2" input_value=""
  read_masked "$prompt"
  input_value="$REPLY"
  printf -v "$target" '%s' "$input_value"
}

ask_token(){
  local target="$1" prompt="$2" input_value=""
  read_masked "$prompt"
  input_value="$REPLY"
  input_value="${input_value//$'\r'/}"; input_value="${input_value//$'\n'/}"
  input_value="${input_value//$'\t'/}"; input_value="${input_value// /}"
  input_value="${input_value//$'\u00A0'/}"; input_value="${input_value//$'\u200B'/}"
  printf -v "$target" '%s' "$input_value"
}

confirm(){
  local prompt="$1" default="${2:-s}" answer
  ask answer "$prompt (s/n)" "$default"
  [[ "$answer" =~ ^[sS]$ ]]
}

slugify(){
  local value="$1"
  value=$(printf '%s' "$value" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$value")
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g')
  printf '%.32s' "$value"
}

normalize_domain(){
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g'
}

banner(){
  say ""
  say "${ORANGE} ███╗   ███╗ ██████╗ ████████╗ ██████╗ ██████╗  █████╗ ███████╗███████╗${C0}"
  say "${ORANGE} ████╗ ████║██╔═══██╗╚══██╔══╝██╔═══██╗██╔══██╗██╔══██╗██╔════╝██╔════╝${C0}"
  say "${ORANGE} ██╔████╔██║██║   ██║   ██║   ██║   ██║██████╔╝███████║███████╗█████╗  ${C0}"
  say "${ORANGE} ██║╚██╔╝██║██║   ██║   ██║   ██║   ██║██╔══██╗██╔══██║╚════██║██╔══╝  ${C0}"
  say "${ORANGE} ██║ ╚═╝ ██║╚██████╔╝   ██║   ╚██████╔╝██████╔╝██║  ██║███████║███████╗${C0}"
  say "${ORANGE} ╚═╝     ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝${C0}"
  say ""
  say "          ${BOLD}DO ZERO À BASE DA SUA STARTUP. EM UMA LINHA.${C0}"
  say "       ${DIM}Infra pronta para criar, publicar e crescer sem bagunça.${C0}"
  say "       ${DIM}por Rafael Ventura · ${C0}${ORANGE}rafaelventura.com.br${C0}${DIM} · ${C0}${ORANGE}github.com/rafzinn${C0}"
  say ""
}

help_text(){
  cat <<'EOF'
Uso:
  bash <(curl -fsSL https://get.motobot.com.br)
  bash <(curl -fsSL https://get.motobot.com.br) --status
  bash <(curl -fsSL https://get.motobot.com.br) --repair-beszel
  bash <(curl -fsSL https://get.motobot.com.br) --site
  bash <(curl -fsSL https://get.motobot.com.br) --wordpress

O primeiro uso instala a fundação. Os demais abrem o gerenciador.
EOF
}

docker_service_exists(){
  command -v docker >/dev/null 2>&1 &&
    docker service ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"
}

foundation_present(){
  [[ -f "${STATE_REAL}/base.env" ]] && return 0
  docker_service_exists traefik_traefik && docker_service_exists portainer_portainer
}

load_state(){
  BASE_NAME="Motobase"; BASE_SLUG="motobase"; BASE_DOMAIN=""; LE_EMAIL=""; PORTAINER_URL=""
  TAILSCALE_IP=""; CERT_RESOLVER="le"
  if [[ -f "${STATE_REAL}/base.env" ]]; then
    # shellcheck disable=SC1091
    source "${STATE_REAL}/base.env"
  else
    BASE_SLUG=$(docker service ls --format '{{.Name}}' 2>/dev/null | sed -n 's/_postgres$//p' | head -1 || true)
    BASE_SLUG="${BASE_SLUG:-motobase}"
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
    if docker network inspect web >/dev/null 2>&1; then
      CERT_RESOLVER="letsencryptresolver"
    fi
  fi
  # Instalações antigas guardavam o endereço de uma app em BASE_DOMAIN. O painel
  # Portainer sempre usa portainer.<domínio-base>, então ele recupera a raiz sem
  # exigir nenhuma migração manual do aluno.
  local portainer_host="${PORTAINER_URL#http://}"
  portainer_host="${portainer_host#https://}"
  portainer_host="${portainer_host%%/*}"
  portainer_host="${portainer_host%%:*}"
  [[ "$portainer_host" == portainer.* ]] && BASE_DOMAIN="${portainer_host#portainer.}"
  return 0
}

install_foundation(){
  say "  ${BOLD}PRIMEIRA EXECUÇÃO${C0}"
  say "  A fundação ainda não foi instalada nesta VPS."
  say ""
  info "Será instalado: Swarm, Traefik, Portainer, Beszel, PostgreSQL + pgvector, Redis, Tailscale e backup."
  say ""
  confirm "Começar a instalação da fundação?" "s" || return 0
  local args=(--base)
  [[ -n "$DRY" ]] && args+=(--dry-run)
  bash "$(motor)" "${args[@]}"
}

# Baixar com <(curl) é perigoso: se a conexão cai no meio, o bash executa um
# script PELA METADE. Aqui o download é insistente, gravado em disco e validado
# sintaticamente antes de rodar — download truncado nunca chega a executar.
ETAPA_IS="preparação"
on_err_is(){
  say ""
  say "  ${RED:-}✗ O gerenciador parou em: ${ETAPA_IS}${C0:-}"
  say "     Rode o MESMO comando de novo — nada foi perdido e ele continua do ponto certo."
  say "     Se repetir, o log da fundação fica em /var/log/motobase-instalacao.log"
  say ""
}
trap on_err_is ERR

motor(){
  local dest; dest=$(mktemp)
  curl -fsSL --connect-timeout 15 --max-time 180 --retry 4 --retry-delay 3 --retry-connrefused \
    "${RAW_BASE}/vibe.sh" -o "$dest" 2>/dev/null \
    || die "Não consegui baixar o instalador. Confira a internet da VPS e rode o comando de novo."
  [[ -s "$dest" ]] || die "O instalador veio vazio no download. Rode o comando de novo."
  bash -n "$dest" 2>/dev/null \
    || die "O download do instalador foi interrompido e veio incompleto. Rode o comando de novo."
  printf '%s' "$dest"
}

ensure_root(){
  [[ $EUID -eq 0 ]] || die "Rode como root: sudo -i"
}

ensure_edge_network(){
  if ! docker network inspect web >/dev/null 2>&1; then
    run docker network create --driver overlay --attachable web >/dev/null
  fi
}

get_public_ip(){
  curl -fsS -4 --max-time 8 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

cloudflare_token(){
  local token_file="/root/.config/cloudflare/token" token=""
  [[ -r "$token_file" ]] && token=$(<"$token_file")
  if [[ -z "$token" ]]; then
    ask_token token "Token Cloudflare para criar o DNS automaticamente"
    if [[ -n "$token" && -z "$DRY" ]]; then
      install -d -m 700 /root/.config/cloudflare
      printf '%s\n' "$token" > "$token_file"
      chmod 600 "$token_file"
    fi
  fi
  printf '%s' "$token"
}

cf_record(){
  local domain="$1" token="$2"
  [[ -z "$token" ]] && { warn "DNS não automatizado: crie um registro A para ${domain}."; return 0; }
  [[ -n "$DRY" ]] && { info "Criaria DNS A ${domain} → IP da VPS"; return 0; }

  local ip api zone candidate zid rid body result
  ip=$(get_public_ip); api="https://api.cloudflare.com/client/v4"; candidate="$domain"; zid=""
  while [[ "$candidate" == *.* ]]; do
    zid=$(curl -fsS --max-time 12 -H "Authorization: Bearer ${token}" \
      "${api}/zones?name=${candidate}&status=active" 2>/dev/null | jq -r '.result[0].id // empty' || true)
    [[ -n "$zid" ]] && { zone="$candidate"; break; }
    candidate="${candidate#*.}"
  done
  [[ -n "$zid" ]] || { warn "Cloudflare: zona de ${domain} não encontrada; configure o DNS manualmente."; return 0; }

  rid=$(curl -fsS --max-time 12 -H "Authorization: Bearer ${token}" \
    "${api}/zones/${zid}/dns_records?type=A&name=${domain}" 2>/dev/null | jq -r '.result[0].id // empty' || true)
  body=$(printf '{"type":"A","name":"%s","content":"%s","ttl":300,"proxied":false}' "$domain" "$ip")
  if [[ -n "$rid" ]]; then
    result=$(curl -fsS --max-time 12 -X PUT -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' --data "$body" "${api}/zones/${zid}/dns_records/${rid}" 2>/dev/null || true)
  else
    result=$(curl -fsS --max-time 12 -X POST -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' --data "$body" "${api}/zones/${zid}/dns_records" 2>/dev/null || true)
  fi
  [[ $(printf '%s' "$result" | jq -r '.success // false' 2>/dev/null) == true ]] \
    && ok "DNS: ${domain} → ${ip}" \
    || warn "Cloudflare recusou o DNS de ${domain}; crie o registro A manualmente na zona ${zone}."
}

register_project(){
  local slug="$1" type="$2" domain="$3" stack="$4"
  mkdir -p "$STATE_DIR"
  local registry="${STATE_DIR}/projects.tsv"
  touch "$registry"; chmod 600 "$registry"
  if ! awk -F '\t' -v s="$slug" '$1==s{found=1} END{exit !found}' "$registry"; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$type" "$domain" "$stack" "$(date -Iseconds)" >> "$registry"
  fi
}

wait_service(){
  local service="$1" attempts=0 replicas have want
  [[ -n "$DRY" ]] && return 0
  while (( attempts < 24 )); do
    replicas=$(docker service ls --filter "name=${service}" --format '{{.Name}} {{.Replicas}}' 2>/dev/null | awk -v s="$service" '$1==s{print $2}')
    have="${replicas%%/*}"; want="${replicas##*/}"
    [[ -n "$replicas" && "$have" == "$want" && "$have" != 0 ]] && return 0
    attempts=$((attempts+1)); sleep 5
  done
  return 1
}

https_smoke(){
  local domain="$1" code=""
  [[ -n "$DRY" ]] && { ok "HTTPS seria testado em https://${domain}"; return 0; }
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "https://${domain}/" 2>/dev/null || true)
  [[ "$code" =~ ^(200|301|302|303|307|308)$ ]] \
    && ok "HTTPS respondeu em ${domain} (${code})" \
    || warn "${domain} ainda não respondeu por HTTPS (${code:-sem resposta}); DNS/certificado pode estar propagando."
}

project_questions(){
  local kind="$1" suggested_domain
  while true; do
    ask PROJECT_NAME "Nome do ${kind}"
    PROJECT_SLUG=$(slugify "$PROJECT_NAME")
    [[ "$PROJECT_SLUG" =~ ^[a-z][a-z0-9-]*$ ]] && break
    warn "Use um nome com letras."
  done
  suggested_domain="${PROJECT_SLUG}.${BASE_DOMAIN}"
  while true; do
    ask PROJECT_DOMAIN "Endereço do ${kind}" "$suggested_domain"
    PROJECT_DOMAIN=$(normalize_domain "$PROJECT_DOMAIN")
    [[ "$PROJECT_DOMAIN" == *.* && "$PROJECT_DOMAIN" != *..* \
      && "$PROJECT_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])$ ]] && break
    warn "Digite um domínio válido, como site.exemplo.com.br."
  done
  ask USE_WWW "Publicar também em www.${PROJECT_DOMAIN}? (s/n)" "n"
}

project_guard(){
  local wanted_type="$1" registry="${STATE_REAL}/projects.tsv" row_slug row_type row_domain rest
  [[ -s "$registry" ]] || return 0
  while IFS=$'\t' read -r row_slug row_type row_domain rest; do
    if [[ "$row_slug" == "$PROJECT_SLUG" && "$row_type" != "$wanted_type" ]]; then
      die "O identificador ${PROJECT_SLUG} já pertence a um projeto ${row_type}. Escolha outro nome."
    fi
    if [[ "$row_domain" == "$PROJECT_DOMAIN" && "$row_slug" != "$PROJECT_SLUG" ]]; then
      die "O domínio ${PROJECT_DOMAIN} já pertence ao projeto ${row_slug}."
    fi
  done < "$registry"
}

install_project_cron(){
  local slug="$1" script="$2"
  mkdir -p "$CRON_DIR"
  printf '25 3 * * * root %s >> /var/log/%s-backup.log 2>&1\n' "$script" "$slug" \
    > "${CRON_DIR}/motobase-${slug}-backup"
  chmod 644 "${CRON_DIR}/motobase-${slug}-backup"
  if [[ -z "$DRY" ]]; then
    command -v cron >/dev/null 2>&1 || $APT install cron >/dev/null 2>&1
    systemctl enable --now cron >/dev/null 2>&1 || true
  fi
}

setup_static_backup(){
  local slug="$1" dir="$2" backup_dir
  backup_dir="${BACKUPS_DIR}/${slug}"
  mkdir -p "$backup_dir"
  cat > "${dir}/backup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
DEST=/var/backups/${slug}
mkdir -p "\$DEST"
tar -czf "\$DEST/site-\$(date +%F).tar.gz" -C /opt/projetos/${slug}/public .
find "\$DEST" -name 'site-*.tar.gz' -mtime +14 -delete
EOF
  chmod 700 "${dir}/backup.sh"
  install_project_cron "$slug" "/opt/projetos/${slug}/backup.sh"
}

setup_wordpress_backup(){
  local slug="$1" stack="$2" secret="$3" dir="$4" backup_dir
  backup_dir="${BACKUPS_DIR}/${slug}"
  mkdir -p "$backup_dir"
  cat > "${dir}/backup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
DEST=/var/backups/${slug}
mkdir -p "\$DEST"
CID=\$(docker ps -q -f name=${stack}_db | head -1)
[[ -n "\$CID" ]] || { echo 'MariaDB fora do ar'; exit 1; }
docker exec "\$CID" sh -c 'mariadb-dump -uroot -p"\$(cat /run/secrets/${secret})" --all-databases --single-transaction' \
  | gzip > "\$DEST/database-\$(date +%F).sql.gz"
docker run --rm -v ${stack}_wordpress_data:/data:ro -v "\$DEST":/backup alpine:3.20 \
  tar -czf "/backup/files-\$(date +%F).tar.gz" -C /data .
find "\$DEST" -type f -mtime +14 -delete
EOF
  chmod 700 "${dir}/backup.sh"
  install_project_cron "$slug" "/opt/projetos/${slug}/backup.sh"
}

create_static_site(){
  ensure_root; load_state; project_questions "site"; project_guard site
  local stack="site-${PROJECT_SLUG}" dir="${PROJECTS_DIR}/${PROJECT_SLUG}" rule token html_name
  html_name=$(printf '%s' "$PROJECT_NAME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
  rule="Host(\`${PROJECT_DOMAIN}\`)"
  [[ "$USE_WWW" =~ ^[sS]$ ]] && rule="Host(\`${PROJECT_DOMAIN}\`) || Host(\`www.${PROJECT_DOMAIN}\`)"

  say ""
  say "  ${BOLD}SITE SIMPLES${C0}"
  info "Stack: ${stack}"
  info "Arquivos: /opt/projetos/${PROJECT_SLUG}/public"
  info "Endereço: https://${PROJECT_DOMAIN}"
  confirm "Criar este site?" "s" || return 0

  ensure_edge_network
  mkdir -p "${dir}/public"
  if [[ ! -f "${dir}/public/index.html" ]]; then
    cat > "${dir}/public/index.html" <<EOF
<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${html_name}</title><style>body{font:18px system-ui;display:grid;place-items:center;min-height:100vh;margin:0;background:#111;color:#eee}main{text-align:center}small{color:#999}</style></head>
<body><main><h1>${html_name}</h1><p>Seu site está no ar.</p><small>Publicado pela Motobase</small></main></body></html>
EOF
  fi
  cat > "${dir}/stack.yml" <<EOF
version: "3.8"
services:
  web:
    image: nginx:1.27-alpine
    volumes:
      - /opt/projetos/${PROJECT_SLUG}/public:/usr/share/nginx/html:ro
    networks: [web]
    deploy:
      replicas: 1
      placement: { constraints: [node.role == manager] }
      labels:
        - traefik.enable=true
        - traefik.docker.network=web
        - traefik.http.routers.${PROJECT_SLUG}.rule=${rule}
        - traefik.http.routers.${PROJECT_SLUG}.entrypoints=websecure
        - traefik.http.routers.${PROJECT_SLUG}.tls.certresolver=${CERT_RESOLVER}
        - traefik.http.services.${PROJECT_SLUG}.loadbalancer.server.port=80
networks:
  web: { external: true }
EOF
  run docker stack deploy --detach=true -c "/opt/projetos/${PROJECT_SLUG}/stack.yml" "$stack" >/dev/null
  token=$(cloudflare_token)
  cf_record "$PROJECT_DOMAIN" "$token"
  [[ "$USE_WWW" =~ ^[sS]$ ]] && cf_record "www.${PROJECT_DOMAIN}" "$token"
  register_project "$PROJECT_SLUG" site "$PROJECT_DOMAIN" "$stack"
  setup_static_backup "$PROJECT_SLUG" "$dir"

  wait_service "${stack}_web" && ok "Container Nginx ativo" || warn "Nginx ainda não ficou pronto."
  [[ -s "${dir}/public/index.html" ]] && ok "Conteúdo inicial presente" || warn "index.html ausente"
  ok "Backup diário configurado"
  https_smoke "$PROJECT_DOMAIN"
  say "\n  ${GREEN}${BOLD}Site criado: https://${PROJECT_DOMAIN}${C0}"
  info "Edite os arquivos em /opt/projetos/${PROJECT_SLUG}/public"
}

ensure_secret(){
  local name="$1" value="$2"
  docker secret inspect "$name" >/dev/null 2>&1 && return 0
  if [[ -n "$DRY" ]]; then
    info "Criaria o Docker Secret ${name}"
  else
    printf '%s' "$value" | docker secret create "$name" - >/dev/null
  fi
}

create_wordpress(){
  ensure_root; load_state; project_questions "WordPress"; project_guard wordpress
  local stack="wp-${PROJECT_SLUG}" dir="${PROJECTS_DIR}/${PROJECT_SLUG}"
  local db_secret="${PROJECT_SLUG}_wp_db_password" redis_secret="${PROJECT_SLUG}_wp_redis_password"
  local db_pass redis_pass rule token
  db_pass=$(pw); redis_pass=$(pw)
  rule="Host(\`${PROJECT_DOMAIN}\`)"
  [[ "$USE_WWW" =~ ^[sS]$ ]] && rule="Host(\`${PROJECT_DOMAIN}\`) || Host(\`www.${PROJECT_DOMAIN}\`)"

  say ""
  say "  ${BOLD}WORDPRESS LIMPO${C0}"
  info "Stack: ${stack}"
  info "WordPress + MariaDB própria + Redis próprio"
  info "Endereço: https://${PROJECT_DOMAIN}"
  confirm "Criar este WordPress?" "s" || return 0

  ensure_edge_network
  ensure_secret "$db_secret" "$db_pass"
  ensure_secret "$redis_secret" "$redis_pass"
  mkdir -p "$dir"
  cat > "${dir}/stack.yml" <<EOF
version: "3.8"
services:
  wordpress:
    image: wordpress:latest
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD_FILE: /run/secrets/${db_secret}
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_REDIS_HOST', 'redis');
        define('WP_REDIS_PASSWORD', trim(file_get_contents('/run/secrets/${redis_secret}')));
    secrets: [${db_secret}, ${redis_secret}]
    volumes: [wordpress_data:/var/www/html]
    networks: [internal, web]
    deploy:
      replicas: 1
      placement: { constraints: [node.role == manager] }
      labels:
        - traefik.enable=true
        - traefik.docker.network=web
        - traefik.http.routers.${PROJECT_SLUG}.rule=${rule}
        - traefik.http.routers.${PROJECT_SLUG}.entrypoints=websecure
        - traefik.http.routers.${PROJECT_SLUG}.tls.certresolver=${CERT_RESOLVER}
        - traefik.http.services.${PROJECT_SLUG}.loadbalancer.server.port=80
  db:
    image: mariadb:11.4
    environment:
      MARIADB_DATABASE: wordpress
      MARIADB_USER: wordpress
      MARIADB_PASSWORD_FILE: /run/secrets/${db_secret}
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/${db_secret}
    secrets: [${db_secret}]
    volumes: [db_data:/var/lib/mysql]
    networks: [internal]
    deploy:
      placement: { constraints: [node.role == manager] }
  redis:
    image: redis:7-alpine
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass \"\$\$(cat /run/secrets/${redis_secret})\""]
    secrets: [${redis_secret}]
    volumes: [redis_data:/data]
    networks: [internal]
    deploy:
      placement: { constraints: [node.role == manager] }
networks:
  internal: { driver: overlay, attachable: true }
  web: { external: true }
secrets:
  ${db_secret}: { external: true }
  ${redis_secret}: { external: true }
volumes:
  wordpress_data: {}
  db_data: {}
  redis_data: {}
EOF
  run docker stack deploy --detach=true -c "/opt/projetos/${PROJECT_SLUG}/stack.yml" "$stack" >/dev/null
  token=$(cloudflare_token)
  cf_record "$PROJECT_DOMAIN" "$token"
  [[ "$USE_WWW" =~ ^[sS]$ ]] && cf_record "www.${PROJECT_DOMAIN}" "$token"
  register_project "$PROJECT_SLUG" wordpress "$PROJECT_DOMAIN" "$stack"
  setup_wordpress_backup "$PROJECT_SLUG" "$stack" "$db_secret" "$dir"

  wait_service "${stack}_db" && ok "MariaDB ativa" || warn "MariaDB ainda não ficou pronta."
  wait_service "${stack}_redis" && ok "Redis ativo" || warn "Redis ainda não ficou pronto."
  wait_service "${stack}_wordpress" && ok "WordPress ativo" || warn "WordPress ainda não ficou pronto."
  if [[ -z "$DRY" ]]; then
    local db_cid redis_cid
    db_cid=$(docker ps -q -f "name=${stack}_db" | head -1)
    redis_cid=$(docker ps -q -f "name=${stack}_redis" | head -1)
    [[ -n "$db_cid" ]] && docker exec "$db_cid" sh -c \
      "mariadb-admin ping -uroot -p\"\$(cat /run/secrets/${db_secret})\" --silent" >/dev/null 2>&1 \
      && ok "MariaDB aceitou conexão" || warn "MariaDB subiu, mas não aceitou o teste de conexão"
    [[ -n "$redis_cid" ]] && docker exec "$redis_cid" sh -c \
      "redis-cli -a \"\$(cat /run/secrets/${redis_secret})\" ping" 2>/dev/null | grep -qx PONG \
      && ok "Redis respondeu PONG" || warn "Redis subiu, mas não respondeu ao teste"
  else
    ok "MariaDB seria testada com autenticação"
    ok "Redis seria testado com autenticação"
  fi
  ok "Backup diário de banco e arquivos configurado"
  https_smoke "$PROJECT_DOMAIN"
  say "\n  ${GREEN}${BOLD}WordPress criado: https://${PROJECT_DOMAIN}${C0}"
  info "Abra o endereço para definir título e administrador do WordPress."
}

list_projects(){
  local registry="${STATE_REAL}/projects.tsv"
  say "  ${BOLD}MEUS PROJETOS${C0}\n"
  if [[ ! -s "$registry" ]]; then
    info "Nenhum projeto criado por este gerenciador ainda."
    return
  fi
  printf '  %-25s %-12s %-32s %s\n' "PROJETO" "TIPO" "DOMÍNIO" "STACK"
  while IFS=$'\t' read -r slug type domain stack created; do
    printf '  %-25s %-12s %-32s %s\n' "$slug" "$type" "$domain" "$stack"
  done < "$registry"
}

service_check(){
  local service="$1" label="$2" replicas have want
  replicas=$(docker service ls --filter "name=${service}" --format '{{.Name}} {{.Replicas}}' 2>/dev/null | awk -v s="$service" '$1==s{print $2}')
  have="${replicas%%/*}"; want="${replicas##*/}"
  [[ -n "$replicas" && "$have" == "$want" && "$have" != 0 ]] \
    && ok "${label} (${replicas})" \
    || warn "${label} (${replicas:-não encontrado})"
}

smoke_projects(){
  local registry="${STATE_REAL}/projects.tsv" slug type domain stack created
  [[ -s "$registry" ]] || { info "Nenhum projeto registrado para testar"; return 0; }
  say "\n  ${BOLD}PROJETOS${C0}"
  while IFS=$'\t' read -r slug type domain stack created; do
    say "\n  ${ORANGE}${slug}${C0} ${DIM}(${type})${C0}"
    if [[ "$type" == site ]]; then
      service_check "${stack}_web" "Nginx"
    elif [[ "$type" == wordpress ]]; then
      service_check "${stack}_wordpress" "WordPress"
      service_check "${stack}_db" "MariaDB"
      service_check "${stack}_redis" "Redis"
    fi
    https_smoke "$domain"
    [[ -x "/opt/projetos/${slug}/backup.sh" ]] && ok "Backup configurado" || warn "Backup ausente"
  done < "$registry"
}

smoke_foundation(){
  ensure_root; load_state
  say "  ${BOLD}SAÚDE DA FUNDAÇÃO${C0}\n"
  command -v docker >/dev/null 2>&1 && ok "Docker instalado" || warn "Docker ausente"
  [[ $(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null) == active ]] && ok "Docker Swarm ativo" || warn "Swarm inativo"
  docker network inspect web >/dev/null 2>&1 && ok "Rede pública web" || warn "Rede web ausente"
  service_check traefik_traefik "Traefik"
  service_check portainer_portainer "Portainer"
  service_check portainer_agent "Portainer Agent"
  service_check beszel_hub "Beszel Hub"
  service_check beszel_agent "Beszel Agent"
  curl -fsS --max-time 5 http://127.0.0.1:8090/api/health >/dev/null 2>&1 \
    && ok "Painel Beszel respondeu" || warn "Painel Beszel não respondeu na porta local 8090"
  service_check "${BASE_SLUG}_postgres" "PostgreSQL + pgvector"
  service_check "${BASE_SLUG}_redis" "Redis"
  local pg_cid redis_cid latest_backup
  pg_cid=$(docker ps -q -f "name=${BASE_SLUG}_postgres" | head -1)
  redis_cid=$(docker ps -q -f "name=${BASE_SLUG}_redis" | head -1)
  if [[ -n "$pg_cid" ]] && docker exec "$pg_cid" pg_isready -U postgres >/dev/null 2>&1; then
    ok "PostgreSQL aceitou conexão"
    docker exec "$pg_cid" psql -U postgres -d "$BASE_SLUG" -tAc \
      "select 1 from pg_extension where extname='vector'" 2>/dev/null | grep -qx 1 \
      && ok "Extensão pgvector habilitada" || warn "Extensão pgvector ausente"
  else
    warn "PostgreSQL não aceitou conexão"
  fi
  if [[ -n "$redis_cid" ]] && docker secret inspect "${BASE_SLUG}_redis_password" >/dev/null 2>&1; then
    docker exec "$redis_cid" sh -c "redis-cli -a \"\$(cat /run/secrets/${BASE_SLUG}_redis_password)\" ping" 2>/dev/null | grep -qx PONG \
      && ok "Redis respondeu com autenticação" || warn "Redis não respondeu com autenticação"
  elif [[ -n "$redis_cid" ]]; then
    warn "Redis respondeu sem senha — base legada; recrie/atualize a fundação para proteger"
  else
    warn "Redis não respondeu ao teste"
  fi
  tailscale status >/dev/null 2>&1 && ok "Tailscale conectado ($(tailscale ip -4 2>/dev/null | head -1))" || warn "Tailscale desconectado"
  if systemctl is-enabled --quiet gestao-lockdown.service 2>/dev/null \
    && iptables -C DOCKER-USER -j GESTAO-TAILNET 2>/dev/null \
    && iptables -S GESTAO-TAILNET 2>/dev/null | grep -q -- '-s 100.64.0.0/10'; then
    ok "Painéis de gestão bloqueados fora da Tailnet"
  else
    warn "Não consegui confirmar o bloqueio Tailnet de Portainer/Beszel"
    info "Rode: systemctl status gestao-lockdown.service"
  fi
  [[ -x "/opt/${BASE_SLUG}/backup.sh" ]] && ok "Backup diário configurado" || warn "Script de backup não encontrado"
  [[ -f /etc/cron.d/${BASE_SLUG}-backup ]] && ok "Agendamento de backup presente" || warn "Agendamento de backup ausente"
  latest_backup=$(find "/var/backups/${BASE_SLUG}" -maxdepth 1 -name '*.sql.gz' -type f 2>/dev/null | sort | tail -1 || true)
  if [[ -n "$latest_backup" ]]; then
    gzip -t "$latest_backup" 2>/dev/null && ok "Último backup íntegro" || warn "Último backup corrompido"
  else
    info "Ainda não há dump para validar"
  fi
  smoke_projects
}

main_menu(){
  load_state
  banner
  while true; do
    say "  ${BOLD}FUNDAÇÃO${C0}  ${GREEN}● ONLINE${C0}"
    say "  ${DIM}${BASE_NAME} · Swarm · Traefik · Portainer · Dados · Tailnet${C0}\n"
    say "  ${ORANGE}[1]${C0} Novo site simples       ${ORANGE}[2]${C0} Novo WordPress"
    say "  ${ORANGE}[3]${C0} Meus projetos           ${ORANGE}[4]${C0} Saúde da VPS"
    say "  ${ORANGE}[0]${C0} Sair\n"
    ask choice "O que você quer fazer"
    say ""
    case "$choice" in
      1) create_static_site; break ;;
      2) create_wordpress; break ;;
      3) list_projects; break ;;
      4) smoke_foundation; break ;;
      0) return 0 ;;
      *) warn "Escolha uma opção válida."; sleep 1 ;;
    esac
  done
}

main(){
  ensure_root
  [[ "$ACTION" == help ]] && { help_text; return; }

  if ! foundation_present; then
    banner
    install_foundation
    foundation_present || return 0
  fi

  case "$ACTION" in
    status) smoke_foundation ;;
    repair-beszel) bash "$(motor)" --repair-beszel ;;
    site) create_static_site ;;
    wordpress) create_wordpress ;;
    *) main_menu ;;
  esac
}

main
