# {{PROJ_NAME}} — VPS dedicada (instalada em {{DATA}} via get.motobot.com.br/somosum)

Plataforma de mandato participativo. Slogan: "eu e você somos um" — o povo pauta,
a IA organiza, o conselho delibera, o deputado executa, e todo mundo vê.

## Documentos-fonte (LER antes de programar)
- Estudo de caso/pitch: https://claude.ai/code/artifact/a1d7c3bd-be88-425a-8fb3-941865c1d368
- Blueprint (schema, bot, agentes IA, fases): https://claude.ai/code/artifact/f4d88a9b-c964-4b6c-a31d-38d3257ef976

## Infra desta VPS (NÃO reinspecionar — instalada pelo vibe.sh)
- Docker Swarm + Traefik v2.11 (rede `web`, portas host-mode, certresolver `le`).
  NUNCA `docker restart`/`docker stop` em serviço Swarm (vira zumbi) — usar
  `docker service update --force <svc>`.
- Banco: `{{SLUG}}_postgres` (pgvector, db `{{SLUG}}`, schema `{{SLUG}}` com 10 tabelas
  prontas; DDL: /opt/{{SLUG}}/ddl.sql). Rede interna `{{SLUG}}_internal`.
- Redis: `{{SLUG}}_redis` (sessões do bot + filas).
- Secrets (fonte única, NUNCA copiar valor em texto): {{SLUG}}_pg_password,
  {{SLUG}}_jwt_secret, {{SLUG}}_tg_token, {{SLUG}}_openai_key. Ler via /run/secrets/.
- App: construir API Node/Express + bot Telegram + painel vanilla; imagem `{{SLUG}}-api`;
  deploy: `docker stack deploy -c /opt/{{SLUG}}/app.yml {{SLUG}}-app` (porta 3000,
  host {{APP_DOMAIN}}).
- Gestão SÓ-TAILNET: Portainer :9000, moltbot :18789 (lockdown DOCKER-USER + unit
  gestao-lockdown). Rota /admin da API: middleware `tailnet-only` + priority 2000
  (exemplo comentado no app.yml).
- Backup: pg_dump diário 03:10 → /var/backups/{{SLUG}} (retenção 14d). Offsite: guard.

## Regras de produto (duras)
- IA organiza e sugere; humano (conselho/deputado) decide. IA NUNCA arquiva/rejeita/
  responde mérito.
- Relato original do cidadão é intocável. Toda mudança de estado gera evento
  (auditoria) e o ciclo só fecha com retorno ao cidadão no Telegram
  (protocolo SU-AAAA-NNNNNN).
- Fases do blueprint: (1) API+bot sem IA → (2) triagem+agrupador →
  (3) painel/conselho/deputado → (4) outbox+página pública.
- LGPD (consent no bot, minimização) e fronteira TSE (mandato ≠ campanha) valem sempre.

## Preferências do dono
- Português BR, direto, SEM emojis. SEM frameworks JS (vanilla puro). SEM border-radius
  (quina perfeita; exceção só círculo/pílula de verdade).
- Identidade visual: base Claude — marfim-cinza quente + laranja terracota
  (#C15F3C claro / #E08862 escuro), grafite #262624 no escuro.
- Commitar mudanças relevantes (git) e reportar resultado real, inclusive falhas.
