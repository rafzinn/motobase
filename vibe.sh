#!/usr/bin/env bash
# =============================================================================
#  ⚡ VIBE STACK — sua startup enxuta, em uma linha
#
#  bash <(curl -fsSL https://get.motobot.com.br/vibe)
#
#  Questionário único no início → o resto roda sozinho:
#    Docker Swarm → Traefik (HTTPS automático) → Postgres+pgvector → Redis
#    → Tailscale + Portainer só-tailnet (gestão) → Claude Code autenticado
#    com CLAUDE.md da infra → moltbot (opcional) → backup diário.
#  As stacks nascem CRUAS: banco sem tabelas, produto do zero — você comanda.
#  Senhas fortes geradas na hora, guardadas como Docker secrets.
#
#  Uso avançado: --seed <nome>  aplica uma semente de projeto (DDL + CLAUDE.md
#  de seeds/<nome>/ no repo) por cima da base. --dry-run não toca o disco.
#
#  Por Rafael Ventura (github.com/rafzinn) × Fable 5.
# =============================================================================
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/rafzinn/motobase/main"

# ── ui ───────────────────────────────────────────────────────────────────────
C0='\033[0m'; DIM='\033[2m'; BOLD='\033[1m'
RED='\033[38;5;203m'; AMB='\033[38;5;179m'; GRN='\033[38;5;108m'; LRJ='\033[38;5;173m'
say(){ echo -e "$*"; }
ok(){ say "  ${GRN}✓${C0} $*"; }
info(){ say "  ${DIM}├─${C0} $*"; }
warn(){ say "  ${AMB}⚠${C0} $*"; }
die(){ say "\n  ${RED}✗ $*${C0}\n"; exit 1; }
ask(){ local __v=$1 __p=$2 __d=${3:-}; local r; read -rp "$(echo -e "  ${AMB}?${C0} ${__p}${__d:+ ${DIM}[$__d]${C0}}: ")" r; printf -v "$__v" '%s' "${r:-$__d}"; }
pw(){ openssl rand -base64 18 | tr -d '/+=' | head -c 20; }

DRY=""; SEED=""
while [[ $# -gt 0 ]]; do case "$1" in
  --dry-run) DRY="--dry-run" ;;
  --seed) SEED="${2:-}"; shift ;;
  *) warn "argumento desconhecido: $1" ;;
esac; shift; done

D=""   # prefixo de escrita: em dry-run, NADA toca o disco real
if [[ "$DRY" == "--dry-run" ]]; then D=$(mktemp -d); fi
run(){ if [[ "$DRY" == "--dry-run" ]]; then say "  ${DIM}[dry-run]${C0} $*"; else eval "$@"; fi; }

banner(){
  say ""
  say "  ${LRJ}  ⚡ V I B E   S T A C K${C0}"
  say "  ${DIM}  sua startup enxuta, em uma linha — por Rafael Ventura × Fable 5${C0}"
  [[ -n "$SEED" ]] && say "  ${DIM}  semente de projeto: ${BOLD}${SEED}${C0}"
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
  # semente (se pedida): baixa ANTES de perguntar qualquer coisa — falha cedo
  SEED_DIR=""
  if [[ -n "$SEED" ]]; then
    SEED_DIR=$(mktemp -d)
    curl -fsSL "${RAW_BASE}/seeds/${SEED}/CLAUDE.md" -o "${SEED_DIR}/CLAUDE.md" 2>/dev/null \
      || die "Semente '${SEED}' não encontrada no repo (seeds/${SEED}/)."
    curl -fsSL "${RAW_BASE}/seeds/${SEED}/ddl.sql" -o "${SEED_DIR}/ddl.sql" 2>/dev/null || true
    ok "Semente '${SEED}' baixada$([[ -f ${SEED_DIR}/ddl.sql ]] && echo ' (com schema de banco)')"
  fi
}

