import os
import threading
import socket
import socketserver
from librespot.core import Session, OAuth, MercuryRequests

# Força reutilização de porta no nível de classe do TCPServer
socketserver.TCPServer.allow_reuse_address = True

# Patch global de Socket para Android
_original_bind = socket.socket.bind

def _android_bind(self, address):
    if isinstance(address, tuple) and len(address) >= 2:
        host = address[0]
        port = address[1]
        if host in ('127.0.0.1', 'localhost'):
            print(f"[DEBUGAO-PYTHON] Redirecionando bind de {host}:{port} -> 0.0.0.0:{port}")
            address = ('0.0.0.0', port)
    try:
        self.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    except Exception:
        pass
    try:
        if hasattr(socket, 'SO_REUSEPORT'):
            self.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except Exception:
        pass
    return _original_bind(self, address)

socket.socket.bind = _android_bind

SCOPES = [
    'streaming',
    'playlist-read-private',
    'playlist-read-collaborative',
    'user-follow-read',
    'user-read-playback-position',
    'user-top-read',
    'user-read-recently-played',
    'user-library-read',
    'user-read-email',
    'user-read-private'
]

_auth_lock = threading.Lock()

def authenticate_spotify(creds_path: str, url_callback, success_callback, error_callback):
    """
    Autentica via OAuth usando o mesmo método do music-tracker-master.
    Usa OAuth diretamente com set_scopes e set_listen_all.
    """
    def run_auth():
        with _auth_lock:
            try:
                print(f"[DEBUGAO-PYTHON] >>> Início do fluxo de autenticação. creds_path = {creds_path}")

                port = 4381
                redirect_url = f"http://127.0.0.1:{port}/login"

                def oauth_print(url):
                    print(f"[DEBUGAO-PYTHON] >>> URL de login gerada: {url}")
                    url_callback.invoke(url)

                client_id = MercuryRequests.keymaster_client_id
                oauth = OAuth(client_id, redirect_url, oauth_print).set_scopes(SCOPES).set_listen_all(True)

                print("[DEBUGAO-PYTHON] >>> Aguardando retorno do OAuth flow...")
                login_credentials = oauth.flow()
                print("[DEBUGAO-PYTHON] >>> OAuth flow concluído! Criando sessão...")

                os.makedirs(os.path.dirname(creds_path), exist_ok=True)

                builder = Session.Builder()
                builder.conf.store_credentials = True
                builder.conf.stored_credentials_file = creds_path
                builder.login_credentials = login_credentials

                session = builder.create()
                print(f"[DEBUGAO-PYTHON] >>> SUCESSO! Sessão autenticada. Credenciais salvas em: {creds_path}")

                try:
                    session.close()
                except Exception:
                    pass

                success_callback.invoke(creds_path)

            except Exception as e:
                import traceback
                err_stack = traceback.format_exc()
                print(f"[DEBUGAO-PYTHON] !!! ERRO CRÍTICO NO LOGIN: {err_stack}")
                error_callback.invoke(str(e))

    t = threading.Thread(target=run_auth)
    t.daemon = True
    t.start()
