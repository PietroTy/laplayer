import requests
import json

client_id = 'd668a20e3f574ed1a2cad0ad99b369f9'
client_secret = 'fb94c9d90ffe4beba11cfeeb6070e2c7'

auth_res = requests.post(
    'https://accounts.spotify.com/api/token',
    data={'grant_type': 'client_credentials'},
    auth=(client_id, client_secret)
)
token = auth_res.json()['access_token']
playlist_id = '6qgL3mJJKnnoKMn3xyKlmD'

url = f'https://api.spotify.com/v1/playlists/{playlist_id}/tracks'
all_items = []

while url:
    res = requests.get(url, headers={'Authorization': f'Bearer {token}'})
    data = res.json()
    items = data.get('items', [])
    all_items.extend(items)
    url = data.get('next')

# Now simulate Dart parsing
pageTracks = 0
for item in all_items:
    if item and item.get('track'):
        trackItem = item['track']
        
        # simulated check
        artists = trackItem.get('artists', [])
        
        album = trackItem.get('album', {})
        album_images = album.get('images', [])
        
        pageTracks += 1

print(f"Total parsed tracks: {pageTracks}")