# ── etapa 1: questionário — TUDO de uma vez, depois o script trabalha sozinho ─
questionario(){
  say "\n${BOLD}[1/9] Questionário${C0} — responde tudo agora e vai tomar um café.\n"

  ask PROJ_NAME "Nome do projeto/startup"
  [[ -n "${PROJ_NAME}" ]] || die "Preciso de um nome."
  SLUG=$(echo "$PROJ_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
  [[ -n "$SLUG" ]] || die "Nome precisa ter letras ou números."
  info "identificador técnico: ${BOLD}${SLUG}${C0} (banco, stacks, secrets)"

  say ""
  say "  ${AMB}┌─────────────────────────  DNS ANTES DE CONTINUAR  ─────────────────────┐${C0}"
  say "  ${AMB}│${C0} No painel do seu DNS (Cloudflare etc.), crie um registro tipo ${BOLD}A${C0}       ${AMB}│${C0}"
  say "  ${AMB}│${C0} apontando o domínio do projeto pro IP deste servidor: ${BOLD}${IP}${C0}"
  say "  ${AMB}│${C0} DICA: na primeira emissão do HTTPS deixe a nuvem ${BOLD}CINZA${C0} (DNS only).    ${AMB}│${C0}"
  say "  ${AMB}└────────────────────────────────────────────────────────────────────────┘${C0}"
  ask APP_DOMAIN "Domínio do projeto (ex: app.seudominio.com.br)"
  [[ -n "$APP_DOMAIN" ]] || die "Preciso de um domínio."
  ask LE_EMAIL "E-mail pro certificado HTTPS (Let's Encrypt)" "admin@${APP_DOMAIN#*.}"

  say "\n  ${BOLD}Credenciais${C0} ${DIM}(Enter pula qualquer uma — dá pra cadastrar depois)${C0}"
  ask CLTOK "Token do Claude (rode ${BOLD}claude setup-token${C0} no SEU computador e cole aqui; ou chave sk-ant-api…)" ""
  ask OAKEY "Chave da OpenAI (sk-…) — se o produto for usar IA da OpenAI" ""
  ask TGTOK "Token de bot do Telegram (do @BotFather) — se o produto for usar" ""
  ask TSKEY "Auth key do Tailscale (tskey-…) ${DIM}— com ela o script não para pra login${C0}" ""

  say ""
  ask QUER_MOLT "Instalar o moltbot (agente pessoal OpenClaw)? (s/n)" "n"
  MOLT_TG=""
  if [[ "$QUER_MOLT" =~ ^[sS] ]]; then
    say "  ${DIM}Um bot do Telegram só roda em UM servidor — se o seu moltbot atual já usa um bot${C0}"
    say "  ${DIM}em outra VPS, crie um bot NOVO no @BotFather pra este.${C0}"
    ask MOLT_TG "Token do bot Telegram do moltbot (Enter pra configurar depois)" ""
  fi

  info "conferindo propagação de ${APP_DOMAIN}…"
  local resolved; resolved=$(getent hosts "$APP_DOMAIN" | awk '{print $1}' | head -1 || true)
  if [[ "$resolved" == "$IP" ]]; then ok "DNS propagado: ${APP_DOMAIN} → ${IP}"
  elif [[ -n "$resolved" ]]; then warn "${APP_DOMAIN} resolve pra ${resolved} (esperava ${IP}). Se a nuvem laranja está ligada, é normal."
  else warn "Ainda não resolve — o HTTPS pode falhar na 1ª tentativa e se corrigir sozinho depois."
  fi

  CRED="${D}/root/${SLUG}-credenciais.txt"
  mkdir -p "${D}/root"
  : > "$CRED"; chmod 600 "$CRED"
  cred(){ echo "$*" >> "$CRED"; }
  cred "══════ ${PROJ_NAME} — credenciais geradas em $(date '+%d/%m/%Y %H:%M') ══════"
  cred "Servidor: $(hostname)  IP: ${IP}"
  cred "Projeto: https://${APP_DOMAIN}"
  ok "Questionário completo — daqui pra frente é comigo."
}

# ── etapa 2: docker + swarm ──────────────────────────────────────────────────
docker_swarm(){
  say "\n${BOLD}[2/9] Docker + Swarm${C0}"
  if ! command -v docker >/dev/null; then
    info "instalando Docker (script oficial)…"
    run "curl -fsSL https://get.docker.com | sh >/dev/null 2>&1"
  fi
  ok "Docker $(docker --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo instalado)"
  if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]]; then
    run "docker swarm init --advertise-addr ${IP} >/dev/null"
  fi
  ok "Swarm ativo (auto-restart de tudo que cair)"
  docker network inspect web >/dev/null 2>&1 || run "docker network create -d overlay --attachable web >/dev/null"
  ok "Rede overlay 'web'"
}

