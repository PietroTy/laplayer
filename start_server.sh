#!/bin/bash
set -eo pipefail

# Resolve the real path of the script
SCRIPT_DIR="$( cd "$( dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd )"
PROJECT_ROOT="$SCRIPT_DIR"
SERVER_DIR="$PROJECT_ROOT/server"

BACKEND_PID_FILE="$PROJECT_ROOT/.backend.pid"
TUNNEL_PID_FILE="$PROJECT_ROOT/.tunnel.pid"
BACKEND_LOG="$PROJECT_ROOT/.backend.log"
TUNNEL_LOG="$PROJECT_ROOT/.tunnel.log"
URL_FILE="$PROJECT_ROOT/server_url.txt"
TUNNEL_URL=""

cleanup() {
    echo "Limpando processos antigos..."
    for FILE in "$BACKEND_PID_FILE" "$TUNNEL_PID_FILE"; do
        if [ -f "$FILE" ]; then
            PID=$(cat "$FILE")
            kill -0 "$PID" 2>/dev/null && kill "$PID" || true
            rm -f "$FILE"
        fi
    done
    rm -f "$BACKEND_LOG" "$TUNNEL_LOG"
}

trap "cleanup; exit" INT TERM EXIT

cleanup

# 1. Iniciar uvicorn
echo "Iniciando backend (Uvicorn)..."
cd "$SERVER_DIR"
uvicorn main:app --host 0.0.0.0 --port 8000 > "$BACKEND_LOG" 2>&1 &
echo $! > "$BACKEND_PID_FILE"

sleep 3

# 2. Iniciar cloudflared
echo "Iniciando Cloudflare Tunnel..."
if [ -f "$SERVER_DIR/cloudflared.exe" ]; then
    "$SERVER_DIR/cloudflared.exe" tunnel --url http://127.0.0.1:8000 > "$TUNNEL_LOG" 2>&1 &
else
    # Se rodar via Git Bash nativo ou WSL
    command -v cloudflared >/dev/null && {
        cloudflared tunnel --url http://127.0.0.1:8000 > "$TUNNEL_LOG" 2>&1 &
    } || {
        echo "cloudflared.exe não encontrado em $SERVER_DIR/cloudflared.exe!"
        exit 1
    }
fi
echo $! > "$TUNNEL_PID_FILE"

# 3. Obter URL
echo "Obtendo URL pública..."
for i in {1..40}; do
    if [ -f "$TUNNEL_LOG" ]; then
        URL=$(grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' "$TUNNEL_LOG" | head -n1 || true)
        if [ -n "$URL" ]; then
            TUNNEL_URL="$URL"
            echo "Tunnel URL: $TUNNEL_URL"
            break
        fi
    fi
    sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
    echo "Não foi possível obter a URL."
    exit 1
fi

# 4. Salvar URL no arquivo
echo -n "$TUNNEL_URL" > "$URL_FILE"

# 5. Git Commit & Push
if [ -d "$PROJECT_ROOT/.git" ]; then
    cd "$PROJECT_ROOT"
    git add "$URL_FILE"
    if ! git diff --cached --quiet; then
        git commit -m "Atualizando server_url.txt para $TUNNEL_URL"
        git push origin main
        echo "URL enviada para o GitHub com sucesso!"
    else
        echo "URL idêntica. Sem alterações no Git."
    fi
else
    echo "Git não inicializado nesta pasta."
fi

echo "Servidor ativo! logs:"
tail -f "$BACKEND_LOG"
