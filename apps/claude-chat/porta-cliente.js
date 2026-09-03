'use strict';
// ── Cliente da PORTA (o Claude Code do host) ──────────────────────────────────
// O container NÃO tem shell no host. Ele só escreve um pedido em
// <PORTA_BASE>/entrada/<id>.json e acompanha <PORTA_BASE>/saida/<id>.jsonl,
// que o serviço motobase-porta (systemd, root) vai preenchendo. Cancelar =
// criar o arquivo `parar`. O modo master mora em estado.json (total_ate).
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const BASE = process.env.PORTA_BASE || '/opt/porta';
const ENTRADA = path.join(BASE, 'entrada');
const SAIDA = path.join(BASE, 'saida');
const UPLOADS = path.join(BASE, 'uploads');
const ESTADO = path.join(BASE, 'estado.json');
const PARAR = path.join(BASE, 'parar');
const TETO_MS = 25 * 60 * 1000;

function disponivel() { try { return fs.existsSync(ENTRADA) && fs.statSync(ENTRADA).isDirectory(); } catch (e) { return false; } }

function estado() {
  try { return JSON.parse(fs.readFileSync(ESTADO, 'utf8')); } catch (e) { return {}; }
}
function gravarEstado(mut) {
  const e = estado(); mut(e);
  const tmp = ESTADO + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(e), { mode: 0o600 });
  fs.renameSync(tmp, ESTADO);
}
function masterAte() {
  const t = Number(estado().total_ate || 0) * 1000;
  return t > Date.now() ? t : null;
}
function abrirMaster(ttlSeg) { gravarEstado(e => { e.total_ate = Date.now() / 1000 + ttlSeg; }); return masterAte(); }
function fecharMaster() { gravarEstado(e => { e.total_ate = 0; }); }

function novoId() { return `${Date.now()}-${crypto.randomBytes(3).toString('hex')}`; }

// anexo → arquivo em uploads/ (o Claude do host lê com a própria ferramenta)
function salvarUpload(id, anexo) {
  fs.mkdirSync(UPLOADS, { recursive: true });
  const nome = String(anexo.name || 'anexo').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 80);
  const destino = path.join(UPLOADS, `${id}-${nome}`);
  fs.writeFileSync(destino, Buffer.from(anexo.data || '', 'base64'), { mode: 0o600 });
  return destino;
}

// quantos pedidos estão na frente do meu na fila
function posicao(id) {
  try { return fs.readdirSync(ENTRADA).filter(f => f.endsWith('.json') && f.slice(0, -5) < id).length; } catch (e) { return 0; }
}

// Envia o pedido e acompanha a saída. `onEvento({tipo, ...})` recebe:
//   estado {texto} · delta {t} · erro {detail}. Resolve com o registro `fim`.
// Devolve { promessa, cancelar }.
function pedir(ped, onEvento) {
  const id = novoId();
  const entradaTmp = path.join(ENTRADA, id + '.json.tmp');
  const entrada = path.join(ENTRADA, id + '.json');
  const saida = path.join(SAIDA, id + '.jsonl');
  const fim = path.join(SAIDA, id + '.fim');
  let comecou = false, terminou = false, cancelado = false, offset = 0, resto = '', ultimaFila = -1;
  fs.writeFileSync(entradaTmp, JSON.stringify(ped), { mode: 0o600 });
  fs.renameSync(entradaTmp, entrada);       // atômico: a porta nunca lê meio arquivo

  const promessa = new Promise((resolve, reject) => {
    const inicio = Date.now();
    let registroFim = null;
    const tick = () => {
      if (terminou) return;
      if (cancelado && !comecou) { terminou = true; return resolve({ rc: 1, cancelado: true }); }
      if (Date.now() - inicio > TETO_MS) { terminou = true; return reject(new Error('a porta não respondeu em 25 min')); }
      if (!comecou) {
        const n = posicao(id);
        if (n !== ultimaFila && !fs.existsSync(saida)) { ultimaFila = n; onEvento({ tipo: 'estado', texto: n > 0 ? `na fila: ${n} na frente` : 'esperando a porta…' }); }
      }
      try {
        if (fs.existsSync(saida)) {
          const st = fs.statSync(saida);
          if (st.size > offset) {
            const fd = fs.openSync(saida, 'r');
            const buf = Buffer.alloc(st.size - offset);
            fs.readSync(fd, buf, 0, buf.length, offset); fs.closeSync(fd);
            offset = st.size;
            resto += buf.toString('utf8');
            let i;
            while ((i = resto.indexOf('\n')) >= 0) {
              const linha = resto.slice(0, i); resto = resto.slice(i + 1);
              if (!linha.trim()) continue;
              let ev; try { ev = JSON.parse(linha); } catch (e) { continue; }
              if (ev.t === 'inicio') { comecou = true; onEvento({ tipo: 'estado', texto: `trabalhando… (modo ${ev.modo}, ${ev.modelo})` }); }
              else if (ev.t === 'texto') onEvento({ tipo: 'delta', t: ev.v });
              else if (ev.t === 'ferramenta') onEvento({ tipo: 'estado', texto: ev.v });
              else if (ev.t === 'erro') onEvento({ tipo: 'erro', detail: ev.v });
              else if (ev.t === 'fim') registroFim = ev;
            }
          }
        }
        if (registroFim && fs.existsSync(fim)) { terminou = true; return resolve(registroFim); }
      } catch (e) { /* leitura parcial: tenta no próximo tick */ }
      setTimeout(tick, 250);
    };
    tick();
  });

  const cancelar = () => {
    if (terminou) return;
    cancelado = true;
    if (!comecou) { try { fs.unlinkSync(entrada); } catch (e) {} }
    else { try { fs.writeFileSync(PARAR, ''); } catch (e) {} }
  };
  return { id, promessa, cancelar };
}

module.exports = { disponivel, estado, masterAte, abrirMaster, fecharMaster, salvarUpload, pedir, BASE };
