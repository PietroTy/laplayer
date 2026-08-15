import os
import sys
from librespot.core import Session
from librespot import metadata
from librespot.audio.decoders import AudioQuality, SuperAudioFormat, FormatOnlyAudioQuality

def test_download(spotify_id: str):
    creds_path = "credentials.json"
    
    if not os.path.exists(creds_path):
        print(f"[ERRO] {creds_path} não encontrado! Rode o pc_login.py primeiro.")
        return

    print(">>> Iniciando sessão do Spotify com credentials.json...")
    session = Session.Builder().stored_file(creds_path).create()
    
    is_premium = session.get_user_attribute("type") == "premium"
    req_quality = "VERY_HIGH" if is_premium else "HIGH"
    print(f">>> Conta do tipo Premium? {is_premium}. Requisitando qualidade {req_quality}.")
    
    try:
        audio_quality = getattr(AudioQuality, req_quality)
    except AttributeError:
        audio_quality = getattr(AudioQuality, "HIGH")

    quality = FormatOnlyAudioQuality(audio_quality, SuperAudioFormat.VORBIS)

    print(f">>> Buscando metadados para a faixa {spotify_id}...")
    track_id_obj = metadata.TrackId.from_base62(spotify_id)
    track_proto = session.api().get_metadata_4_track(track_id_obj)
    
    music_name = track_proto.name if track_proto.name else "unknown"
    artist_name = track_proto.artist[0].name if track_proto.artist else "unknown artist"
    print(f">>> Música encontrada: {music_name} - {artist_name}")

    file_path = f"teste_download_{spotify_id}.ogg"

    print(">>> Carregando fluxo de áudio...")
    stream_data = session.content_feeder().load(track_id_obj, quality, False, None)

    if stream_data and stream_data.input_stream:
        audio_stream = stream_data.input_stream
        actual_stream = audio_stream.stream() if hasattr(audio_stream, 'stream') else audio_stream
        
        downloaded = 0
        print(">>> Baixando... ", end="", flush=True)

        with open(file_path, 'wb') as f:
            while True:
                chunk = actual_stream.read(20000)
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)
                print(f"\r>>> Baixando... {downloaded // 1024} KB", end="", flush=True)
        
        print(f"\n>>> Download concluído! Arquivo salvo como {file_path}")
    else:
        print("\n[ERRO] Fluxo de áudio não disponível. Talvez exija Premium para esta faixa.")

if __name__ == '__main__':
    # Exemplo: Never Gonna Give You Up
    test_id = "4cOdK2wGLETKBW3PvgPWqT"
    if len(sys.argv) > 1:
        test_id = sys.argv[1]
    
    print(f"============================================================")
    print(f" TESTE DE DOWNLOAD NATIVO (LIBRESPOT) - {test_id}")
    print(f"============================================================")
    test_download(test_id)
