#!/usr/bin/env python3
"""PORTA da VPS — o Claude Code que OPERA esta máquina, atrás de uma porta estreita.

Por que existe: o chat do navegador (chat.<domínio>, só pela tailnet) precisa
mandar tarefas num Claude com poder de verdade — docker, banco, arquivos,
deploy. Dar shell root pra dentro de um navegador seria a saída preguiçosa e
perigosa. Aqui é o contrário: quem pede só ESCREVE UM ARQUIVO em
/opt/porta/entrada; quem executa é este serviço, no host, como root.

Garantias do desenho (o mesmo da porta que roda em produção no Motobot):
  · UMA credencial: a do host (/etc/profile.d/claude-cred.sh, o setup-token
    do plano do dono). O container do chat nunca vê o shell da máquina.
  · UMA fila: um pedido por vez. Nunca há dois Claudes editando o mesmo
    projeto ao mesmo tempo.
  · SESSÃO POR CONVERSA: cada conversa do chat tem seu uuid; a porta retoma
    (--resume) e o Claude lembra o que já fez ali. Memória de longo prazo =
    /opt/CLAUDE.md + a memória do Claude Code em /root/.claude.
  · MODO LEITURA por padrão: Write/Edit negados e todo Bash passa pelo
    guarda-leitura.py (recusa escrita, deploy, systemctl, SQL de escrita).
    O modo MASTER (senha mestra + código de 4 dígitos, aberto pelo chat)
    libera acceptEdits + Bash + web por 3 h e expira sozinho.
  · Tudo em historico.jsonl: quem pediu, o quê, modo, modelo, segundos, rc.

Protocolo (arquivos):
  entrada/<id>.json  {texto, origem, usuario, sessao, modelo, esforco, regras}
  saida/<id>.jsonl   linhas {"t":"inicio"} · {"t":"texto","v":…} ·
                     {"t":"ferramenta","v":…} · {"t":"erro","v":…} ·
                     {"t":"fim", uso:{…}, rc, segundos, sessao, sessao_nova}
  saida/<id>.fim     marcador de conclusão (quem lê pode confiar)
  parar              existe = cancela a tarefa em curso
  estado.json        {total_ate, sessoes:[…], modelo, esforco}
"""
import json
import os
import shlex
import shutil
import signal
import subprocess
import time
import uuid

BASE = os.environ.get("PORTA_BASE", "/opt/porta")
ENTRADA = os.path.join(BASE, "entrada")
SAIDA = os.path.join(BASE, "saida")
UPLOADS = os.path.join(BASE, "uploads")
ESTADO = os.path.join(BASE, "estado.json")
HISTORICO = os.path.join(BASE, "historico.jsonl")
PARAR = os.path.join(BASE, "parar")
SETTINGS_LEITURA = os.path.join(BASE, "settings-leitura.json")
CWD = os.environ.get("PORTA_CWD", "/opt")
CLAUDE = os.environ.get("PORTA_CLAUDE") or shutil.which("claude") or "/usr/bin/claude"
CRED = "/etc/profile.d/claude-cred.sh"   # export CLAUDE_CODE_OAUTH_TOKEN=… (gravado pelo instalador)
TETO = 20 * 60                            # uma tarefa não passa de 20 min
LIMPAR_UPLOADS_DIAS = 7
MODELO_PADRAO = "sonnet"
ESFORCO_PADRAO = "medium"
MODELOS = ("haiku", "sonnet", "opus", "fable")
MODEL_ARG = {"haiku": "haiku", "sonnet": "sonnet", "opus": "opus", "fable": "claude-fable-5-1"}
ESFORCOS = ("low", "medium", "high", "xhigh")
MAX_SESSOES = 500
# pastas fora de /opt que o modo master pode escrever (acceptEdits só cobre o cwd)
ADD_DIRS = ["/tmp", "/etc/motobase", "/etc/systemd/system", "/root/.claude/projects"]
PROJ_NAME = os.environ.get("PROJ_NAME", "esta VPS")


def ler_estado():
    try:
        with open(ESTADO, encoding="utf-8") as f:
            e = json.load(f)
    except Exception:
        e = {}
    e.setdefault("total_ate", 0)
    e.setdefault("sessoes", [])
    e.setdefault("modelo", MODELO_PADRAO)
    e.setdefault("esforco", ESFORCO_PADRAO)
    return e


