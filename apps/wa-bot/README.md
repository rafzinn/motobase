# Base de chatbot WhatsApp — Motobase

Bot WhatsApp **nativo** na RyzeAPI (mesma do Motobot) + OpenAI (`gpt-4o-mini`). Ponto de partida:
recebe mensagem, responde com a LLM (memória por contato em SQLite), envia de volta.
Troque `SYSTEM_PROMPT` e a lógica de `responder()`/`/webhook/wa` pelo seu produto.

## Config (secrets/env)
- `RYZE_ACCOUNT_TOKEN` (secret `ryze_account_token`) — token da conta Ryze (envio + instância).
- `RYZE_INSTANCE` (env) — nome da instância = número próprio do bot (não o do Motobot).
- `OPENAI_API_KEY` (secret `openai_api_key`) — chave da OpenAI (sk-proj-…). `OPENAI_BASE_URL` opcional (compatíveis).
- `WA_WEBHOOK_TOKEN` (secret, opcional) — protege o `/webhook/wa`.
- `WA_WEBHOOK_URL` (env) — `https://bot.<domínio>/webhook/wa`; o bot registra na Ryze sozinho no boot (com retry).
- `MODEL` (gpt-4o-mini), `MAX_TOKENS`, `MEM_TURNS`, `SYSTEM_PROMPT`, `DATA_DIR` (/data).

## Parear o número
`GET /connect` (tailnet) devolve o QR; escaneie no WhatsApp. `GET /status` mostra a conexão.
O `/webhook/wa` é **público** (a Ryze precisa alcançar) — protegido pelo `WA_WEBHOOK_TOKEN`.
`GET /healthz` diz se a chave e o token da Ryze chegaram no container.
