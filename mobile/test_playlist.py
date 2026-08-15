import requests
import json
import re
import sys

url = sys.argv[1]
playlist_id = url.split('playlist/')[1].split('?')[0]
embed_url = f"https://open.spotify.com/embed/playlist/{playlist_id}"

res = requests.get(embed_url)
match = re.search(r'<script id="session" data-testid="session" type="application/json">(.*?)</script>', res.text)
if match:
    data = json.loads(match.group(1))
    token = data.get("accessToken")
    print("Token found!")
    
    api_url = f"https://api.spotify.com/v1/playlists/{playlist_id}/tracks?limit=100&offset=0"
    api_res = requests.get(api_url, headers={"Authorization": f"Bearer {token}"})
    if api_res.status_code == 200:
        api_data = api_res.json()
        print(f"Total tracks: {api_data.get('total')}")
        items = api_data.get("items", [])
        print(f"Items length: {len(items)}")
        if len(items) > 0:
            print(f"First track: {items[0]['track']['name']}")
    else:
        print(f"API Error {api_res.status_code}: {api_res.text}")
else:
    print("Session JSON not found")
