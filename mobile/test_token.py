import urllib.request, re
try:
    req = urllib.request.Request(
        'https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT',
        headers={'User-Agent': 'Mozilla/5.0'}
    )
    r = urllib.request.urlopen(req).read().decode('utf-8')
    match = re.search(r'"accessToken":"([^"]+)"', r)
    print("MATCH:", bool(match))
    if match:
        print("TOKEN:", match.group(1)[:20] + "...")
except Exception as e:
    print("ERROR:", e)
