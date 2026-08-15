import sys
import os
import re
import time
from mutagen.oggvorbis import OggVorbis
from librespot.core import Session
from librespot import audio, metadata
from librespot.audio.decoders import AudioQuality, SuperAudioFormat, FormatOnlyAudioQuality
from google.protobuf.json_format import MessageToDict

def sanitize_filename(name):
    return re.sub(r'[\\/*?:"<>|]', "", name)

def start_saved_session(creds_path):
    try:
        session = Session.Builder().stored_file(creds_path).create()
        return session
    except Exception as e:
        print(f"erro ao carregar sessao: {e}", file=sys.stderr)
        sys.exit(1)

def resolve_file_duplicate(base_path, track_id):
    final_path = f"{base_path}.ogg"
    
    if not os.path.exists(final_path):
        return False, final_path
    
    def check_id(path):
        try:
            audio= OggVorbis(path)
            local_id = audio.get("spotify_id", [None])[0]
            return local_id == track_id
        except Exception:
            return False

    if check_id(final_path):
        return True, final_path

    n = 1
    while True:
        path_n = f"{base_path} ({n}).ogg"

        if not os.path.exists(path_n):
            return False, path_n
        
        if check_id(path_n):
            return True, path_n

        n += 1

def main(creds_path, download_path, download_quality, playlist_name):
    track_ids = sys.stdin.read().splitlines()
    track_ids = [t.strip() for t in track_ids if t.strip()]

    if not track_ids:
        print("ids nao recebidos")
        sys.exit(1)

    print("fazendo login")
    session = start_saved_session(creds_path)
    
    is_premium = session.get_user_attribute("type") == "premium"

    req_quality = download_quality.upper()

    if req_quality == "VERY_HIGH" and not is_premium: 
        print("usuario sem spotify premium, fallback qualidade de download para HIGH")
        req_quality = "HIGH"

    try:
        audio_quality = getattr(AudioQuality, req_quality)
    except AttributeError:
        print(f"qualidade: {req_quality}, invalida", file=sys.stderr)
        audio_quality = "HIGH"

    quality = FormatOnlyAudioQuality(audio_quality, SuperAudioFormat.VORBIS)

    final_path = download_path
    if playlist_name:
        playlist_name_sanitized = sanitize_filename(playlist_name)
        final_path = os.path.join(download_path, playlist_name_sanitized)
    os.makedirs(final_path, exist_ok=True)

    print(f"iniciando download de {len(track_ids)} musicas")

    for i, track_id_base62 in enumerate(track_ids, 1):
        try:
            track_id_obj = metadata.TrackId.from_base62(track_id_base62)
            track_proto = session.api().get_metadata_4_track(track_id_obj)
            
            music_name = track_proto.name if track_proto.name else "unknown"
            artist_name = track_proto.artist[0].name if track_proto.artist else "unknown artist"

            file_base_name = sanitize_filename(f"{artist_name} - {music_name}")
            full_base_path = os.path.join(final_path, file_base_name)

            skip, file_path = resolve_file_duplicate(full_base_path, track_id_base62)    

            clean_file_name = os.path.basename(file_path)

            if skip:
                print(f"pulando {track_id_base62}::{clean_file_name} (ja existente)")
                continue
            
            print(f"comecando {track_id_base62}::{clean_file_name}")

            # download
            stream_data = session.content_feeder().load(track_id_obj, quality, False, None)

            if stream_data and stream_data.input_stream:
                audio_stream = stream_data.input_stream
                actual_stream = audio_stream.stream() if hasattr(audio_stream, 'stream') else audio_stream

                with open(file_path, 'wb') as f:
                    while True:
                        chunk = actual_stream.read(20000)
                        if not chunk:
                            break
                        f.write(chunk)

                # metadata
                try:
                    audio_tags = OggVorbis(file_path)
                    audio_tags["title"] = music_name
                    audio_tags["artist"] = artist_name
                    audio_tags["spotify_id"] = track_id_base62
                    audio_tags.save()
                except Exception as e:
                    print(f"{track_id_base62} - falha ao salvar metadados: {e}", file=sys.stderr)

                print(f"finalizado {track_id_base62}")
            else:
                print(f"erro ao carregar stream: {track_id_base62}", file=sys.stderr)

        except Exception as e:
            print(f"erro na musica {track_id_base62}: {e}", file=sys.stderr)

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print("comando: python3 downloader.py <creds_path> <download_path> <quality> <playlist_name>", file=sys.stderr)
        sys.exit(1)

    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])

