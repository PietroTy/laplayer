import requests
import time

t0 = time.time()
r = requests.post(
    "http://127.0.0.1:8000/api/download",
    json={
        "title": "Feel Good Inc.",
        "artist": "Gorillaz",
        "album": "Demon Days",
        "duration_ms": 222000,
        "audio_format": "m4a",
        "audio_quality": "high"
    },
    headers={"X-Access-Key": "LAPLAYER-VIP-8812"}
)
t1 = time.time()

print(f"Status: {r.status_code}")
print(f"Size: {len(r.content)} bytes")
print(f"Total time elapsed: {t1 - t0:.2f} seconds!")
