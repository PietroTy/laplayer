import os
import threading
import tempfile
import time

# Altera o diretório atual e variáveis de ambiente ANTES de importar o librespot
# Isso evita que o librespot grave caminhos em readonly ('/') durante o import do módulo.
_tmp = tempfile.gettempdir()
os.environ["HOME"] = _tmp
os.environ["USERPROFILE"] = _tmp
os.environ["TMPDIR"] = _tmp
try:
    os.chdir(_tmp)
except:
    pass

from mutagen.oggvorbis import OggVorbis
from librespot.core import Session
from librespot import metadata
from librespot.audio.decoders import AudioQuality, SuperAudioFormat, FormatOnlyAudioQuality

import socket

# Patch global de Socket para Android
_original_bind = socket.socket.bind

def _android_bind(self, address):
    if isinstance(address, tuple) and len(address) >= 2:
        host = address[0]
        port = address[1]
        if host in ('127.0.0.1', 'localhost'):
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
    try:
        return _original_bind(self, address)
    except Exception as e:
        print(f"Aviso: socket.bind({address}) ignorado: {e}")

socket.socket.bind = _android_bind

def _sanitize_filename(name):
    import re
    return re.sub(r'[\\/*?:"<>|]', "", name)

def download_track(
    spotify_id: str,
    creds_path: str,
    output_dir: str,
    tmp_filename: str,
    progress_callback,
    success_callback,
    error_callback,
    audio_quality_setting: str = "high"
):
    """
    Baixa uma faixa via librespot e chama os callbacks Kotlin.
    Suporta mapeamento de qualidade de áudio (low: 96k, medium: 160k, high/best: 320k).
    """
    global _global_session
    if '_global_session' not in globals():
        _global_session = None

    def get_or_create_session(creds_path):
        global _global_session
        if _global_session is not None:
            try:
                # Testa se a sessão ainda está viva
                _global_session.get_user_attribute("type")
                return _global_session
            except Exception as e:
                print(f"Sessão global morreu, recriando... Erro: {e}")
                try:
                    _global_session.close()
                except:
                    pass
                _global_session = None

        last_err = None
        for attempt in range(3):
            try:
                _global_session = Session.Builder().stored_file(creds_path).create()
                break
            except Exception as err:
                last_err = err
                print(f"Aviso: Falha ao conectar no Spotify (tentativa {attempt+1}): {err}")
                time.sleep(1.5)
        
        if not _global_session:
            raise Exception(f"Falha ao conectar no Spotify após 3 tentativas. Erro final: {last_err}")
            
        return _global_session

    def run_download_attempt():
        progress_callback.invoke(f"Iniciando sessão do Spotify...", 0.1)
        
        creds_dir = os.path.dirname(creds_path)
        if not os.path.exists(creds_dir):
            os.makedirs(creds_dir, exist_ok=True)

        session = get_or_create_session(creds_path)
        
        # Mapeia qualidade de acordo com a preferência de armazenamento do usuário
        setting_clean = (audio_quality_setting or "high").lower()
        if setting_clean == "low":
            req_quality = "NORMAL"
        elif setting_clean == "medium":
            req_quality = "HIGH"
        else:
            is_premium = session.get_user_attribute("type") == "premium"
            req_quality = "VERY_HIGH" if is_premium else "HIGH"
        
        try:
            audio_quality = getattr(AudioQuality, req_quality)
        except AttributeError:
            audio_quality = getattr(AudioQuality, "HIGH")

        quality = FormatOnlyAudioQuality(audio_quality, SuperAudioFormat.VORBIS)

        progress_callback.invoke(f"Buscando metadados no Spotify...", 0.3)
        track_id_obj = metadata.TrackId.from_base62(spotify_id)
        track_proto = session.api().get_metadata_4_track(track_id_obj)
        
        music_name = track_proto.name if track_proto.name else "unknown"
        artist_name = track_proto.artist[0].name if track_proto.artist else "unknown artist"

        final_ext = "ogg"
        file_path = os.path.join(output_dir, f"{tmp_filename}.{final_ext}")

        progress_callback.invoke(f"Carregando fluxo de áudio...", 0.5)
        stream_data = session.content_feeder().load(track_id_obj, quality, False, None)

        if stream_data and stream_data.input_stream:
            audio_stream = stream_data.input_stream
            actual_stream = audio_stream.stream() if hasattr(audio_stream, 'stream') else audio_stream
            
            # Para progresso
            estimated_size = 5 * 1024 * 1024 # 5MB fallback, não temos o size real antes
            downloaded = 0

            with open(file_path, 'wb') as f:
                while True:
                    chunk = actual_stream.read(20000)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    # Progresso aproximado
                    pct = min(0.9, 0.5 + (downloaded / estimated_size) * 0.4)
                    progress_callback.invoke(f"Baixando ({downloaded//1024}KB)...", pct)

            progress_callback.invoke(f"Gravando metadados ID3...", 0.95)
            try:
                audio_tags = OggVorbis(file_path)
                audio_tags["title"] = music_name
                audio_tags["artist"] = artist_name
                audio_tags["spotify_id"] = spotify_id
                audio_tags.save()
            except Exception as tag_err:
                print(f"Aviso: falha ao salvar tags: {tag_err}")

            progress_callback.invoke(f"Concluído", 1.0)
            return file_path
        else:
            raise Exception("Fluxo de áudio não disponível. Talvez exija Premium para esta faixa.")

    def run_download():
        max_retries = 3
        last_err = None
        
        for attempt in range(max_retries):
            try:
                file_path = run_download_attempt()
                success_callback.invoke(file_path)
                return
            except Exception as e:
                last_err = str(e)
                print(f"[DEBUGAO-PYTHON] Erro na tentativa {attempt+1} do download: {last_err}")
                
                # Se deu erro, a sessão pode estar corrompida (Doze mode, conexão caída, etc)
                # Vamos forçar a recriação da sessão para a próxima tentativa.
                close_session()
                
                if attempt < max_retries - 1:
                    progress_callback.invoke(f"Re-conectando Spotify... ({attempt+2}/{max_retries})", 0.1)
                    time.sleep(2) # Pausa para respirar e deixar a rede do Android estabilizar
        
        # Se esgotou as tentativas, propaga o erro
        error_callback.invoke(last_err)

    # Executa sincronicamente, pois o Kotlin já spawnou uma background Thread.
    run_download()

def close_session():
    """
    Encerra a sessão global do librespot de forma assíncrona com timeout estrito de 1.0s,
    evitando que conexões TCP mortas travem a thread do Android/Chaquopy.
    """
    global _global_session
    if '_global_session' in globals() and _global_session is not None:
        sess = _global_session
        _global_session = None
        
        def _force_close(s):
            try:
                s.close()
            except Exception:
                pass

        try:
            t = threading.Thread(target=_force_close, args=(sess,), daemon=True)
            t.start()
            t.join(timeout=1.0)
        except Exception as e:
            print(f"Aviso ao encerrar sessão: {e}")