def gravar_estado(e):
    tmp = ESTADO + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(e, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ESTADO)


def modo_master(e):
    return time.time() < float(e.get("total_ate") or 0)


def credencial():
    """O setup-token vive em /etc/profile.d (o shell do dono o herda); um
    serviço systemd não passa pelo profile, então lemos aqui. Sem cópia."""
    env = dict(os.environ)
    env.setdefault("HOME", "/root")
    if os.path.isfile(CRED):
        try:
            with open(CRED, encoding="utf-8") as f:
                for linha in f:
                    linha = linha.strip()
                    if linha.startswith("export ") and "=" in linha:
                        k, v = linha[7:].split("=", 1)
                        env[k.strip()] = "".join(shlex.split(v))
        except Exception:
            pass
    return env


def anotar(registro):
    with open(HISTORICO, "a", encoding="utf-8") as f:
        f.write(json.dumps(registro, ensure_ascii=False) + "\n")


def motor(estado, ped):
    modelo = ped.get("modelo") or estado.get("modelo") or MODELO_PADRAO
    esforco = ped.get("esforco") or estado.get("esforco") or ESFORCO_PADRAO
    if modelo not in MODELOS:
        modelo = MODELO_PADRAO
    if esforco not in ESFORCOS:
        esforco = ESFORCO_PADRAO
    return modelo, esforco


def resumo_ferramenta(bloco):
    nome = bloco.get("name") or "?"
    inp = bloco.get("input") or {}
    if nome == "Bash":
        alvo = (inp.get("command") or "")
    elif nome in ("Read", "Write", "Edit", "NotebookEdit"):
        alvo = inp.get("file_path") or inp.get("notebook_path") or ""
    elif nome in ("Grep", "Glob"):
        alvo = inp.get("pattern") or ""
    elif nome in ("WebFetch", "WebSearch"):
        alvo = inp.get("url") or inp.get("query") or ""
    else:
        alvo = json.dumps(inp, ensure_ascii=False)
    alvo = " ".join(str(alvo).split())
    if len(alvo) > 140:
        alvo = alvo[:137] + "…"
    return f"{nome}: {alvo}" if alvo else nome


