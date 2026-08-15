#!/usr/bin/env bash
# =============================================================================
#  🤝 SOMOS UM — plataforma de mandato participativo, VPS em uma linha
#
#  bash <(curl -fsSL https://get.motobot.com.br/somosum)
#
#  Sobe a fundação completa do Somos Um numa VPS zerada:
#    Docker Swarm → Traefik (HTTPS automático) → Postgres+pgvector → Redis
#    → schema do banco aplicado → Tailscale + Portainer só-tailnet (gestão)
#    → terreno pronto pra aplicação (API + bot).
#  Senhas fortes geradas na hora, guardadas como Docker secrets.
#
#  Por Rafael Ventura (github.com/rafzinn) × Fable 5.
# =============================================================================
set -euo pipefail

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

DRY=${1:-}
D=""   # prefixo de escrita: em dry-run, NADA toca o disco real
if [[ "$DRY" == "--dry-run" ]]; then D=$(mktemp -d); fi
run(){ if [[ "$DRY" == "--dry-run" ]]; then say "  ${DIM}[dry-run]${C0} $*"; else eval "$@"; fi; }

CRED="${D}/root/somosum-credenciais.txt"
cred(){ echo "$*" >> "$CRED"; }

banner(){
  say ""
  say "  ${LRJ}  ██╗${C0}${DIM}██╗${C0}      ${BOLD}S O M O S   U M${C0}"
  say "  ${LRJ}  ██║${C0}${DIM}██║${C0}      ${DIM}eu e você somos um${C0}"
  say "  ${LRJ}  ╚═╝${C0}${DIM}╚═╝${C0}      ${DIM}mandato participativo — por Rafael Ventura × Fable 5${C0}"
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
  mkdir -p "${D}/root"
  : > "$CRED"; chmod 600 "$CRED"
  cred "══════ SOMOS UM — credenciais geradas em $(date '+%d/%m/%Y %H:%M') ══════"
  cred "Servidor: $(hostname)  IP: ${IP}"
}