# ── etapa 3: traefik ─────────────────────────────────────────────────────────
traefik_stack(){
  say "\n${BOLD}[3/9] Traefik — o porteiro HTTPS${C0}"
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
  run "docker stack deploy -c /opt/traefik/stack.yml traefik >/dev/null"
  ok "Traefik no ar — todo serviço novo ganha HTTPS automático"
}

# ── etapa 4: banco + redis (CRUS — schema é com você e o Claude) ─────────────
dados_stack(){
  say "\n${BOLD}[4/9] Dados — Postgres+pgvector e Redis${C0}"
  local PGP; PGP=$(pw)
  if ! docker secret inspect "${SLUG}_pg_password" >/dev/null 2>&1; then
    run "printf '%s' '${PGP}' | docker secret create ${SLUG}_pg_password - >/dev/null"
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
  run "docker stack deploy -c /opt/${SLUG}/stack.yml ${SLUG} >/dev/null"
  ok "Postgres+pgvector (host interno: ${BOLD}${SLUG}_postgres${C0}) e Redis (${BOLD}${SLUG}_redis${C0}) no ar"
  info "rede '${SLUG}_internal': banco e redis NÃO ficam expostos na web"
  cred ""; cred "Postgres: host ${SLUG}_postgres:5432  db ${SLUG}  user postgres"
  cred "  senha: ${PGP}  (fonte de verdade: docker secret ${SLUG}_pg_password)"
  cred "Redis: host ${SLUG}_redis:6379 (rede interna, sem senha)"
  banco_pronto
}

banco_pronto(){
  say "\n  ${LRJ}▸ Preparando o banco${C0}"
  if [[ "$DRY" == "--dry-run" ]]; then
    say "  ${DIM}[dry-run] habilitaria pgvector${SEED:+ e aplicaria o schema da semente '${SEED}'}${C0}"
    [[ -n "$SEED" ]] && { ok "Schema da semente '${SEED}' aplicado (dry-run)"; return; }
  else
    info "aguardando o Postgres subir…"
    local i=0 CID=""
    until CID=$(docker ps -q -f name="${SLUG}_postgres" | head -1) && [[ -n "$CID" ]] \
      && docker exec "$CID" pg_isready -U postgres >/dev/null 2>&1; do
      i=$((i+1)); [[ $i -gt 60 ]] && die "Postgres não subiu em 2 minutos — veja: docker service ps ${SLUG}_postgres"
      sleep 2
    done
    docker exec "$CID" psql -U postgres -d "${SLUG}" -c "create extension if not exists vector;" >/dev/null
    if [[ -n "$SEED" && -f "${SEED_DIR}/ddl.sql" ]]; then
      sed "s/{{SLUG}}/${SLUG}/g" "${SEED_DIR}/ddl.sql" > "/opt/${SLUG}/ddl.sql"
      docker exec -i "$CID" psql -U postgres -d "${SLUG}" -v ON_ERROR_STOP=1 < "/opt/${SLUG}/ddl.sql" >/dev/null
      ok "Schema da semente '${SEED}' aplicado (DDL guardado em /opt/${SLUG}/ddl.sql)"
      return
    fi
  fi
  ok "Banco ${BOLD}${SLUG}${C0} pronto, pgvector habilitado — ${DIM}sem tabelas: o schema nasce do SEU produto${C0}"
}

