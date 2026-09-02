# Base de chatbot WhatsApp — Motobase

Bot WhatsApp **nativo** na RyzeAPI (mesma do Motobot) + Claude. Ponto de partida:
recebe mensagem, responde com a LLM (memória por contato), envia de volta.
Troque `SYSTEM_PROMPT` e a lógica de `responder()`/`/webhook/wa` pelo seu produto.

## Config (secrets/env)
- `RYZE_ACCOUNT_TOKEN` (secret) — token da conta Ryze (envio + instância).
- `RYZE_INSTANCE` (env) — nome da instância = número próprio do bot (não o do Motobot).
- `ANTHROPIC_API_KEY` (secret) — chave da API (sk-ant-api…).
- `WA_WEBHOOK_TOKEN` (secret, opcional) — protege o `/webhook/wa`.
- `MODEL` (claude-haiku-4-5), `MAX_TOKENS`, `MEM_TURNS`, `SYSTEM_PROMPT`.

## Parear o número
`GET /connect` (tailnet) devolve o QR; escaneie no WhatsApp. `GET /status` mostra a conexão.
O `/webhook/wa` é **público** (a Ryze precisa alcançar) — protegido pelo `WA_WEBHOOK_TOKEN`.