def sistema(estado, ped):
    master = modo_master(estado)
    regras = (ped.get("regras") or "").strip()
    usuario = ped.get("usuario") or "o dono"
    partes = [
        f"Você é o Claude Code de {PROJ_NAME}, atendendo pela PORTA (chat no navegador, só pela tailnet). "
        f"Quem fala é {usuario}. Responda em PT-BR, direto e curto; sem emojis. "
        "Esta VPS foi instalada pelo Motobase: siga o /opt/CLAUDE.md (ele descreve a infra, o banco, "
        "o Redis, os secrets e o playbook de como criar um app novo). Não reinspecione o que o "
        "CLAUDE.md já afirma. Ao criar algo, entregue de ponta a ponta (stack, DNS, banco, teste) e "
        "reporte o resultado real, inclusive falhas.",
    ]
    if master:
        falta = int((float(estado.get("total_ate") or 0) - time.time()) // 60)
        partes.append(f"MODO MASTER ATIVO (expira em {falta} min): escrita, deploy e shell liberados. "
                      "Aja sem pedir confirmação para o que o dono já pediu; confirme só ação "
                      "destrutiva ou pública (apagar dados, DNS, expor serviço).")
    else:
        partes.append("MODO LEITURA: você só consulta (ler arquivos, docker ps/logs, SELECT). Se uma ação "
                      "for negada por permissão, NÃO insista: diga exatamente o que faria e lembre que "
                      "o botão 'Liberar master' no chat (senha mestra + código de 4 dígitos) libera por 3 horas.")
    if regras:
        partes.append("REGRAS DO DONO (valem sempre):\n" + regras[:4000])
    return "\n\n".join(partes)


def montar_cmd(estado, ped, sessao, retomar, modelo, esforco):
    cmd = [CLAUDE, "-p", "--model", MODEL_ARG.get(modelo, modelo), "--effort", esforco,
           "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
    cmd += ["--resume", sessao] if retomar else ["--session-id", sessao]
    if modo_master(estado):
        # acceptEdits: edição de arquivo entra sem perguntar (só dentro do cwd + add-dir).
        # Bash liberado explicitamente: no headless não existe diálogo de permissão.
        # O CLI recusa bypass quando roda como root — acceptEdits é o teto honesto.
        cmd += ["--permission-mode", "acceptEdits",
                "--allowedTools", "Bash", "WebFetch", "WebSearch",
                "--add-dir", *ADD_DIRS]
    else:
        # LEITURA de verdade: Write/Edit negados e todo Bash passa pelo guarda
        cmd += ["--settings", SETTINGS_LEITURA,
                "--disallowedTools", "Write", "Edit", "NotebookEdit",
                "--allowedTools", "Bash"]
    cmd += ["--append-system-prompt", sistema(estado, ped)]
    cmd.append(ped["texto"])
    return cmd


def executar(ident, ped, estado):
    destino = os.path.join(SAIDA, ident + ".jsonl")
    modelo, esforco = motor(estado, ped)
    sessao = (ped.get("sessao") or "").strip()
    if not sessao:
        sessao = str(uuid.uuid4())
    retomar = sessao in estado["sessoes"]
    sessao_nova = False
    inicio = time.time()
    env = credencial()

    def escreve(saida, obj):
        saida.write(json.dumps(obj, ensure_ascii=False) + "\n")
        saida.flush()

    with open(destino, "w", encoding="utf-8") as saida:
        escreve(saida, {"t": "inicio", "modo": "master" if modo_master(estado) else "leitura",
                        "modelo": modelo, "esforco": esforco, "sessao": sessao})
        tentativa = 0
        while True:
            tentativa += 1
            cmd = montar_cmd(estado, ped, sessao, retomar, modelo, esforco)
            if os.path.exists(PARAR):
                os.remove(PARAR)
            rc, uso, texto_saiu, stderr, interrompido = rodar(cmd, env, saida, escreve, inicio)
            # --resume de sessão que o CLI não achou (transcript apagado): recomeça limpa UMA vez
            if rc != 0 and retomar and not texto_saiu and tentativa == 1 and \
                    ("session" in (stderr or "").lower() or "conversation" in (stderr or "").lower()):
                sessao = str(uuid.uuid4())
                retomar = False
                sessao_nova = True
                escreve(saida, {"t": "ferramenta", "v": "sessão anterior não existe mais — começando uma nova"})
                continue
            break

        if rc != 0 and not texto_saiu and not interrompido:
            escreve(saida, {"t": "erro", "v": motivo_falha(stderr, rc)})
        segundos = int(time.time() - inicio)
        escreve(saida, {"t": "fim", "rc": rc, "segundos": segundos, "uso": uso,
                        "sessao": sessao, "sessao_nova": sessao_nova, "modelo": modelo,
                        "interrompido": interrompido})

    if rc == 0 or texto_saiu:
        if sessao not in estado["sessoes"]:
            estado["sessoes"].append(sessao)
            estado["sessoes"] = estado["sessoes"][-MAX_SESSOES:]
    gravar_estado(estado)
    if os.path.exists(PARAR):
        os.remove(PARAR)
    return rc, int(time.time() - inicio), modelo, esforco


def rodar(cmd, env, saida, escreve, inicio):
    """Roda o claude e traduz o stream-json pra linhas simples no arquivo de saída."""
    uso = None
    texto_saiu = False
    interrompido = False
    stderr_buf = []
    p = subprocess.Popen(cmd, cwd=CWD, env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        while True:
            linha = p.stdout.readline()
            if not linha:
                if p.poll() is not None:
                    break
                time.sleep(0.05)
            else:
                try:
                    ev = json.loads(linha)
                except Exception:
                    continue
                t = ev.get("type")
                if t == "stream_event":
                    inner = ev.get("event") or {}
                    if inner.get("type") == "content_block_delta":
                        d = inner.get("delta") or {}
                        if d.get("type") == "text_delta" and d.get("text"):
                            texto_saiu = True
                            escreve(saida, {"t": "texto", "v": d["text"]})
                elif t == "assistant":
                    for bloco in ((ev.get("message") or {}).get("content") or []):
                        if bloco.get("type") == "tool_use":
                            escreve(saida, {"t": "ferramenta", "v": resumo_ferramenta(bloco)})
                elif t == "result":
                    u = ev.get("usage") or {}
                    uso = {"entrada": u.get("input_tokens", 0), "saida": u.get("output_tokens", 0),
                           "cache": u.get("cache_read_input_tokens", 0),
                           "usd": ev.get("total_cost_usd"), "turnos": ev.get("num_turns")}
                    if not texto_saiu and isinstance(ev.get("result"), str) and ev["result"].strip():
                        texto_saiu = True
                        escreve(saida, {"t": "texto", "v": ev["result"]})
                    if ev.get("is_error") or (ev.get("subtype") and ev.get("subtype") != "success"):
                        stderr_buf.append(str(ev.get("result") or ev.get("subtype")))
            if os.path.exists(PARAR):
                p.send_signal(signal.SIGINT)
                time.sleep(2)
                if p.poll() is None:
                    p.kill()
                interrompido = True
                escreve(saida, {"t": "erro", "v": "cancelado a pedido do dono"})
                break
            if time.time() - inicio > TETO:
                p.kill()
                interrompido = True
                escreve(saida, {"t": "erro", "v": "passou de 20 min e foi interrompido — quebre em passos menores"})
                break
    finally:
        if p.poll() is None:
            p.kill()
        try:
            stderr_buf.append(p.stderr.read() or "")
        except Exception:
            pass
        rc = p.wait()
    return rc, uso, texto_saiu, "\n".join(x for x in stderr_buf if x).strip(), interrompido


def motivo_falha(texto, rc):
    baixo = (texto or "").lower()
    if any(x in baixo for x in ("billing", "credit", "quota", "payment", "insufficient", "exhausted", "subscription")):
        return "assinatura/quota do Claude: " + (texto or "")[:200]
    if any(x in baixo for x in ("unauthorized", "forbidden", "authentication", "not logged", "token")):
        return "autenticação do Claude no host falhou — rode 'motobase chat' e cole o setup-token de novo"
    if rc == 124:
        return "timeout"
    return f"o Claude do host falhou (código {rc}): " + (texto or "")[:300]


def limpar_uploads():
    try:
        limite = time.time() - LIMPAR_UPLOADS_DIAS * 86400
        for nome in os.listdir(UPLOADS):
            c = os.path.join(UPLOADS, nome)
            if os.path.isfile(c) and os.path.getmtime(c) < limite:
                os.remove(c)
    except Exception:
        pass


def main():
    for pasta in (ENTRADA, SAIDA, UPLOADS):
        os.makedirs(pasta, exist_ok=True)
    os.chmod(BASE, 0o700)
    print(f"[porta] no ar · claude={CLAUDE} · cwd={CWD}", flush=True)
    ultima_limpeza = 0
    while True:
        arquivos = sorted(f for f in os.listdir(ENTRADA) if f.endswith(".json"))
        if not arquivos:
            time.sleep(0.3)
            if time.time() - ultima_limpeza > 3600:
                limpar_uploads()
                ultima_limpeza = time.time()
            continue
        for nome in arquivos:
            caminho = os.path.join(ENTRADA, nome)
            try:
                with open(caminho, encoding="utf-8") as f:
                    ped = json.load(f)
            except Exception:
                os.remove(caminho)
                continue
            os.remove(caminho)
            ident = nome[:-5]
            texto = (ped.get("texto") or "").strip()
            if not texto:
                continue
            ped["texto"] = texto
            estado = ler_estado()
            print(f"[porta] {ped.get('origem') or '?'}/{ped.get('usuario') or '?'}: {texto[:70]!r} "
                  f"({'MASTER' if modo_master(estado) else 'leitura'})", flush=True)
            try:
                rc, seg, modelo, esforco = executar(ident, ped, estado)
            except Exception as e:  # nunca deixar a fila morrer por um pedido
                rc, seg, modelo, esforco = 1, 0, "?", "?"
                with open(os.path.join(SAIDA, ident + ".jsonl"), "a", encoding="utf-8") as saida:
                    saida.write(json.dumps({"t": "erro", "v": f"porta: {e}"}) + "\n")
                    saida.write(json.dumps({"t": "fim", "rc": 1, "segundos": 0, "uso": None}) + "\n")
            open(os.path.join(SAIDA, ident + ".fim"), "w").close()
            anotar({"t": int(time.time()), "id": ident, "origem": ped.get("origem"),
                    "usuario": ped.get("usuario"), "pedido": texto[:400], "rc": rc,
                    "segundos": seg, "modo": "master" if modo_master(estado) else "leitura",
                    "modelo": modelo, "esforco": esforco})
            print(f"[porta] concluído em {seg}s (rc={rc})", flush=True)


if __name__ == "__main__":
    main()