# ── etapa 5: secrets da aplicação (já respondidos no questionário) ───────────
app_secrets(){
  say "\n${BOLD}[5/9] Secrets da aplicação${C0}"
  if [[ -n "$TGTOK" ]] && ! docker secret inspect "${SLUG}_tg_token" >/dev/null 2>&1; then
    run "printf '%s' '${TGTOK}' | docker secret create ${SLUG}_tg_token - >/dev/null"
    ok "secret ${SLUG}_tg_token criado"
  fi
  if [[ -n "$OAKEY" ]] && ! docker secret inspect "${SLUG}_openai_key" >/dev/null 2>&1; then
    run "printf '%s' '${OAKEY}' | docker secret create ${SLUG}_openai_key - >/dev/null"
    ok "secret ${SLUG}_openai_key criado"
  fi
  local JWTS; JWTS=$(pw)$(pw)
  if ! docker secret inspect "${SLUG}_jwt_secret" >/dev/null 2>&1; then
    run "printf '%s' '${JWTS}' | docker secret create ${SLUG}_jwt_secret - >/dev/null"
    ok "secret ${SLUG}_jwt_secret criado (login/sessões da sua app)"
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
  ok "Template da aplicação em ${BOLD}/opt/${SLUG}/app.yml${C0} ${DIM}(deploy quando a API for construída)${C0}"
}

# ── etapa 6: tailscale + gestão só-tailnet ───────────────────────────────────
tailscale_gestao(){
  say "\n${BOLD}[6/9] Tailscale — gestão fora da internet pública${C0}"
  info "Portainer (e o que mais for gestão) só abre com o Tailscale ligado no SEU dispositivo."
  if ! command -v tailscale >/dev/null; then
    info "instalando Tailscale (script oficial)…"
    run "curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1"
  fi
  if [[ "$DRY" == "--dry-run" ]]; then
    say "  ${DIM}[dry-run] tailscale up${TSKEY:+ --authkey=***}${C0}"; TSIP="100.x.y.z"
  else
    if [[ -n "$TSKEY" ]]; then tailscale up --authkey="$TSKEY"
    else
      say "  ${AMB}→ Abra o link que vai aparecer abaixo e autorize este servidor na sua tailnet:${C0}"
      tailscale up
    fi
    TSIP=$(tailscale ip -4 2>/dev/null | head -1)
    [[ -n "$TSIP" ]] || die "Tailscale não subiu — rode 'tailscale up' manualmente e repita."
  fi
  ok "Servidor na tailnet: ${BOLD}${TSIP}${C0}"

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
  run "docker stack deploy -c /opt/${SLUG}/portainer.yml portainer >/dev/null"

  # Porta publicada pelo Docker IGNORA o ufw — o trinco de verdade é na chain
  # DOCKER-USER, e precisa sobreviver a reboot (script + unit systemd).
  cat > "${D}/usr/local/sbin/gestao-lockdown.sh" <<'EOF'
#!/usr/bin/env bash
# Trava portas de GESTÃO pra aceitarem só tailnet (100.64/10) e localhost.
set -e
PORTS="9000 18789"   # 9000=Portainer · 18789=moltbot (gateway/painel)
iptables -N GESTAO-TAILNET 2>/dev/null || true
iptables -F GESTAO-TAILNET
for p in $PORTS; do
  iptables -A GESTAO-TAILNET -p tcp --dport "$p" -s 100.64.0.0/10 -j RETURN
  iptables -A GESTAO-TAILNET -p tcp --dport "$p" -s 127.0.0.0/8    -j RETURN
  iptables -A GESTAO-TAILNET -p tcp --dport "$p" -j DROP
done
iptables -C DOCKER-USER -j GESTAO-TAILNET 2>/dev/null || iptables -I DOCKER-USER 1 -j GESTAO-TAILNET
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
  ok "Portainer: ${BOLD}http://${TSIP}:9000${C0} ${DIM}(SÓ com Tailscale ligado; crie o admin no 1º acesso — expira em 5min)${C0}"
  info "do IP público, as portas de gestão simplesmente não respondem (DROP na DOCKER-USER, persistente)"
  cred ""; cred "Portainer (gestão, só-tailnet): http://${TSIP}:9000"
  cred "IP tailnet do servidor: ${TSIP}"
}

