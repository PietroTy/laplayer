import sys
import re
import json
from librespot.core import Session
from librespot import metadata
from google.protobuf.json_format import MessageToDict

def extract_playlist_id(url):
    match = re.search(r'(track|playlist)/([a-zA-Z0-9]+)', url)
    if match:
        return match.group(1), match.group(2)
    return None, None

def start_saved_session(creds_path):
    try:
        session = Session.Builder().stored_file(creds_path).create()
        return session
    except Exception as e:
        print(f"erro ao carregar sessao: {e}", file=sys.stderr)
        sys.exit(1)

def main(creds_path, playlist_url):
    type, id = extract_playlist_id(playlist_url)
    if not type:
        print("url invalida", file=sys.stderr)
        sys.exit(1)

    print("carregando credenciais e conectando ao spotify...")
    session = start_saved_session(creds_path)

    print("conectado, buscando playlist")

    try:
        music_list = []
        if type == "playlist":
            playlist_id_obj = metadata.PlaylistId.from_base62(id)
            playlist_proto = session.api().get_playlist(playlist_id_obj)
            playlist_data = MessageToDict(playlist_proto, preserving_proto_field_name=True)

            playlist_name = playlist_data.get('attributes', {}).get('name', 'Unknown')
            music_list.append({
                "playlist": playlist_name
            })

            items = playlist_data.get('contents', {}).get('items', [])

            print(f"playlist: {playlist_name} - n de musicas: {len(items)}\n")
            print(f"playlist_id: {id}")

            count = 0
            
            for item in items:
                uri = item.get('uri', '')
                if not uri.startswith('spotify:track:'):
                    continue

                track_id_base62 = uri.split(':')[-1]

                music_list.append({
                    "spotify_id": track_id_base62
                })

                count += 1

        elif type == "track":
            music_list.append({
                "playlist": "",
                "spotify_id": id
            })

        print("\njson")
        json_result = json.dumps(music_list, indent=2, ensure_ascii=False)
        print(json_result)

    except Exception as e:
        print(f"erro consultando metadados: {e}")
        sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("chamada incorreta. ex: python3 scraper.py credentials.jso 'https://open.spotify.com/playlist/...'", file=sys.stderr)
        sys.exit(1)

    main(sys.argv[1], sys.argv[2])