# ── etapa 1: docker + swarm ──────────────────────────────────────────────────
docker_swarm(){
  say "\n${BOLD}[1/7] Docker + Swarm${C0}"
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

# ── etapa 2: domínio ─────────────────────────────────────────────────────────
domain_step(){
  say "\n${BOLD}[2/7] Domínio${C0}"
  say ""
  say "  ${AMB}┌─────────────────────────  ANTES DE CONTINUAR  ─────────────────────────┐${C0}"
  say "  ${AMB}│${C0} No painel do seu DNS (Cloudflare etc.), crie um registro tipo ${BOLD}A${C0}       ${AMB}│${C0}"
  say "  ${AMB}│${C0} apontando o domínio da plataforma pro IP deste servidor: ${BOLD}${IP}${C0}"
  say "  ${AMB}│${C0} DICA: na primeira emissão do HTTPS deixe a nuvem ${BOLD}CINZA${C0} (DNS only).    ${AMB}│${C0}"
  say "  ${AMB}└────────────────────────────────────────────────────────────────────────┘${C0}"
  say ""
  ask APP_DOMAIN "Domínio da plataforma (ex: somosum.seudominio.com.br)"
  [[ -n "$APP_DOMAIN" ]] || die "Preciso de um domínio."
  ask LE_EMAIL "E-mail pro certificado HTTPS (Let's Encrypt)" "admin@${APP_DOMAIN#*.}"
  info "conferindo propagação de ${APP_DOMAIN}…"
  local resolved; resolved=$(getent hosts "$APP_DOMAIN" | awk '{print $1}' | head -1 || true)
  if [[ "$resolved" == "$IP" ]]; then ok "DNS propagado: ${APP_DOMAIN} → ${IP}"
  elif [[ -n "$resolved" ]]; then warn "${APP_DOMAIN} resolve pra ${resolved} (esperava ${IP}). Se a nuvem laranja está ligada, é normal."
  else warn "Ainda não resolve — o HTTPS pode falhar na 1ª tentativa e se corrigir sozinho depois."
  fi
  cred ""; cred "Plataforma: https://${APP_DOMAIN}"
}

# ── etapa 3: traefik ─────────────────────────────────────────────────────────
traefik_stack(){
  say "\n${BOLD}[3/7] Traefik — o porteiro HTTPS${C0}"
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

# ── etapa 4: banco + redis (com secrets) ─────────────────────────────────────
dados_stack(){
  say "\n${BOLD}[4/7] Dados — Postgres+pgvector e Redis${C0}"
  local PGP; PGP=$(pw)
  if ! docker secret inspect somosum_pg_password >/dev/null 2>&1; then
    run "printf '%s' '${PGP}' | docker secret create somosum_pg_password - >/dev/null"
  else
    warn "secret somosum_pg_password já existe — mantendo a senha atual"
    PGP="(já existia — veja o registro anterior)"
  fi
  mkdir -p "${D}/opt/somosum"
  cat > "${D}/opt/somosum/stack.yml" <<EOF
version: "3.8"
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/somosum_pg_password
      POSTGRES_DB: somosum
    secrets: [somosum_pg_password]
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
  somosum_pg_password: { external: true }
volumes: { pgdata: {}, redisdata: {} }
EOF
  run "docker stack deploy -c /opt/somosum/stack.yml somosum >/dev/null"
  ok "Postgres+pgvector (host interno: ${BOLD}somosum_postgres${C0}) e Redis (${BOLD}somosum_redis${C0}) no ar"
  info "rede 'somosum_internal': banco e redis NÃO ficam expostos na web"
  cred ""; cred "Postgres: host somosum_postgres:5432  db somosum  user postgres"
  cred "  senha: ${PGP}  (fonte de verdade: docker secret somosum_pg_password)"
  cred "Redis: host somosum_redis:6379 (rede interna, sem senha)"
}

# ── etapa 4b: schema ─────────────────────────────────────────────────────────
schema_ddl(){
  say "\n  ${LRJ}▸ Aplicando schema do banco${C0}"
  cat > "${D}/opt/somosum/ddl.sql" <<'EOSQL'
create schema if not exists somosum;
create extension if not exists vector;

create table if not exists somosum.setores (
  id serial primary key,
  nome text not null,
  ativo boolean not null default true
);

create table if not exists somosum.cidadaos (
  id bigserial primary key,
  tg_user_id bigint not null unique,
  nome text,
  setor_id int references somosum.setores(id),
  consentiu_em timestamptz,
  consent_versao text,
  bloqueado boolean not null default false,
  criado_em timestamptz not null default now()
);

create table if not exists somosum.usuarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  email text not null unique,
  senha_hash text not null,
  papel text not null check (papel in ('mediador','conselho','deputado','admin')),
  ativo boolean not null default true
);

create table if not exists somosum.causas (
  id bigserial primary key,
  titulo text not null,
  resumo text,
  trilha text not null check (trilha in ('chamado','ideia')),
  tema text,
  competencia text check (competencia in
    ('estadual','municipal','federal','concessionaria','outra')),
  instrumento_sugerido text,
  setor_id int references somosum.setores(id),
  apoios int not null default 0,
  status text not null default 'fila' check (status in
    ('fila','em_analise','no_conselho','aprovada','rejeitada',
     'devolvida','com_deputado','em_execucao','concluida')),
  criada_em timestamptz not null default now()
);

create table if not exists somosum.demandas (
  id bigserial primary key,
  protocolo text not null unique,
  cidadao_id bigint not null references somosum.cidadaos(id),
  causa_id bigint references somosum.causas(id),
  trilha text not null check (trilha in ('chamado','ideia')),
  relato text not null,
  midia jsonb not null default '[]',
  local_texto text,
  setor_id int references somosum.setores(id),
  tema text,
  competencia text,
  urgencia text,
  instrumento_sugerido text,
  triagem jsonb,
  embedding vector(1536),
  status text not null default 'recebida' check (status in
    ('recebida','triada','em_causa','aguardando_info','arquivada')),
  criada_em timestamptz not null default now()
);
create index if not exists demandas_causa_idx on somosum.demandas (causa_id);
create index if not exists demandas_cidadao_idx on somosum.demandas (cidadao_id);

create table if not exists somosum.apoios (
  causa_id bigint not null references somosum.causas(id),
  cidadao_id bigint not null references somosum.cidadaos(id),
  criado_em timestamptz not null default now(),
  primary key (causa_id, cidadao_id)
);

create table if not exists somosum.conselho_votos (
  id bigserial primary key,
  causa_id bigint not null references somosum.causas(id),
  usuario_id uuid not null references somosum.usuarios(id),
  voto text not null check (voto in ('aprova','rejeita','devolve')),
  justificativa text,
  criado_em timestamptz not null default now(),
  unique (causa_id, usuario_id)
);

create table if not exists somosum.acoes_mandato (
  id bigserial primary key,
  causa_id bigint not null references somosum.causas(id),
  tipo text not null check (tipo in
    ('indicacao','emenda','projeto_lei','requerimento',
     'audiencia','oficio','encaminhamento')),
  orgao_destino text,
  numero_oficial text,
  descricao text,
  status text not null default 'decidida' check (status in
    ('decidida','protocolada','em_execucao','concluida','negada')),
  decidida_por uuid references somosum.usuarios(id),
  criada_em timestamptz not null default now()
);

create table if not exists somosum.eventos (
  id bigserial primary key,
  entidade text not null,
  entidade_id bigint not null,
  tipo text not null,
  ator_tipo text not null,
  ator_id text,
  payload jsonb,
  criado_em timestamptz not null default now()
);
create index if not exists eventos_entidade_idx on somosum.eventos (entidade, entidade_id);

create table if not exists somosum.notificacoes (
  id bigserial primary key,
  cidadao_id bigint not null references somosum.cidadaos(id),
  demanda_id bigint,
  causa_id bigint,
  mensagem text not null,
  status text not null default 'pendente'
    check (status in ('pendente','enviada','falhou')),
  tentativas int not null default 0,
  criada_em timestamptz not null default now(),
  enviada_em timestamptz
);
EOSQL
  if [[ "$DRY" == "--dry-run" ]]; then
    say "  ${DIM}[dry-run] aplicaria o DDL em somosum_postgres${C0}"
  else
    info "aguardando o Postgres subir…"
    local i=0 CID=""
    until CID=$(docker ps -q -f name=somosum_postgres | head -1) && [[ -n "$CID" ]] \
      && docker exec "$CID" pg_isready -U postgres >/dev/null 2>&1; do
      i=$((i+1)); [[ $i -gt 60 ]] && die "Postgres não subiu em 2 minutos — veja: docker service ps somosum_postgres"
      sleep 2
    done
    docker exec -i "$CID" psql -U postgres -d somosum -v ON_ERROR_STOP=1 < /opt/somosum/ddl.sql >/dev/null
  fi
  ok "Schema ${BOLD}somosum${C0} aplicado (10 tabelas + pgvector)"
}

# ── etapa 5: tailscale + gestão só-tailnet ───────────────────────────────────
tailscale_gestao(){
  say "\n${BOLD}[5/7] Tailscale — gestão fora da internet pública${C0}"
  info "Portainer (e futuras telas de admin) só vão abrir com o Tailscale ligado no SEU dispositivo."
  if ! command -v tailscale >/dev/null; then
    info "instalando Tailscale (script oficial)…"
    run "curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1"
  fi
  ask TSKEY "Auth key do Tailscale (tskey-…; Enter pra logar por link no navegador)" ""
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
  mkdir -p "${D}/opt/somosum" "${D}/usr/local/sbin" "${D}/etc/systemd/system"
  cat > "${D}/opt/somosum/portainer.yml" <<'EOF'
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
  run "docker stack deploy -c /opt/somosum/portainer.yml portainer >/dev/null"

  # LIÇÃO (Motobot 2026-08-02): porta publicada pelo Docker IGNORA o ufw.
  # O trinco de verdade é na chain DOCKER-USER — e precisa sobreviver a reboot.
  cat > "${D}/usr/local/sbin/somosum-lockdown.sh" <<'EOF'
#!/usr/bin/env bash
# Trava portas de GESTÃO pra aceitarem só tailnet (100.64/10) e localhost.
set -e
PORTS="9000"
iptables -N SOMOSUM-GESTAO 2>/dev/null || true
iptables -F SOMOSUM-GESTAO
for p in $PORTS; do
  iptables -A SOMOSUM-GESTAO -p tcp --dport "$p" -s 100.64.0.0/10 -j RETURN
  iptables -A SOMOSUM-GESTAO -p tcp --dport "$p" -s 127.0.0.0/8    -j RETURN
  iptables -A SOMOSUM-GESTAO -p tcp --dport "$p" -j DROP
done
iptables -C DOCKER-USER -j SOMOSUM-GESTAO 2>/dev/null || iptables -I DOCKER-USER 1 -j SOMOSUM-GESTAO
EOF
  chmod +x "${D}/usr/local/sbin/somosum-lockdown.sh"
  cat > "${D}/etc/systemd/system/somosum-lockdown.service" <<'EOF'
[Unit]
Description=Somos Um - trava portas de gestao pra tailnet
After=docker.service tailscaled.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/somosum-lockdown.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  run "systemctl daemon-reload && systemctl enable --now somosum-lockdown.service >/dev/null 2>&1"
  ok "Portainer: ${BOLD}http://${TSIP}:9000${C0} ${DIM}(SÓ com Tailscale ligado; crie o admin no 1º acesso — expira em 5min)${C0}"
  info "do IP público, a porta 9000 simplesmente não responde (DROP na DOCKER-USER, persistente)"
  cred ""; cred "Portainer (gestão, só-tailnet): http://${TSIP}:9000"
  cred "IP tailnet do servidor: ${TSIP}"
}

# ── etapa 6: segredos da aplicação ───────────────────────────────────────────
app_secrets(){
  say "\n${BOLD}[6/7] Segredos da aplicação${C0} ${DIM}(Enter pra pular e cadastrar depois)${C0}"
  ask TGTOK "Token do bot do Telegram (do @BotFather)" ""
  if [[ -n "$TGTOK" ]] && ! docker secret inspect somosum_tg_token >/dev/null 2>&1; then
    run "printf '%s' '${TGTOK}' | docker secret create somosum_tg_token - >/dev/null"
    ok "secret somosum_tg_token criado"
  fi
  ask OAKEY "Chave da OpenAI (sk-…)" ""
  if [[ -n "$OAKEY" ]] && ! docker secret inspect somosum_openai_key >/dev/null 2>&1; then
    run "printf '%s' '${OAKEY}' | docker secret create somosum_openai_key - >/dev/null"
    ok "secret somosum_openai_key criado"
  fi
  local JWTS; JWTS=$(pw)$(pw)
  if ! docker secret inspect somosum_jwt_secret >/dev/null 2>&1; then
    run "printf '%s' '${JWTS}' | docker secret create somosum_jwt_secret - >/dev/null"
    ok "secret somosum_jwt_secret criado (login do painel)"
  fi
  cred ""; cred "Secrets no Swarm: somosum_pg_password, somosum_jwt_secret${TGTOK:+, somosum_tg_token}${OAKEY:+, somosum_openai_key}"
  cred "  (cadastrar depois: printf '%s' 'VALOR' | docker secret create NOME -)"

  # template da stack da aplicação — deploy quando a API existir
  cat > "${D}/opt/somosum/app.yml" <<EOF
version: "3.8"
services:
  api:
    image: somosum-api:latest
    environment:
      APP_DOMAIN: ${APP_DOMAIN}
      PG_HOST: somosum_postgres
      REDIS_URL: redis://somosum_redis:6379
    secrets: [somosum_pg_password, somosum_jwt_secret, somosum_tg_token, somosum_openai_key]
    networks: [somosum_internal, web]
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.routers.somosum.rule=Host(\`${APP_DOMAIN}\`)
        - traefik.http.routers.somosum.entrypoints=websecure
        - traefik.http.routers.somosum.tls.certresolver=le
        - traefik.http.services.somosum.loadbalancer.server.port=3000
        # ── rota de ADMIN MASTER (descomentar quando existir /admin na API) ──
        # Só-tailnet via middleware definido no Traefik. priority=2000 OBRIGATÓRIO
        # se algum dia houver router com PathPrefix genérico (lição Motobot 08-02).
        # - traefik.http.routers.somosum-adm.rule=Host(\`${APP_DOMAIN}\`) && PathPrefix(\`/admin\`)
        # - traefik.http.routers.somosum-adm.entrypoints=websecure
        # - traefik.http.routers.somosum-adm.tls.certresolver=le
        # - traefik.http.routers.somosum-adm.middlewares=tailnet-only
        # - traefik.http.routers.somosum-adm.priority=2000
        # - traefik.http.routers.somosum-adm.service=somosum
networks:
  somosum_internal: { external: true }
  web: { external: true }
secrets:
  somosum_pg_password: { external: true }
  somosum_jwt_secret: { external: true }
  somosum_tg_token: { external: true }
  somosum_openai_key: { external: true }
EOF
  ok "Template da aplicação em ${BOLD}/opt/somosum/app.yml${C0} ${DIM}(deploy quando a API for construída)${C0}"
}

# ── etapa 6: backup ──────────────────────────────────────────────────────────
backup_cron(){
  say "\n${BOLD}[7/7] Backup do banco — desde o dia um${C0}"
  mkdir -p "${D}/var/backups/somosum" "${D}/opt/somosum"
  cat > "${D}/opt/somosum/backup.sh" <<'EOF'
#!/usr/bin/env bash
# backup diário do banco do Somos Um (retenção 14 dias)
set -euo pipefail
CID=$(docker ps -q -f name=somosum_postgres | head -1)
[[ -n "$CID" ]] || { echo "postgres fora do ar"; exit 1; }
DEST=/var/backups/somosum
docker exec "$CID" pg_dump -U postgres -d somosum | gzip > "${DEST}/somosum-$(date +%F).sql.gz"
find "$DEST" -name 'somosum-*.sql.gz' -mtime +14 -delete
EOF
  chmod +x "${D}/opt/somosum/backup.sh"
  if [[ "$DRY" == "--dry-run" ]]; then
    say "  ${DIM}[dry-run] instalaria cron 03:10 → /opt/somosum/backup.sh${C0}"
  else
    ( crontab -l 2>/dev/null | grep -v somosum/backup.sh; echo "10 3 * * * /opt/somosum/backup.sh >> /var/log/somosum-backup.log 2>&1" ) | crontab -
  fi
  ok "pg_dump diário 03:10 → /var/backups/somosum (retenção 14 dias)"
  warn "Backup LOCAL não salva de disco morto: rode também a blindagem c/ envio pra nuvem:"
  say "     ${BOLD}bash <(curl -fsSL https://get.motobot.com.br/guard)${C0}"
}

# ── resumo ───────────────────────────────────────────────────────────────────
resumo(){
  say "\n${GRN}${BOLD}═══ Fundação do Somos Um pronta ═══${C0}\n"
  say "  Plataforma:  ${BOLD}https://${APP_DOMAIN}${C0} ${DIM}(no ar quando a API subir)${C0}"
  say "  Gestão:      ${BOLD}http://${TSIP:-<ip-tailnet>}:9000${C0} ${DIM}(Portainer — SÓ com Tailscale ligado)${C0}"
  say "  Banco:       somosum_postgres (schema somosum, 10 tabelas, pgvector)"
  say "  Fila/sessão: somosum_redis"
  say "  Credenciais: ${BOLD}/root/somosum-credenciais.txt${C0} ${DIM}(chmod 600 — anote e apague)${C0}"
  say ""
  say "  ${BOLD}Próximos passos:${C0}"
  say "   1. Construir a API + bot (Fase 1 do blueprint) e gerar a imagem somosum-api"
  say "   2. ${DIM}docker stack deploy -c /opt/somosum/app.yml somosum-app${C0}"
  say "   3. Registrar o webhook do bot no Telegram (a API faz isso ao subir)"
  say "   4. Rodar o guard (blindagem + backup na nuvem)"
  say ""
  [[ "$DRY" == "--dry-run" ]] && warn "Foi um dry-run: nada foi alterado no servidor (escritas em ${D})."
}

banner
preflight
docker_swarm
domain_step
traefik_stack
dados_stack
schema_ddl
tailscale_gestao
app_secrets
backup_cron
resumo
