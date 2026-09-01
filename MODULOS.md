# 🦀 A Trilha — do zero ao seu próprio sistema com IA

> Este repositório é o **Módulo 1** materializado. Os demais acontecem nas aulas —
> aqui fica o mapa, pra você saber exatamente aonde essa estrada leva.

## Módulo 1 — A Fundação (uma linha) `← você está aqui`

Uma linha no terminal e sua VPS vira infraestrutura de produção:
Docker Swarm, Traefik com HTTPS automático, Portainer só pela Tailnet,
Beszel para saúde e consumo, PostgreSQL com pgvector, Redis e backup. A
fundação nasce uma vez; depois o
mesmo comando cria sites simples ou WordPress em stacks independentes.

```bash
bash <(curl -fsSL https://get.motobot.com.br)
```

**Você sai sabendo**: o que é cada peça, por que orquestrador em vez de
"instalar na mão", como um serviço ganha domínio + cadeado sozinho.

## Módulo 2 — A Blindagem (cyber segurança de gente grande, de graça)

O que separa um projeto de estimação de um sistema que aguenta o mundo real:

- **Firewall + SSH endurecido + fail2ban** — a porta fecha, o robô de força-bruta é banido.
- **Backup diário → Cloudflare R2** — seus bancos e sites dormem fora do
  servidor, todo dia às 04:00, com retenção de 30 dias.
- **Auto-commit → GitHub privado** — seu código com cópia externa a cada 30min,
  cada commit **assinado com quem estava logado** (usuário@IP). Servidor pode
  pegar fogo; seu trabalho, não.
- **A regra que ninguém ensina**: backup que nunca foi *restaurado* é esperança,
  não backup. Treinamos o restore.

```bash
bash <(curl -fsSL https://get.motobot.com.br/guard)
```

## Módulo 3 — Os Cérebros (qual LLM pra qual trabalho)

IA não é "uma"; é um **time**, e quem sabe escalar o time certo paga centavos
onde amador paga fortuna:

| Cérebro | Papel no time | Quando escalar |
|---|---|---|
| **Claude Fable 5** | O arquiteto | Desenhar o sistema, decisões difíceis, código que precisa nascer certo |
| **Claude Opus** | O engenheiro sênior | Execução pesada do dia a dia, refactors, features completas |
| **Claude Haiku** | O estagiário genial | Classificar, resumir, rotear — milissegundos e centavos |
| **GPT-4.1-mini** | O atendente incansável | Entender linguagem de cliente em produção, 24h, custo de guaraná |

**Você sai sabendo**: custo por tarefa, latência, quando a resposta "boa e
barata" ganha da "perfeita e cara" — a matemática real de um produto com IA.

## Módulo 4 — MCP: a IA com as mãos nas suas stacks

Aqui a mágica: **MCP (Model Context Protocol)** conecta o Claude a TUDO que
você subiu nos módulos 1 e 2. A IA deixa de *opinar* sobre o seu sistema e
passa a *operar* o seu sistema:

- Claude **consulta seu PostgreSQL** e responde sobre seus dados reais.
- Claude **enxerga seus containers** e diagnostica o serviço que caiu.
- Claude **mexe no seu DNS da Cloudflare**, nos seus repositórios do GitHub,
  nos seus fluxos do n8n.
- Você pergunta em português; ela executa na infraestrutura — com as
  permissões que VOCÊ deu, e mais nenhuma.

**Você sai sabendo**: montar seus próprios servidores MCP, dar (e limitar)
poderes, e transformar o terminal num copiloto que conhece a sua casa.

## Módulo 5 — O Produto (o seu, não o meu)

Com fundação, blindagem, cérebros e mãos — você constrói **o seu sistema**,
conversando com a IA. Cada aluno sai com um produto diferente, porque cada um
tem um problema diferente. Meu papel: as calls, as cascas de banana que já
pisei em produção, e o empurrão na hora certa.

---

**Aula gratuita** — o Módulo 1 inteiro, ao vivo, do zero:
em breve o link. Me segue: [github.com/rafzinn](https://github.com/rafzinn) 🦀
