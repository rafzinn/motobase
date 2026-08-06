#!/usr/bin/env bash
# =============================================================================
#  🦀 MOTOBASE — sua VPS de produção em uma linha
#
#  bash <(curl -fsSL https://get.motobot.com.br)
#
#  Sobe a MESMA fundação que roda o Motobot em produção:
#    Docker Swarm → Traefik (HTTPS automático) → Portainer → stacks à escolha
#  Senhas fortes geradas na hora. Domínios com HTTPS de verdade via Cloudflare.
#
#  Por Rafael Ventura (github.com/rafzinn) × Fable 5.
#  Conhecimento de arquitetura aberto; produto Motobot continua fechado. 😉
# =============================================================================
set -euo pipefail

# ── ui ───────────────────────────────────────────────────────────────────────
C0='\033[0m'; DIM='\033[2m'; BOLD='\033[1m'
RED='\033[38;5;203m'; AMB='\033[38;5;179m'; GRN='\033[38;5;108m'; CRM='\033[38;5;230m'
say(){ echo -e "$*"; }
ok(){ say "  ${GRN}✓${C0} $*"; }
info(){ say "  ${DIM}├─${C0} $*"; }
warn(){ say "  ${AMB}⚠${C0} $*"; }
die(){ say "\n  ${RED}✗ $*${C0}\n"; exit 1; }
ask(){ local __v=$1 __p=$2 __d=${3:-}; local r; read -rp "$(echo -e "  ${AMB}?${C0} ${__p}${__d:+ ${DIM}[$__d]${C0}}: ")" r; printf -v "$__v" '%s' "${r:-$__d}"; }
pw(){ openssl rand -base64 18 | tr -d '/+=' | head -c 20; }

DRY=${1:-}
run(){ if [[ "$DRY" == "--dry-run" ]]; then say "  ${DIM}[dry-run]${C0} $*"; else eval "$@"; fi; }

CRED=/root/motobase-credenciais.txt
cred(){ echo "$*" >> "$CRED"; }

banner(){
  say ""
  say "  ${RED}    /\\_/\\ ${C0}"
  say "  ${RED}  ( o . o )   ${BOLD}${CRM}M O T O B A S E${C0}"
  say "  ${RED}  /|  ⌄  |\\ ${C0}  ${DIM}sua VPS de produção, em uma linha${C0}"
  say "  ${RED} ✂ |____| ✂${C0}  ${DIM}por Rafael Ventura × Fable 5 🦀${C0}"
  say ""
}

# ── checagens ────────────────────────────────────────────────────────────────
preflight(){
  [[ $EUID -eq 0 ]] || die "Rode como root (sudo -i antes)."
  command -v apt-get >/dev/null || die "Este instalador suporta Ubuntu/Debian (apt)."
  IP=$(curl -fsS -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  ok "Servidor: $(hostname) — IP público ${BOLD}${IP}${C0}"
  if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == "active" ]]; then
    warn "Este servidor JÁ tem Docker Swarm ativo."
    ask GOON "Continuar mesmo assim? Vou pular o que já existir (s/n)" "n"
    [[ "$GOON" =~ ^[sS] ]] || die "Abortado com segurança — nada foi alterado."
  fi
  : > "$CRED"; chmod 600 "$CRED"
  cred "══════ MOTOBASE — credenciais geradas em $(date '+%d/%m/%Y %H:%M') ══════"
  cred "Servidor: $(hostname)  IP: ${IP}"
}

# ── etapa 1: docker + swarm ──────────────────────────────────────────────────
docker_swarm(){
  say "\n${BOLD}[1/5] Docker + Swarm${C0}"
  if ! command -v docker >/dev/null; then
    info "instalando Docker (script oficial)…"
    run "curl -fsSL https://get.docker.com | sh >/dev/null 2>&1"
  fi
  ok "Docker $(docker --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo instalado)"
  if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]]; then
    run "docker swarm init --advertise-addr ${IP} >/dev/null"
  fi
  ok "Swarm ativo (orquestrador de containers com auto-restart)"
  docker network inspect web >/dev/null 2>&1 || run "docker network create -d overlay --attachable web >/dev/null"
  ok "Rede overlay 'web' (todos os serviços conversam por ela)"
}

