import requests
import sys

url = sys.argv[1]
playlist_id = url.split('playlist/')[1].split('?')[0]
embed_url = f"https://open.spotify.com/embed/playlist/{playlist_id}"

res = requests.get(embed_url)
with open('embed_output.html', 'w', encoding='utf-8') as f:
    f.write(res.text)
print("Saved to embed_output.html")
