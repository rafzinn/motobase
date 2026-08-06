<div align="center">

# 🦀 motobase

**Sua VPS de produção — em uma linha.**

A mesma fundação que roda um sistema real de delivery em produção,
instalada e configurada sozinha, com HTTPS de verdade e painel visual.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rafzinn/motobase/main/install.sh)
```

*por [Rafael Ventura](https://github.com/rafzinn) × Fable 5*

</div>

---

## O caminho completo (do absoluto zero)

> Nunca alugou um servidor? Perfeito. Segue a receita que em ~30 minutos você
> tem infraestrutura de gente grande no ar. Cada passo diz exatamente onde
> clicar.

### Passo 0 — O que você precisa comprar (uma vez só)

| O quê | Onde | Custo | Pra quê |
|---|---|---|---|
| **Um domínio** (ex: `meunegocio.com.br`) | [registro.br](https://registro.br) | ~R$ 40/ano | O endereço do seu sistema na internet |
| **Uma VPS** (um computador alugado na nuvem) | Hostinger, Contabo, DigitalOcean… | ~R$ 25–40/mês | Onde tudo vai rodar, 24h por dia |

Na hora de criar a VPS escolha: **Ubuntu 22.04 (ou mais novo)**, mínimo **2GB de RAM**.
Ao final, o provedor te dá um **IP** (ex: `203.0.113.10`) e uma **senha de root**. Guarde os dois.

### Passo 1 — Coloque o domínio na Cloudflare (grátis)

1. Crie uma conta em [cloudflare.com](https://cloudflare.com).
2. Clique **Add a site** → digite seu domínio → plano **Free**.
3. A Cloudflare vai te mostrar **2 nameservers** (ex: `ana.ns.cloudflare.com`).
4. Volte no **registro.br** → seu domínio → **Alterar servidores DNS** → cole os 2.
5. Espere o e-mail *"your site is active"* (minutos a poucas horas).

### Passo 2 — Aponte o domínio pro seu servidor

No painel da Cloudflare → seu domínio → **DNS** → **Add record**:

```
Tipo: A      Nome: @             Conteúdo: <IP da sua VPS>     Nuvem: CINZA
Tipo: A      Nome: portainer     Conteúdo: <IP da sua VPS>     Nuvem: CINZA
```

> ⚠ **A dica que ninguém te conta:** deixe a nuvem **CINZA** (DNS only) até o
> HTTPS ser emitido (cadeado verde no navegador). Depois, se quiser o escudo
> da Cloudflare, liga a nuvem laranja.
>
> Se for instalar n8n ou mais sites, crie também os registros deles
> (`n8n`, `www`, etc.) — o instalador te lembra na hora certa.

### Passo 3 — Entre no seu servidor

- **Windows**: abra o *PowerShell* · **Mac/Linux**: abra o *Terminal*
- Digite (com o SEU IP):

```bash
ssh root@203.0.113.10
```

Confirme com `yes`, cole a senha de root (ela não aparece ao digitar — é normal).

### Passo 4 — A linha

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rafzinn/motobase/main/install.sh)
```

O instalador conversa com você em português: pergunta seu domínio, seu e-mail,
e **qual combinação de stacks** você quer (ou `A` pra instalar tudo). Todas as
senhas são **geradas fortes** e salvas em `/root/motobase-credenciais.txt`.

### Passo 5 — Pronto. Isto está no ar:

| Serviço | Endereço | Primeiro acesso |
|---|---|---|
| **Portainer** (painel visual do servidor) | `https://portainer.seudominio` | Crie o admin **em até 5min** após instalar |
| **WordPress** (se escolheu) | `https://seudominio` | Assistente de instalação do WP |
| **n8n** (se escolheu) | `https://n8n.seudominio` | Crie a conta admin |
| **Site estático** (se escolheu) | `https://www.seudominio` | Edite `/opt/sites/...` — publica na hora |
| PostgreSQL / Redis (se escolheu) | internos (rede `web`) | senhas no arquivo de credenciais |

---

## O que a linha instala, por baixo do capô

| Peça | Papel |
|---|---|
| **Docker Swarm** | Orquestrador: cada serviço num container, com auto-restart se cair |
| **Traefik** | O porteiro: recebe todo acesso, emite e renova **HTTPS sozinho** (Let's Encrypt) |
| **Portainer** | Painel visual: veja logs, reinicie serviços, suba stacks sem terminal |
| **Rede `web`** | A avenida interna por onde os serviços conversam |
| Stacks à escolha | WordPress + MySQL + Redis · PostgreSQL · Redis · n8n · sites estáticos |

Regras de ouro que o instalador imprime no final (aprendidas em produção real):
nunca `docker restart` em serviço do Swarm (use `docker service update --force`),
nuvem laranja só depois do cadeado, backup não é opcional.

## O que este repositório NÃO é

Este repo é a **fundação** — o terreno, o alicerce e o quadro de energia.
O *cérebro* (bots de atendimento por voz, fluxos de venda, integrações de IA,
pagamentos automáticos) é o que construímos **nas aulas**, cada aluno criando
o seu, conversando com a IA — nenhuma linha dessa camada vive aqui.

👉 **Aula gratuita**: em breve o link — me segue em [github.com/rafzinn](https://github.com/rafzinn).

## Perguntas rápidas

**Posso rodar numa VPS que já uso pra outras coisas?**
O instalador detecta e te avisa antes de tocar em qualquer coisa. Mas o ideal é uma VPS limpa.

**O HTTPS não veio de primeira.**
Espere 1–2 minutos e recarregue. Persistindo, confira: nuvem CINZA e o registro A apontando pro IP certo.

**Perdi as senhas.**
`cat /root/motobase-credenciais.txt` no servidor. Copie pra um gerenciador de senhas e apague o arquivo.

**Quebrei tudo, e agora?**
Respira. `docker service ls` mostra o que está de pé. No Portainer dá pra reiniciar qualquer serviço com um clique. E é exatamente esse tipo de socorro que a gente treina nas aulas.

---

<div align="center">

**🦀 Feito. Agora fala com a IA e constrói em cima.**

</div>
