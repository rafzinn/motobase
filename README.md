<div align="center">

# 🦀 Motobase

**Uma base. Muitos projetos. Tudo no lugar.**

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
- Redis 7 com persistência;
- Tailscale e bloqueio das portas administrativas;
- Docker Secrets;
- Claude Code e GitHub CLI;
- backup local diário;
- smoke tests ao final.

Os painéis já nascem registrados em DNS privado: Portainer em
`http://portainer.<domínio>:9000` e Beszel em `http://monitor.<domínio>:8090`.
Ambos resolvem para o IP Tailscale da VPS e só abrem dentro da Tailnet.
O wizard pergunta somente nome, domínio, e-mail e credenciais opcionais de
Cloudflare, Claude, OpenAI, Telegram e Tailscale. Senhas internas e decisões
técnicas são geradas automaticamente.

Quando o token da Cloudflare é informado, o wizard pede o domínio principal e
o subdomínio personalizado separadamente, cria o registro A no começo da
instalação e aproveita o restante do processo para a propagação do DNS.

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
