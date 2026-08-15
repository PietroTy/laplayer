import sys
import os
import time
from librespot.core import Session
from librespot import metadata
from librespot.audio.decoders import AudioQuality, SuperAudioFormat, FormatOnlyAudioQuality

def login_with_credentials(username, password):
    script_dir = os.path.dirname(os.path.abspath(__file__))
    creds_path = os.path.join(script_dir, "credentials.json")

    print("=" * 60)
    print(" LOCALIFY - Login Direto no Spotify (Login5)")
    print("=" * 60)
    print(f">>> Tentando autenticar usuário '{username}'...")

    try:
        builder = Session.Builder()
        builder.conf.store_credentials = True
        builder.conf.stored_credentials_file = creds_path
        builder.user_pass(username, password)
        
        session = builder.create()
        print(f"\n[SUCESSO] LOGIN REALIZADO COM SUCESSO!")
        print(f"   Usuario: {session.username()}")
        print(f"   Tipo de conta: {session.get_user_attribute('type')}")
        print(f"   Credenciais salvas em: {creds_path}")

        print("\n>>> Testando requisicao de chave de audio com intervalo de seguranca...")
        time.sleep(2)
        
        track_id_obj = metadata.TrackId.from_base62("4cOdK2wGLETKBW3PvgPWqT")
        quality = FormatOnlyAudioQuality(AudioQuality.HIGH, SuperAudioFormat.VORBIS)

        try:
            stream_data = session.content_feeder().load(track_id_obj, quality, False, None)
            if stream_data and stream_data.input_stream:
                print("\n============================================================")
                print(" SUCESSO! CHAVE DE AUDIO OBTIDA E FLUXO DE AUDIO LIBERADO!")
                print("============================================================")
        except Exception as key_err:
            print(f"\n[AVISO] Resposta do teste de chave de audio: {key_err}")

        session.close()

    except Exception as e:
        print(f"\n[ERRO] NO LOGIN: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Uso: python pc_login_direct.py <usuario_ou_email> <senha>")
        sys.exit(1)
    
    user = sys.argv[1]
    pwd = sys.argv[2]
    login_with_credentials(user, pwd)
