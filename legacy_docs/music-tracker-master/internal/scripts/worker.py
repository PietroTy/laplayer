import json
import sys
import threading
import time

def send_event(event, message):
    print(json.dumps({"event": event, "message": message}), flush=True)

def ping():
    while True:
        time.sleep(5)
        send_event("log", "worker ativo")

def main():
    send_event("log", "worker iniciado e aguardando comandos")

    t = threading.Thread(target=ping, daemon=True)
    t.start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            command = json.loads(line)
            action = command.get("action", "unknown")
            send_event("log", f"comando recebido do go: {action}")
        except json.JSONDecodeError:
            send_event("error", "falha ao decodificar comando go")

if __name__ == '__main__':
    main()