# ── etapa 7: claude code — o programador mora aqui ───────────────────────────
claude_code(){
  say "\n${BOLD}[7/9] Claude Code — pronto pra receber ordens${C0}"
  if ! command -v node >/dev/null || [[ "$(node -v 2>/dev/null | grep -oP '\d+' | head -1)" -lt 20 ]]; then
    info "instalando Node.js 22 (NodeSource)…"
    run "curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 && apt-get install -y nodejs >/dev/null 2>&1"
  fi
  ok "Node $(node -v 2>/dev/null || echo '(dry-run)')"
  if ! command -v claude >/dev/null; then
    info "instalando Claude Code…"
    run "npm install -g @anthropic-ai/claude-code >/dev/null 2>&1"
  fi
  ok "Claude Code $(claude --version 2>/dev/null | head -1 || echo instalado)"

  # credencial: setup-token (sk-ant-oat…) vira CLAUDE_CODE_OAUTH_TOKEN; chave API vira ANTHROPIC_API_KEY
  mkdir -p "${D}/etc/profile.d"
  if [[ -n "$CLTOK" ]]; then
    local VARNAME="ANTHROPIC_API_KEY"
    [[ "$CLTOK" == sk-ant-oat* ]] && VARNAME="CLAUDE_CODE_OAUTH_TOKEN"
    printf 'export %s=%q\n' "$VARNAME" "$CLTOK" > "${D}/etc/profile.d/claude-cred.sh"
    chmod 600 "${D}/etc/profile.d/claude-cred.sh"
    ok "Credencial gravada (${VARNAME}) — sessões novas de shell já nascem autenticadas"
  else
    warn "Sem token do Claude — rode ${BOLD}claude${C0} uma vez e faça login pelo link (ou cole um setup-token depois)."
  fi

  # CLAUDE.md: o Claude desta VPS nasce SABENDO a infra (e o projeto, se houver semente)
  mkdir -p "${D}/opt"
  if [[ -n "$SEED" && -f "${SEED_DIR}/CLAUDE.md" ]]; then
    sed -e "s/{{SLUG}}/${SLUG}/g" -e "s/{{PROJ_NAME}}/${PROJ_NAME}/g" \
        -e "s/{{APP_DOMAIN}}/${APP_DOMAIN}/g" -e "s/{{DATA}}/$(date '+%Y-%m-%d')/g" \
        "${SEED_DIR}/CLAUDE.md" > "${D}/opt/CLAUDE.md"
    ok "CLAUDE.md da semente '${SEED}' semeado em /opt — o Claude daqui já nasce sabendo o projeto"
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
- Secrets no Swarm (fonte única, NUNCA copiar valor em texto plano): ${SLUG}_pg_password,
  ${SLUG}_jwt_secret${TGTOK:+, ${SLUG}_tg_token}${OAKEY:+, ${SLUG}_openai_key}. Ler em runtime via /run/secrets/.
- App: template pronto em /opt/${SLUG}/app.yml (imagem \`${SLUG}-api\`, porta 3000,
  host ${APP_DOMAIN}); deploy: \`docker stack deploy -c /opt/${SLUG}/app.yml ${SLUG}-app\`.
- Gestão SÓ-TAILNET: Portainer :9000${QUER_MOLT:+, moltbot :18789} (lockdown na chain DOCKER-USER + unit
  gestao-lockdown; porta publicada pelo Docker ignora ufw). Rota /admin da app: middleware
  \`tailnet-only\` + priority 2000 (exemplo comentado no app.yml).
- Backup: pg_dump diário 03:10 → /var/backups/${SLUG} (retenção 14d). Offsite: guard
  (bash <(curl -fsSL https://get.motobot.com.br/guard)).

## Postura
- Commitar mudanças relevantes (git) e reportar resultado real, inclusive falhas.
- Segredo novo = docker secret; nunca hardcode, nunca .env commitado.
EOF
    ok "CLAUDE.md da infra semeado em /opt — o Claude daqui já nasce sabendo o servidor"
  fi
  cred ""; cred "Claude Code: instalado${CLTOK:+, autenticado} — abrir com 'claude' dentro de /opt"
}

# ── etapa 8: moltbot (agente pessoal) ────────────────────────────────────────
moltbot_stack(){
  say "\n${BOLD}[8/9] Moltbot — agente pessoal (OpenClaw)${C0}"
  [[ "$QUER_MOLT" =~ ^[sS] ]] || { info "pulado — instale depois rodando o script de novo"; return; }
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
  run "docker stack deploy -c /opt/${SLUG}/moltbot.yml moltbot >/dev/null"
  ok "Moltbot no ar — painel: ${BOLD}http://${TSIP:-<ip-tailnet>}:18789/?token=${GWTOK}${C0} ${DIM}(só com Tailscale ligado)${C0}"
  info "1º acesso: o browser vira device 'Pending' — aprove com: docker exec -it \$(docker ps -q -f name=moltbot_moltbot) clawdbot devices approve <requestId>"
  if [[ -n "$MOLT_TG" ]]; then
    info "conectar o Telegram: docker exec -it \$(docker ps -q -f name=moltbot_moltbot) clawdbot channels add --channel telegram --token ${MOLT_TG}"
    info "depois: docker service update --force moltbot_moltbot  (NUNCA docker restart — vira zumbi no Swarm)"
  fi
  cred ""; cred "Moltbot (gestão, só-tailnet): http://${TSIP:-<ip-tailnet>}:18789"
  cred "  gateway token (CONTROLE TOTAL — não compartilhar): ${GWTOK}"
  [[ -n "$MOLT_TG" ]] && cred "  bot Telegram: token informado (conectar via 'clawdbot channels add')"
}

# ── etapa 9: backup ──────────────────────────────────────────────────────────
backup_cron(){
  say "\n${BOLD}[9/9] Backup do banco — desde o dia um${C0}"
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
  if [[ "$DRY" == "--dry-run" ]]; then
    say "  ${DIM}[dry-run] instalaria cron 03:10 → /opt/${SLUG}/backup.sh${C0}"
  else
    ( crontab -l 2>/dev/null | grep -v "${SLUG}/backup.sh"; echo "10 3 * * * /opt/${SLUG}/backup.sh >> /var/log/${SLUG}-backup.log 2>&1" ) | crontab -
  fi
  ok "pg_dump diário 03:10 → /var/backups/${SLUG} (retenção 14 dias)"
  warn "Backup LOCAL não salva de disco morto: rode também a blindagem c/ envio pra nuvem:"
  say "     ${BOLD}bash <(curl -fsSL https://get.motobot.com.br/guard)${C0}"
}

# ── resumo ───────────────────────────────────────────────────────────────────
resumo(){
  say "\n${GRN}${BOLD}═══ Fundação do ${PROJ_NAME} pronta ═══${C0}\n"
  say "  Projeto:     ${BOLD}https://${APP_DOMAIN}${C0} ${DIM}(no ar quando a sua app subir)${C0}"
  say "  Gestão:      ${BOLD}http://${TSIP:-<ip-tailnet>}:9000${C0} ${DIM}(Portainer — SÓ com Tailscale ligado)${C0}"
  say "  Banco:       ${SLUG}_postgres (db ${SLUG}, pgvector${SEED:+, schema da semente '${SEED}'})"
  say "  Fila/sessão: ${SLUG}_redis"
  say "  Credenciais: ${BOLD}/root/${SLUG}-credenciais.txt${C0} ${DIM}(chmod 600 — anote e apague)${C0}"
  say ""
  say "  ${BOLD}Pra começar a construir:${C0}"
  say "   ${LRJ}cd /opt && claude${C0}   ${DIM}← o CLAUDE.md daqui já apresenta o servidor pra ele${C0}"
  say ""
  [[ "$DRY" == "--dry-run" ]] && warn "Foi um dry-run: nada foi alterado no servidor (escritas em ${D})."
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
moltbot_stack
backup_cron
resumo
