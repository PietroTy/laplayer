import sys
import textwrap
import webbrowser
import threading
from librespot.core import Session, OAuth, MercuryRequests

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

def realizar_login_oauth(caminho_creds = "credentials.json"):
    print("autenticacao spotify")

    port = 4381
    redirect_url = f"http://127.0.0.1:{port}/login"
    
    def oauth_print (url):
        #magic_link = f"\033]8;;{url}\033\\ [ login no navegador ]\033]8;;\033\\"
        #print(f"\n{magic_link}\n")
        print("abrindo navegador...")
        try:
            webbrowser.open(url)
        except Exception:
            pass

        def print_fallback():
            print("\nse navegador nao abriu, copie link abaixo:")
            wrapped_url = textwrap.fill(url, width=70, break_long_words=True)
            print(f"{wrapped_url}\n")

        t = threading.Timer(5.0, print_fallback)
        t.daemon = True
        t.start()


    try:
        client_id = MercuryRequests.keymaster_client_id
        oauth = OAuth(client_id, redirect_url, oauth_print).set_scopes(SCOPES).set_listen_all(True)
        login_credentials = oauth.flow()

        print("processando token de login")

        builder = Session.Builder()
        builder.conf.store_credentials = True
        builder.conf.stored_credentials_file = caminho_creds
        builder.login_credentials = login_credentials

        _ = builder.create()

        print(f"login realizado")
        print(f"credentiais gravadar em: {caminho_creds}")
    
    except Exception as e:
        print(f"falha ao criar credentials.json: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    creds_path = sys.argv[1] if len(sys.argv) > 1 else "credentials.json"
    realizar_login_oauth()

