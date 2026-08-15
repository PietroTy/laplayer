import time
import yt_dlp

opts = {
    'extract_flat': True,
    'quiet': True,
    'no_warnings': True,
    'nocheckcertificate': True,
    'geo_bypass': True,
    'extractor_args': {'youtube': {'player_client': ['android_vr', 'web']}}
}

query = "Gorillaz Feel Good Inc"

print("--- TEST 1: Single query ytsearch5 ---")
t0 = time.time()
with yt_dlp.YoutubeDL(opts) as ydl:
    res = ydl.extract_info(f"ytsearch5:{query}", download=False)
t1 = time.time()
print(f"Time taken for single search: {t1 - t0:.2f}s")
if res and 'entries' in res:
    for e in res['entries']:
        print(" - ", e.get('title'), "| Channel:", e.get('uploader') or e.get('channel'))
