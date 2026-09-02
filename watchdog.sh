#!/usr/bin/env bash
# Motobase watchdog — telemetria do sistema + alerta no Telegram.
# Roda a cada poucos minutos (systemd timer). Só alerta quando o ESTADO muda
# (não faz spam). Usa a credencial OpenAI pra escrever um diagnóstico claro.
set -uo pipefail

CONF=/etc/motobase/watchdog.env
[[ -r "$CONF" ]] || exit 0
# shellcheck disable=SC1090
source "$CONF"

STATE_DIR=/var/lib/motobase
STATE="$STATE_DIR/watchdog.state"
mkdir -p "$STATE_DIR"
TG_API="https://api.telegram.org/bot${TG_TOKEN:-}"

# Descobre o chat id (o dono precisa mandar /start pro bot UMA vez) se ainda não temos.
if [[ -z "${TG_CHAT:-}" && -n "${TG_TOKEN:-}" ]]; then
  TG_CHAT=$(curl -s -m 8 "${TG_API}/getUpdates" 2>/dev/null \
    | grep -oE '"chat":\{"id":-?[0-9]+' | grep -oE -- '-?[0-9]+' | head -1 || true)
  if [[ -n "$TG_CHAT" ]]; then
    sed -i '/^TG_CHAT=/d' "$CONF" 2>/dev/null || true
    echo "TG_CHAT=$TG_CHAT" >> "$CONF"
  fi
fi

problemas=()
add(){ problemas+=("$1"); }

# 1) serviços essenciais de pé (réplicas completas)
for svc in traefik_traefik "${SLUG}_postgres" "${SLUG}_redis" portainer_portainer; do
  rep=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | awk -v s="$svc" '$1==s{print $2}')
  [[ -n "$rep" && "${rep%%/*}" == "${rep##*/}" && "${rep%%/*}" != "0" ]] || add "serviço ${svc} fora do ar (${rep:-inexistente})"
done
# 2) opcionais: se existem, têm que estar de pé
for svc in beszel_hub home_home chat_chat wabot_wabot; do
  docker service inspect "$svc" >/dev/null 2>&1 || continue
  rep=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | awk -v s="$svc" '$1==s{print $2}')
  [[ -n "$rep" && "${rep%%/*}" == "${rep##*/}" && "${rep%%/*}" != "0" ]] || add "serviço ${svc} caiu (${rep})"
done
# 3) disco e memória
duse=$(df / --output=pcent 2>/dev/null | tail -1 | tr -dc '0-9')
[[ "${duse:-0}" -ge 90 ]] && add "disco em ${duse}% (crítico)"
mem=$(free 2>/dev/null | awk '/Mem:/{if($2>0)printf "%d", $7/$2*100}')
[[ -n "${mem:-}" && "$mem" -le 8 ]] && add "memória disponível em ${mem}%"
# 4) endereços respondem de verdade (local, sem depender de DNS/Tailscale)
hit(){ curl -sk -m 8 -o /dev/null -w '%{http_code}' -H "Host: $1" "https://127.0.0.1${2:-/}" 2>/dev/null || echo 000; }
if [[ -n "${BASE_DOMAIN:-}" ]]; then
  c=$(hit "$BASE_DOMAIN" "/"); [[ "$c" == 200 ]] || add "home não responde (HTTP ${c})"
  docker service inspect chat_chat  >/dev/null 2>&1 && { c=$(hit "chat.${BASE_DOMAIN}" "/");      [[ "$c" =~ ^(200|304|401)$ ]] || add "chat não responde (HTTP ${c})"; }
  docker service inspect wabot_wabot >/dev/null 2>&1 && { c=$(hit "bot-admin.${BASE_DOMAIN}" "/"); [[ "$c" == 200 ]] || add "pareamento do bot não responde (HTTP ${c})"; }
fi

# Só alerta se o estado MUDOU desde a última checagem (nada de spam).
assinatura=$(printf '%s\n' "${problemas[@]:-}" | sort | md5sum | awk '{print $1}')
anterior=$(cat "$STATE" 2>/dev/null || echo "")
[[ "$assinatura" == "$anterior" ]] && exit 0
echo "$assinatura" > "$STATE"

# Monta a mensagem
if [[ ${#problemas[@]} -eq 0 ]]; then
  msg="✅ ${PROJ_NAME:-VPS} — tudo normalizado. Serviços e endereços respondendo."
else
  lista=$(printf '• %s\n' "${problemas[@]}")
  msg="⚠️ ${PROJ_NAME:-VPS} — ${#problemas[@]} irregularidade(s) detectada(s):
${lista}"
  # OpenAI escreve um diagnóstico curto + o conserto (se a chave existe e jq está aqui)
  if [[ -n "${OPENAI_KEY:-}" ]] && command -v jq >/dev/null 2>&1; then
    diag=$(curl -s -m 25 https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer ${OPENAI_KEY}" -H 'content-type: application/json' \
      -d "$(jq -nc --arg l "$lista" '{model:"gpt-4o-mini",max_tokens:220,messages:[
        {role:"system",content:"Voce e SRE. Em PT-BR, no maximo 3 linhas: causa provavel e o comando exato de conserto (Docker Swarm/Traefik). Direto, sem rodeios."},
        {role:"user",content:("Irregularidades numa VPS Motobase:\n"+$l)}]}')" 2>/dev/null \
      | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    [[ -n "$diag" ]] && msg="${msg}

🔎 ${diag}"
  fi
fi

# Envia pro Telegram (se temos token e chat id)
if [[ -n "${TG_TOKEN:-}" && -n "${TG_CHAT:-}" ]]; then
  curl -s -m 10 "${TG_API}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=${msg}" >/dev/null 2>&1
fi
exit 0
