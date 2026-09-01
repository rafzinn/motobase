<div align="center">

# 🦀 Motobase

**Do zero à base da sua startup. Em uma linha.**

Infra pronta para criar, publicar e crescer sem bagunça.

Instale a fundação uma vez. Volte quando quiser para criar o próximo projeto.

```bash
bash <(curl -fsSL https://get.motobot.com.br)
```

*por [Rafael Ventura](https://github.com/rafzinn) × Fable 5*

</div>

## Como funciona

O mesmo comando tem dois comportamentos:

1. Em uma VPS nova, instala a fundação completa.
2. Em uma VPS com Motobase, abre o gerenciador de projetos.

A fundação não é reinstalada quando um projeto novo é criado.

## Fundação

- Docker Swarm e rede overlay;
- Traefik com HTTPS automático;
- Portainer acessível somente pela Tailnet;
- Beszel Hub + Agent para saúde, consumo e containers, somente pela Tailnet;
- PostgreSQL 16 com pgvector;
- Redis 7 com persistência e senha em Docker Secret;
- Tailscale e bloqueio das portas administrativas;
- Docker Secrets;
- fail2ban e atualizações de segurança automáticas;
- Claude Code e GitHub CLI;
- backup local diário;
- smoke tests ao final.

Após validar a conexão privada, rode `motobase preparar-ssh`, teste o acesso
como `mbadmin` em outro terminal e só então rode `motobase blindar-ssh`. Esse
fluxo desliga senha/root direto e permite SSH somente pela Tailnet sem arriscar
trancar quem está instalando para fora da VPS.

Os painéis já nascem registrados em DNS privado: Portainer em
`http://portainer.<domínio>:9000` e Beszel em `http://monitor.<domínio>:8090`.
Ambos resolvem para o IP Tailscale da VPS e só abrem dentro da Tailnet.
O wizard pergunta somente nome interno da VPS/cliente, domínio base, e-mail e credenciais opcionais de
Cloudflare, Claude, OpenAI, Telegram e Tailscale. Senhas internas e decisões
técnicas são geradas automaticamente.

Na fundação, nenhum site ou aplicação é criado. Com o token da Cloudflare, o
wizard cria somente `portainer.<domínio>` e `monitor.<domínio>` para os painéis
privados após conectar a VPS à Tailnet. Ao criar um site ou WordPress depois,
ele sugere automaticamente `nome-do-projeto.<domínio>` — e você pode trocar
por outro domínio completo se precisar.

## Contas e credenciais

Nada de uma VPS anterior é reutilizado. Para uma instalação totalmente nova:

| Plataforma | Usada para | Credencial | Momento |
|---|---|---|---|
| Cloudflare DNS | Criar os endereços dos painéis e projetos | Token `Edit zone DNS` da zona do cliente | Instalação-base / novo projeto |
| Tailscale | Rede privada dos painéis | Auth key de uso único e não efêmera | Instalação-base |
| Claude | Programação na VPS | Token/API key, opcional | Instalação-base |
| OpenAI | IA das futuras aplicações | API key de projeto, opcional | Instalação-base |
| Telegram | Bots e alertas futuros | Token criado pelo BotFather, opcional | Instalação-base |
| Cloudflare R2 | Backup externo | Endpoint S3 + Access Key ID + Secret Access Key | Módulo `/guard` |
| GitHub | Cópia externa do código | Fine-grained token | Módulo `/guard` |

O token de DNS da Cloudflare e as credenciais do R2 são independentes. O
monitor externo via Cloudflare Worker ainda não é provisionado pelo wizard;
ele é uma integração separada.

Todos os tokens, chaves e endpoints de conta são digitados em campos ocultos.
A conferência final informa apenas se a credencial foi fornecida, sem mostrar
prefixos ou fragmentos — adequado para instalação durante aulas gravadas.

## Projetos disponíveis

### Site simples

Cria uma stack independente com Nginx, domínio, HTTPS, diretório persistente,
backup e smoke test.

```bash
bash <(curl -fsSL https://get.motobot.com.br) --site
```

Arquivos ficam em `/opt/projetos/<slug>/public`.

### WordPress limpo

Cria uma stack independente com WordPress, MariaDB própria, Redis próprio,
volumes persistentes, Docker Secrets, domínio, HTTPS, backup do banco e dos
arquivos e smoke tests autenticados.

```bash
bash <(curl -fsSL https://get.motobot.com.br) --wordpress
```

Depois do deploy, o primeiro acesso ao domínio conclui o cadastro do título e
do administrador do WordPress.

## Gerenciamento

Executar o comando sem argumentos abre o menu:

```text
[1] Novo site simples       [2] Novo WordPress
[3] Meus projetos           [4] Saúde da VPS
[0] Sair
```

Também é possível rodar o diagnóstico diretamente:

```bash
bash <(curl -fsSL https://get.motobot.com.br) --status
```

Cada projeto tem stack, rede interna, volumes, secrets e backup próprios. Só o
serviço web participa da rede pública do Traefik.

## Simulação segura

Para percorrer um fluxo e gerar os arquivos em um diretório temporário, sem
criar serviços, redes ou secrets:

```bash
bash <(curl -fsSL https://get.motobot.com.br) --dry-run --site
bash <(curl -fsSL https://get.motobot.com.br) --dry-run --wordpress
```

## Blindagem externa

O backup local protege contra erro operacional, mas não contra perda do disco.
Para firewall, SSH por chave, fail2ban e backup externo no Cloudflare R2:

```bash
bash <(curl -fsSL https://get.motobot.com.br/guard)
```
