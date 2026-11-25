#!/bin/sh
# Plantão de mensagens via SSE da nuvem (/api/events).
# Uso: plantao-stream.sh [--uma-vez] <slug> [slug...]   |   plantao-stream.sh [--uma-vez] --alertar
#
# Imprime UMA linha por evento (cada linha acorda o agente quando este script é o
# command de um Monitor persistente do harness):
#   Fulano: texto                    mensagem recebida
#   Você (celular): texto            o operador respondeu na mão (celular ou web)
#   Painel (ana): texto             alguém da equipe respondeu pelo painel (contexto)
#   IA da Meta (sua conta): texto    resposta gerada pela Meta em nome da conta
#   Entrega interrompida (mensagem nova, 1/3 saiu) — releia o chat e responda de novo
#                                    uma entrega humanizada agendada não saiu (ou saiu pela
#                                    metade); entregas concluídas ficam em silêncio
# O eco do agente/MCP fica em silêncio (o servidor oculta com `ocultar=coletor`, e uma
# fromMe sem `origem`, de coletor antigo, também); envio de uma pessoa pelo painel aparece
# como Painel (login).
# Com mais de uma conversa, a linha vem com [slug] na frente.
#
# Reconecta sozinho e retoma de onde parou (guarda o último `id:` e reenvia em
# Last-Event-ID); o servidor manda ": ping" a cada 25s como keep-alive. Um lock por
# conjunto de conversas impede plantão em duplicata (segunda instância sai com 3).
# Variáveis de ambiente vencem o .env da raiz (WAC_CLOUD_URL/USER/PASS).
# PLANTAO_CLOUD=pessoal troca pro coletor PESSOAL (trio WAC_PESSOAL_URL/USER/PASS).
# PLANTAO_STATE_DIR (lock/cursor; default $TMPDIR ou /tmp), PLANTAO_RETRY_S (default 5).
# PLANTAO_RECONNECT_S (default 600): reconecta a cada N s, retomando pelo cursor. Conexão
# meio-morta (sem FIN) deixava o curl parado pra sempre e o plantão mudo.
#
# --uma-vez: para runtimes que só acordam o agente quando a tarefa TERMINA (Antigravity,
# Codex), não a cada linha. Imprime o primeiro evento e sai com 0; o agente trata e roda
# de novo. O cursor fica guardado entre as execuções, então o que chegou enquanto o
# agente tratava o evento vem na execução seguinte. Cursor mais velho que
# PLANTAO_CURSOR_MAX_MIN (default 60) é descartado: plantão parado há tanto tempo
# recomeça em "agora" em vez de despejar o histórico.
#
# Credenciais: variáveis de ambiente; senão o arquivo em WAC_ENV_FILE; senão o .env da raiz
# do repositório; senão ~/.wacrew/env, que serve à cópia do script dentro de um plugin.

set -u
for ARG do
  case "$ARG" in
    -h|--help)
      cat <<'EOF'
uso: plantao-stream.sh [--uma-vez] <slug> [slug...] | --alertar
     plantao-stream.sh -h | --help

Plantão de mensagens via SSE da nuvem (/api/events).

Modos e opções:
  <slug> [slug...]         monitora uma ou mais conversas (com várias, prefixa [slug])
  --alertar                monitora conversas com alerta ligado
  --uma-vez                imprime o primeiro evento e sai com 0 (salva cursor)
  -h, --help               mostra esta ajuda e sai com 0

Variáveis de ambiente:
  WAC_CLOUD_URL/USER/PASS  credenciais do coletor principal; sem WAC_CLOUD_URL no env,
                           carrega o 1º arquivo que existir: WAC_ENV_FILE, .env da raiz, ~/.wacrew/env
  WAC_ENV_FILE             arquivo de credenciais alternativo
  PLANTAO_CLOUD=pessoal    troca pro coletor pessoal (trio WAC_PESSOAL_URL/USER/PASS)
  PLANTAO_STATE_DIR        lock e cursor (default: $TMPDIR ou /tmp)
  PLANTAO_RETRY_S          espera em s antes de reconectar (default: 5)
  PLANTAO_RECONNECT_S      reconecta a cada N s retomando pelo cursor (default: 600)
  PLANTAO_CURSOR_MAX_MIN   descarta cursor mais velho que N min no --uma-vez (default: 60)

