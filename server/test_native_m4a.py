import time
import yt_dlp

opts = {
    'format': 'bestaudio[ext=m4a]/bestaudio/best',
    'outtmpl': 'test_direct.%(ext)s',
    'quiet': True,
    'no_warnings': True,
    'extractor_args': {'youtube': {'player_client': ['android_vr', 'web']}}
}

t0 = time.time()
with yt_dlp.YoutubeDL(opts) as ydl:
    ydl.download(["https://www.youtube.com/watch?v=-Fp0aTedjwI"])
t1 = time.time()
print(f"Direct native m4a download time: {t1 - t0:.2f} seconds!")