# ── etapa 2: domínio (a observação que o lead precisa ver) ───────────────────
domain_step(){
  say "\n${BOLD}[2/5] Domínio${C0}"
  say ""
  say "  ${AMB}┌─────────────────────────  ANTES DE CONTINUAR  ─────────────────────────┐${C0}"
  say "  ${AMB}│${C0} No painel da ${BOLD}Cloudflare${C0} (ou do seu DNS), crie um registro apontando   ${AMB}│${C0}"
  say "  ${AMB}│${C0} pro IP deste servidor:                                                 ${AMB}│${C0}"
  say "  ${AMB}│${C0}                                                                        ${AMB}│${C0}"
  say "  ${AMB}│${C0}   Tipo: ${BOLD}A${C0}    Nome: ${BOLD}seu-dominio${C0} (@ ou sub)    Conteúdo: ${BOLD}${IP}${C0}"
  say "  ${AMB}│${C0}                                                                        ${AMB}│${C0}"
  say "  ${AMB}│${C0} DICA: na primeira emissão do HTTPS deixe a nuvem ${BOLD}CINZA${C0} (DNS only).    ${AMB}│${C0}"
  say "  ${AMB}│${C0} Depois do cadeado verde, pode ligar a nuvem laranja se quiser.         ${AMB}│${C0}"
  say "  ${AMB}└────────────────────────────────────────────────────────────────────────┘${C0}"
  say ""
  ask BASE_DOMAIN "Qual o seu domínio base? (ex: meunegocio.com.br)"
  [[ -n "$BASE_DOMAIN" ]] || die "Preciso de um domínio."
  ask LE_EMAIL "E-mail pro certificado HTTPS (Let's Encrypt)" "admin@${BASE_DOMAIN}"
  info "conferindo propagação de ${BASE_DOMAIN}…"
  local resolved; resolved=$(getent hosts "$BASE_DOMAIN" | awk '{print $1}' | head -1 || true)
  if [[ "$resolved" == "$IP" ]]; then ok "DNS propagado: ${BASE_DOMAIN} → ${IP}"
  elif [[ -n "$resolved" ]]; then warn "${BASE_DOMAIN} resolve pra ${resolved} (esperava ${IP}). Se a nuvem laranja está ligada, é normal."
  else warn "Ainda não resolve — o HTTPS pode falhar na 1ª tentativa e se corrigir sozinho depois."
  fi
  cred ""; cred "Domínio base: ${BASE_DOMAIN}"
}

# ── etapa 3: traefik ─────────────────────────────────────────────────────────
traefik_stack(){
  say "\n${BOLD}[3/5] Traefik — o porteiro HTTPS${C0}"
  mkdir -p /opt/traefik && touch /opt/traefik/acme.json && chmod 600 /opt/traefik/acme.json
  cat > /opt/traefik/stack.yml <<EOF
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
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/traefik/acme.json:/acme.json
    networks: [web]
    deploy:
      placement: { constraints: [node.role == manager] }
networks:
  web: { external: true }
EOF
  run "docker stack deploy -c /opt/traefik/stack.yml traefik >/dev/null"
  ok "Traefik no ar — todo serviço novo ganha HTTPS automático"
}

