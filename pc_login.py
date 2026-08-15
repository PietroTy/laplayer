"""
Script para gerar credentials.json no PC.
Abre o navegador para login no Spotify e salva as credenciais.
"""
import sys
import os
import webbrowser
import threading

from librespot.core import Session, OAuth, MercuryRequests

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    creds_path = os.path.join(script_dir, "credentials.json")

    print("=" * 60)
    print("  LOCALIFY - Login no Spotify (PC)")
    print("=" * 60)
    print(f"\nO credentials.json sera salvo em:\n  {creds_path}\n")

    port = 4381
    redirect_url = f"http://127.0.0.1:{port}/login"

    def on_url(url):
        print("\n" + "=" * 60)
        print("  COPIE E COLE ESTE LINK NO SEU NAVEGADOR:")
        print("=" * 60)
        print(f"\n{url}\n")
        print("=" * 60)
        try:
            webbrowser.open(url)
            print("(Tambem tentei abrir automaticamente)")
        except Exception:
            pass

    try:
        client_id = MercuryRequests.keymaster_client_id
        oauth = OAuth(client_id, redirect_url, on_url)

        print(">>> Aguardando login no navegador...")
        login_credentials = oauth.flow()
        print(">>> Token recebido! Criando sessao...")

        builder = Session.Builder()
        builder.conf.store_credentials = True
        builder.conf.stored_credentials_file = creds_path
        builder.login_credentials = login_credentials
        session = builder.create()

        print(f"\n>>> LOGIN REALIZADO COM SUCESSO!")
        print(f">>> Credenciais salvas em: {creds_path}")

        try:
            session.close()
        except Exception:
            pass

        print("\n" + "=" * 60)
        print("  PROXIMO PASSO - copie e cole no terminal:")
        print(f'  adb push "{creds_path}" /storage/emulated/0/Android/data/com.example.localify/files/credentials.json')
        print("=" * 60)

    except Exception as e:
        print(f"\n[ERRO] Falha no login: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == '__main__':
    main()