Códigos de saída: 2 (uso incorreto), 3 (plantão já ativo)
EOF
      exit 0
      ;;
  esac
done
UMA_VEZ=0
if [ "${1:-}" = "--uma-vez" ]; then UMA_VEZ=1; shift; fi
[ $# -ge 1 ] || { echo "uso: plantao-stream.sh [--uma-vez] <slug> [slug...] | --alertar" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${WAC_CLOUD_URL:-}" ]; then
  for ARQ in ${WAC_ENV_FILE:+"$WAC_ENV_FILE"} "$ROOT/.env" "${HOME:-}/.wacrew/env"; do
    if [ -f "$ARQ" ]; then
      set -a
      # shellcheck disable=SC1090
      . "$ARQ"
      set +a
      break
    fi
  done
fi

CLOUD="${PLANTAO_CLOUD:-principal}"
if [ "$CLOUD" = "pessoal" ]; then
  : "${WAC_PESSOAL_URL:?WAC_PESSOAL_URL não configurado (trio do coletor pessoal no .env da raiz)}"
  WAC_CLOUD_URL="$WAC_PESSOAL_URL"
  WAC_CLOUD_USER="${WAC_PESSOAL_USER:?WAC_PESSOAL_USER não configurado}"
  WAC_CLOUD_PASS="${WAC_PESSOAL_PASS:?WAC_PESSOAL_PASS não configurado}"
fi
: "${WAC_CLOUD_URL:?WAC_CLOUD_URL não configurado (defina no .env da raiz ou em ~/.wacrew/env)}"
: "${WAC_CLOUD_USER:?WAC_CLOUD_USER não configurado}"
: "${WAC_CLOUD_PASS:?WAC_CLOUD_PASS não configurado}"

if [ "$1" = "--alertar" ]; then
  QUERY="alertar=1"
  KEY="alertar"
  MULTI=1
else
  SLUGS=$(printf '%s,' "$@")
  SLUGS=${SLUGS%,}
  QUERY="slug=$SLUGS"
  KEY=$(printf '%s' "$SLUGS" | tr -c 'A-Za-z0-9_-' '_')
  if [ $# -gt 1 ]; then MULTI=1; else MULTI=0; fi
fi
QUERY="$QUERY&ocultar=coletor"

STATE="${PLANTAO_STATE_DIR:-${TMPDIR:-/tmp}}"
if [ "$CLOUD" != "principal" ]; then KEY="$CLOUD-$KEY"; fi
LOCK="$STATE/plantao-$KEY.pid"
CURSOR="$STATE/plantao-$KEY.cursor"
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "plantão já ativo pra $KEY (pid $(cat "$LOCK")) — não armei outro" >&2
  exit 3
fi
printf '%s' "$$" > "$LOCK"
FIFO="$STATE/plantao-$KEY.fifo"
CURL_PID=""
if [ "$UMA_VEZ" = 1 ]; then
  # Retoma de onde a execução anterior parou, salvo se o cursor envelheceu.
  if [ -n "$(find "$CURSOR" -mmin +"${PLANTAO_CURSOR_MAX_MIN:-60}" 2>/dev/null)" ]; then
    rm -f "$CURSOR"
  fi
  trap 'rm -f "$LOCK" "$FIFO"; [ -n "$CURL_PID" ] && kill "$CURL_PID" 2>/dev/null' EXIT
  trap 'exit 130' INT TERM
else
  # Plantão novo começa em "agora": só a reconexão dentro desta execução retoma.
  rm -f "$CURSOR"
  trap 'rm -f "$LOCK" "$CURSOR"' EXIT INT TERM
fi

conectar() {
  if [ -s "$CURSOR" ]; then
    curl -sN --max-time "${PLANTAO_RECONNECT_S:-600}" -u "$WAC_CLOUD_USER:$WAC_CLOUD_PASS" -H "Last-Event-ID: $(cat "$CURSOR")" \
      "$WAC_CLOUD_URL/api/events?$QUERY"
  else
    curl -sN --max-time "${PLANTAO_RECONNECT_S:-600}" -u "$WAC_CLOUD_USER:$WAC_CLOUD_PASS" "$WAC_CLOUD_URL/api/events?$QUERY"
  fi
}

# Lê o SSE da entrada padrão e imprime uma linha por evento. Com --uma-vez, devolve 10
# logo depois de imprimir a primeira.
processar() {
  EVENTO=""
  while IFS= read -r line; do
    case "$line" in
    "id: "*) printf '%s' "${line#id: }" > "$CURSOR" ;;
    "event: "*) EVENTO="${line#event: }" ;;
    "data: "*)
      if [ "$EVENTO" = "entrega" ]; then
        EVENTO=""
        SAIDA=$(printf '%s\n' "${line#data: }" | MULTI="$MULTI" python3 -c 'import sys, json, os
m = json.loads(sys.stdin.read())
if m.get("estado") == "interrompido":
    pre = "[" + str(m.get("slug", "?")) + "] " if os.environ.get("MULTI") == "1" else ""
    motivos = {"mensagem_nova": "mensagem nova", "operador_respondeu": "operador respondeu na mão", "reinicio": "coletor reiniciou", "falha": "falha no envio"}
    motivo = motivos.get(m.get("motivo"), str(m.get("motivo")))
    saiu = str(m.get("enviados", 0)) + "/" + str(m.get("total", "?"))
    print(f"{pre}Entrega interrompida ({motivo}, {saiu} saiu) — releia o chat e responda de novo", flush=True)')
      else
        EVENTO=""
        SAIDA=$(printf '%s\n' "${line#data: }" | MULTI="$MULTI" python3 -c 'import sys, json, os
m = json.loads(sys.stdin.read())
pre = "[" + str(m.get("slug", "?")) + "] " if os.environ.get("MULTI") == "1" else ""
texto = (m.get("text") or "").strip() or "[" + str(m.get("type", "")) + "]"
if m.get("fromMe"):
    o = m.get("origem")
    if m.get("ator") == "painel":
        login = m.get("usuario") or "?"
        print(f"{pre}Painel ({login}): {texto}", flush=True)
    elif o in ("celular", "web"):
        print(f"{pre}Você ({o}): {texto}", flush=True)
    elif o == "ia_meta":
        print(f"{pre}IA da Meta (sua conta): {texto}", flush=True)
else:
    quem = m.get("senderName") or m.get("sender") or "?"
    print(f"{pre}{quem}: {texto}", flush=True)')
      fi
      if [ -n "$SAIDA" ]; then
        printf '%s\n' "$SAIDA"
        [ "$UMA_VEZ" = 1 ] && return 10
      fi
      ;;
    esac
  done
  return 0
}

if [ "$UMA_VEZ" = 1 ]; then
  # A leitura roda no shell principal (pelo FIFO) para poder sair sem esperar o curl.
  rm -f "$FIFO"
  mkfifo "$FIFO"
  while :; do
    conectar > "$FIFO" &
    CURL_PID=$!
    processar < "$FIFO"
    ST=$?
    kill "$CURL_PID" 2>/dev/null
    wait "$CURL_PID" 2>/dev/null
    CURL_PID=""
    [ "$ST" = 10 ] && exit 0
    sleep "${PLANTAO_RETRY_S:-5}"
  done
fi

while :; do
  conectar | processar
  sleep "${PLANTAO_RETRY_S:-5}"
done