# ── etapa 4: portainer ───────────────────────────────────────────────────────
portainer_stack(){
  say "\n${BOLD}[4/5] Portainer — o painel visual do servidor${C0}"
  local PDOM="portainer.${BASE_DOMAIN}"
  cat > /opt/traefik/portainer.yml <<EOF
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
    networks: [agent, web]
    deploy:
      placement: { constraints: [node.role == manager] }
      labels:
        - traefik.enable=true
        - traefik.http.routers.portainer.rule=Host(\`${PDOM}\`)
        - traefik.http.routers.portainer.entrypoints=websecure
        - traefik.http.routers.portainer.tls.certresolver=le
        - traefik.http.services.portainer.loadbalancer.server.port=9000
networks:
  agent: { driver: overlay, attachable: true }
  web: { external: true }
volumes:
  pdata:
EOF
  run "docker stack deploy -c /opt/traefik/portainer.yml portainer >/dev/null"
  ok "Portainer: ${BOLD}https://${PDOM}${C0} ${DIM}(crie o admin no PRIMEIRO acesso — corre, expira em 5min)${C0}"
  warn "Lembra do DNS: crie também ${BOLD}portainer.${BASE_DOMAIN}${C0} → ${IP}"
  cred "Portainer: https://${PDOM}  (admin criado no primeiro acesso)"
}

# ── etapa 5: stacks à escolha ────────────────────────────────────────────────
menu_stacks(){
  say "\n${BOLD}[5/5] Stacks${C0} — o que este servidor vai rodar?"
  say "   ${BOLD}1${C0}) WordPress (site/blog completo: MySQL + Redis cache)"
  say "   ${BOLD}2${C0}) PostgreSQL (banco de dados)"
  say "   ${BOLD}3${C0}) Redis (cache/filas)"
  say "   ${BOLD}4${C0}) n8n (automações no-code)"
  say "   ${BOLD}5${C0}) Site estático (nginx — HTML/CSS/JS direto da pasta)"
  say "   ${BOLD}A${C0}) TUDO — instala as 5"
  ask PICK "Escolha (ex: 1 3 5, ou A)" "A"
  [[ "$PICK" =~ [Aa] ]] && PICK="1 2 3 4 5"
  for p in $PICK; do case $p in
    1) stack_wordpress ;;
    2) stack_postgres ;;
    3) stack_redis ;;
    4) stack_n8n ;;
    5) stack_static ;;
  esac; done
}

stack_wordpress(){
  say "\n  ${CRM}▸ WordPress${C0}"
  ask WPDOM "  Domínio do site (ex: blog.${BASE_DOMAIN} ou ${BASE_DOMAIN})" "${BASE_DOMAIN}"
  local DBP; DBP=$(pw); local RTP; RTP=$(pw)
  mkdir -p /opt/stacks
  cat > /opt/stacks/wordpress.yml <<EOF
version: "3.8"
services:
  db:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${RTP}
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wp
      MYSQL_PASSWORD: ${DBP}
    volumes: [wpdb:/var/lib/mysql]
    networks: [internal]
  redis:
    image: redis:7-alpine
    networks: [internal]
  wordpress:
    image: wordpress:php8.3-apache
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wp
      WORDPRESS_DB_PASSWORD: ${DBP}
      WORDPRESS_DB_NAME: wordpress
    volumes: [wpfiles:/var/www/html]
    networks: [internal, web]
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.routers.wp.rule=Host(\`${WPDOM}\`)
        - traefik.http.routers.wp.entrypoints=websecure
        - traefik.http.routers.wp.tls.certresolver=le
        - traefik.http.services.wp.loadbalancer.server.port=80
networks:
  internal: { driver: overlay }
  web: { external: true }
volumes: { wpdb: {}, wpfiles: {} }
EOF
  run "docker stack deploy -c /opt/stacks/wordpress.yml wordpress >/dev/null"
  ok "WordPress: ${BOLD}https://${WPDOM}${C0} ${DIM}(instalação do WP no primeiro acesso)${C0}"
  cred ""; cred "WordPress: https://${WPDOM}"
  cred "  MySQL root: ${RTP}"; cred "  MySQL user wp: ${DBP}"
}

stack_postgres(){
  say "\n  ${CRM}▸ PostgreSQL${C0}"
  local PGP; PGP=$(pw)
  mkdir -p /opt/stacks
  cat > /opt/stacks/postgres.yml <<EOF
version: "3.8"
services:
  postgres:
    image: postgres:16
    environment: { POSTGRES_PASSWORD: ${PGP} }
    volumes: [pgdata:/var/lib/postgresql/data]
    networks: [web]
networks: { web: { external: true } }
volumes: { pgdata: {} }
EOF
  run "docker stack deploy -c /opt/stacks/postgres.yml postgres >/dev/null"
  ok "PostgreSQL no ar (host interno: ${BOLD}postgres_postgres${C0}, porta 5432)"
  cred ""; cred "PostgreSQL: host postgres_postgres:5432  user postgres  senha: ${PGP}"
}

stack_redis(){
  say "\n  ${CRM}▸ Redis${C0}"
  local RDP; RDP=$(pw)
  mkdir -p /opt/stacks
  cat > /opt/stacks/redis.yml <<EOF
version: "3.8"
services:
  redis:
    image: redis:7-alpine
    command: redis-server --requirepass ${RDP}
    volumes: [rdata:/data]
    networks: [web]
networks: { web: { external: true } }
volumes: { rdata: {} }
EOF
  run "docker stack deploy -c /opt/stacks/redis.yml redis >/dev/null"
  ok "Redis no ar (host interno: ${BOLD}redis_redis${C0}, porta 6379, com senha)"
  cred ""; cred "Redis: host redis_redis:6379  senha: ${RDP}"
  cred "  DICA: senha em URI precisa URL-encode (@ vira %40)"
}

stack_n8n(){
  say "\n  ${CRM}▸ n8n${C0}"
  local NDOM="n8n.${BASE_DOMAIN}"
  mkdir -p /opt/stacks
  cat > /opt/stacks/n8n.yml <<EOF
version: "3.8"
services:
  n8n:
    image: n8nio/n8n:latest
    environment:
      - N8N_HOST=${NDOM}
      - WEBHOOK_URL=https://${NDOM}/
      - GENERIC_TIMEZONE=America/Sao_Paulo
    volumes: [n8ndata:/home/node/.n8n]
    networks: [web]
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.routers.n8n.rule=Host(\`${NDOM}\`)
        - traefik.http.routers.n8n.entrypoints=websecure
        - traefik.http.routers.n8n.tls.certresolver=le
        - traefik.http.services.n8n.loadbalancer.server.port=5678
networks: { web: { external: true } }
volumes: { n8ndata: {} }
EOF
  run "docker stack deploy -c /opt/stacks/n8n.yml n8n >/dev/null"
  ok "n8n: ${BOLD}https://${NDOM}${C0} ${DIM}(crie a conta admin no primeiro acesso)${C0}"
  warn "DNS: crie também ${BOLD}n8n.${BASE_DOMAIN}${C0} → ${IP}"
  cred ""; cred "n8n: https://${NDOM}  (conta criada no primeiro acesso)"
}

stack_static(){
  say "\n  ${CRM}▸ Site estático${C0}"
  ask SDOM "  Domínio do site estático (ex: lp.${BASE_DOMAIN})" "www.${BASE_DOMAIN}"
  local SLUG; SLUG=$(echo "$SDOM" | tr '.' '-' | tr -cd 'a-z0-9-')
  mkdir -p "/opt/sites/${SLUG}"
  [[ -f "/opt/sites/${SLUG}/index.html" ]] || cat > "/opt/sites/${SLUG}/index.html" <<EOF
<!doctype html><meta charset="utf-8"><title>${SDOM}</title>
<body style="margin:0;display:grid;place-items:center;min-height:100vh;background:#0d0d0d;color:#ece5d8;font-family:system-ui">
<div style="text-align:center"><h1 style="letter-spacing:-.02em">🦀 No ar.</h1>
<p style="color:#a8a094">Edite <code>/opt/sites/${SLUG}/index.html</code> — a mudança aparece na hora.</p></div>
EOF
  cat > "/opt/stacks/site-${SLUG}.yml" <<EOF
version: "3.8"
services:
  site:
    image: nginx:alpine
    volumes: ["/opt/sites/${SLUG}:/usr/share/nginx/html:ro"]
    networks: [web]
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.routers.s${SLUG}.rule=Host(\`${SDOM}\`)
        - traefik.http.routers.s${SLUG}.entrypoints=websecure
        - traefik.http.routers.s${SLUG}.tls.certresolver=le
        - traefik.http.services.s${SLUG}.loadbalancer.server.port=80
networks: { web: { external: true } }
EOF
  run "docker stack deploy -c /opt/stacks/site-${SLUG}.yml site-${SLUG} >/dev/null"
  ok "Site estático: ${BOLD}https://${SDOM}${C0} — pasta ${BOLD}/opt/sites/${SLUG}${C0} (editar = publicar)"
  cred ""; cred "Site estático: https://${SDOM}  pasta /opt/sites/${SLUG}"
}

# ── resumo ───────────────────────────────────────────────────────────────────
summary(){
  say "\n${GRN}${BOLD}════════════════ TUDO NO AR ════════════════${C0}"
  say ""
  say "  Suas credenciais foram salvas em ${BOLD}${CRED}${C0} (só root lê)."
  say "  ${AMB}Copie pra um gerenciador de senhas e apague o arquivo.${C0}"
  say ""
  say "  ${DIM}Regras de ouro desta casa (aprendidas em produção):${C0}"
  say "  ${DIM}• NUNCA 'docker restart' num serviço do Swarm — use:${C0}"
  say "    ${BOLD}docker service update --force <serviço>${C0}"
  say "  ${DIM}• HTTPS demora ~1min na primeira emissão. Nuvem laranja da CF${C0}"
  say "  ${DIM}  só depois do cadeado verde.${C0}"
  say "  ${DIM}• Backup não é opcional. Pergunte-me como. 😉${C0}"
  say ""
  say "  🦀 ${BOLD}Feito.${C0} Agora fala com a IA e constrói em cima."
  say "     ${DIM}github.com/rafzinn/motobase${C0}"
  say ""
}

banner
preflight
docker_swarm
domain_step
traefik_stack
portainer_stack
menu_stacks
summary
