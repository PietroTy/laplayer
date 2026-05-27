import os
import time
import shutil
import re
from fastapi import FastAPI, BackgroundTasks, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import Optional
import yt_dlp
import requests
from mutagen.mp4 import MP4, MP4Cover

# ---------------------------------------------------------------------------
# Cookie configuration – helps bypass YouTube bot-detection.
#
# Priority:
#   1. A `cookies.txt` (Netscape format) placed next to this file.
#   2. Chromium cookie store (read directly by yt-dlp).
#   3. Firefox cookie store (read directly by yt-dlp).
#
# To generate cookies.txt manually:
#   yt-dlp --cookies-from-browser chromium --cookies cookies.txt <any-yt-url>
# ---------------------------------------------------------------------------

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_COOKIES_FILE = os.path.join(_SCRIPT_DIR, "cookies.txt")

def _detect_cookie_opts() -> dict:
    """Detect and return the best available cookie options for yt-dlp (runs once at startup)."""
    if os.path.exists(_COOKIES_FILE):
        print(f"[Backend] Usando cookies.txt: {_COOKIES_FILE}")
        return {"cookiefile": _COOKIES_FILE}
    for browser in ("chromium", "firefox"):
        try:
            with yt_dlp.YoutubeDL({"cookies_from_browser": (browser,), "quiet": True, "no_warnings": True}) as _ydl:
                _ydl.cookiejar  # just accessing the jar is enough to validate
            print(f"[Backend] Usando cookies do navegador: {browser}")
            return {"cookies_from_browser": (browser,)}
        except Exception:
            pass
    print("[Backend] Nenhuma fonte de cookies disponível – downloads podem falhar por bot-detection.")
    return {}

# Cached at startup – avoids re-probing on every request
_COOKIE_OPTS: dict = _detect_cookie_opts()

# Node.js path for YouTube JS challenge solving (signature decryption)
import shutil as _shutil
import os
_NODE_PATH = ""
for _path in [
    _shutil.which("node"),
    "/home/pit/.nvm/versions/node/v20.20.0/bin/node",
    os.path.expanduser("~/.nvm/versions/node/v20.20.0/bin/node")
]:
    if _path and os.path.exists(_path):
        _NODE_PATH = _path
        break
if not _NODE_PATH:
    # default fallback just in case
    _NODE_PATH = "node"

def _get_base_opts() -> dict:
    """Common yt-dlp options shared across all calls (cookies + JS runtime)."""
    opts = {**_COOKIE_OPTS}
    if _NODE_PATH:
        opts["js_runtimes"] = {"node": {"path": _NODE_PATH}}
    
    # Enable the remote component challenge solver script needed for YouTube JS challenge solving
    opts["remote_components"] = "ejs:github"
    return opts

# Print configuration status on import
print(f"[Backend] Node.js detectado para resolver desafios do YouTube: {_NODE_PATH}")

app = FastAPI(title="Localify Backend Server")

TEMP_DIR = "temp_downloads"
os.makedirs(TEMP_DIR, exist_ok=True)

class TrackRequest(BaseModel):
    title: str
    artist: str
    album: str
    imageUrl: Optional[str] = None
    duration_ms: Optional[int] = 0
    skip_match: Optional[int] = 0
    youtube_url: Optional[str] = None  # Se fornecido, baixa diretamente sem busca

def cleanup_file(filepath: str):
    try:
        if os.path.exists(filepath):
            os.remove(filepath)
    except Exception as e:
        print(f"Erro ao limpar {filepath}: {e}")

def clean_query_string(artist: str, title: str) -> str:
    # Remove parenthetical details from the title/artist (like "feat.", "remix", or repetitive text)
    # matching (...) or [...]
    clean_title = re.sub(r'[\(\[][^\)\]]*[\)\]]', '', title)
    clean_artist = re.sub(r'[\(\[][^\)\]]*[\)\]]', '', artist)
    
    # Remove weird punctuation and extra spaces, but keep standard alphanumeric characters, accents, and hyphens
    clean_title = re.sub(r'[^\w\s\-\u00C0-\u017F]', '', clean_title)
    clean_artist = re.sub(r'[^\w\s\-\u00C0-\u017F]', '', clean_artist)
    
    # Join and trim
    query = f"{clean_artist.strip()} {clean_title.strip()}"
    # Replace multiple spaces with a single space
    query = re.sub(r'\s+', ' ', query).strip()
    return query

@app.get("/api/search")
async def search_tracks(q: str, limit: int = 8):
    """
    Busca músicas no YouTube sem baixar nada.
    Retorna candidatos com título, artista, duração e thumbnail.
    """
    if not q or not q.strip():
        raise HTTPException(status_code=400, detail="Parâmetro 'q' é obrigatório.")

    limit = max(1, min(limit, 20))  # Limita entre 1 e 20 resultados

    search_opts = {
        'extract_flat': True,
        'quiet': True,
        'no_warnings': True,
        'nocheckcertificate': True,
        'geo_bypass': True,
        **_get_base_opts(),
    }

    try:
        with yt_dlp.YoutubeDL(search_opts) as ydl:
            results = ydl.extract_info(f"ytsearch{limit}:{q.strip()}", download=False)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Erro ao buscar no YouTube: {e}")

    entries = results.get("entries", []) if results else []

    tracks = []
    for entry in entries:
        if not entry:
            continue
        video_id = entry.get("id") or entry.get("url", "")
        duration_s = entry.get("duration") or 0
        # Pega a melhor thumbnail disponível
        thumbnails = entry.get("thumbnails") or []
        thumbnail = ""
        if thumbnails:
            # Prefere a de maior resolução (última da lista normalmente)
            thumbnail = thumbnails[-1].get("url", "") or thumbnails[0].get("url", "")
        if not thumbnail:
            thumbnail = entry.get("thumbnail", "")

        tracks.append({
            "youtube_id":  video_id,
            "title":       entry.get("title", ""),
            "artist":      entry.get("uploader") or entry.get("channel") or "",
            "duration_ms": int(duration_s * 1000),
            "thumbnail":   thumbnail,
            "url":         f"https://www.youtube.com/watch?v={video_id}",
        })

    return {"results": tracks, "query": q.strip()}


@app.post("/api/download")
async def download_track(request: TrackRequest, background_tasks: BackgroundTasks):
    # Gerar ID único para o arquivo temporário
    timestamp = int(time.time() * 1000)
    base_filename = f"track_{timestamp}"
    
    # Baixar cover art se disponível
    cover_path = None
    if request.imageUrl:
        cover_path = os.path.join(TEMP_DIR, f"{base_filename}_cover.jpg")
        try:
            r = requests.get(request.imageUrl, stream=True, timeout=10)
            if r.status_code == 200:
                with open(cover_path, 'wb') as f:
                    r.raw.decode_content = True
                    shutil.copyfileobj(r.raw, f)
            else:
                cover_path = None
        except Exception as e:
            print(f"Aviso: falha ao baixar capa: {e}")
            cover_path = None

    # Limpar string de busca base para evitar parênteses longos e pontuações estranhas
    clean_base = clean_query_string(request.artist, request.title)

    # Lista ordenada de termos de busca para maximizar as chances de download com qualidade
    queries = [
        f"{clean_base} official audio",
        f"{clean_base} topic",
        f"{clean_base} audio",
        f"{clean_base} lyrics",
        f"{clean_base}",
        f"{request.artist} {request.title}"  # Último recurso: busca com strings originais sem limpeza
    ]

    downloaded_file = None

    # ── Caminho rápido: URL do YouTube fornecida diretamente ─────────────────
    if request.youtube_url:
        print(f"[Backend] Download direto de URL: {request.youtube_url}")
        ydl_opts = {
            'format': 'm4a/bestaudio/best',
            'outtmpl': os.path.join(TEMP_DIR, f"{base_filename}.%(ext)s"),
            'quiet': True,
            'no_warnings': True,
            'noplaylist': True,
            'nocheckcertificate': True,
            'geo_bypass': True,
            **_get_base_opts(),
            'postprocessors': [{'key': 'FFmpegMetadata', 'add_metadata': True}],
        }
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(request.youtube_url, download=True)
                ext = info.get('ext', 'm4a')
                candidate_file = os.path.join(TEMP_DIR, f"{base_filename}.{ext}")
                if os.path.exists(candidate_file):
                    downloaded_file = candidate_file
                    print(f"[Backend] Download direto concluído: {downloaded_file}")
        except Exception as e:
            print(f"[Backend] Falha no download direto: {e}")
            # Cai no fluxo normal de busca se o download direto falhar

    # ── Fluxo normal: busca por queries ──────────────────────────────────────
    if not downloaded_file:
        for attempt_idx, query in enumerate(queries):
            print(f"[Backend] Tentando busca ({attempt_idx + 1}/{len(queries)}): {query}")
            
            # Buscamos os primeiros 5 resultados (sem baixar) usando o prefixo ytsearch5:
            search_opts = {
                'extract_flat': True,
                'quiet': True,
                'no_warnings': True,
                'nocheckcertificate': True,
                'geo_bypass': True,
                **_get_base_opts(),
            }
            
            entries = []
            try:
                with yt_dlp.YoutubeDL(search_opts) as ydl:
                    search_results = ydl.extract_info(f"ytsearch5:{query}", download=False)
                    if search_results and 'entries' in search_results:
                        entries = list(search_results['entries'])
            except Exception as e:
                print(f"[Backend] Erro ao buscar '{query}': {e}")
                continue
                
            if not entries:
                print(f"[Backend] Nenhum resultado para '{query}'")
                continue
    
            # Se for o primeiro termo de busca e skip_match for fornecido, pulamos os primeiros N resultados
            start_idx = request.skip_match if (request.skip_match and request.skip_match > 0 and attempt_idx == 0) else 0
            if start_idx >= len(entries):
                # Se skip_match for maior que a lista, reduzimos ou pegamos o último para não ficar sem nada
                start_idx = max(0, len(entries) - 1)
                
            # Tentamos baixar cada vídeo retornado na busca
            for entry_idx in range(start_idx, len(entries)):
                entry = entries[entry_idx]
                video_id = entry.get('id') or entry.get('url')
                if not video_id:
                    continue
                    
                video_url = f"https://www.youtube.com/watch?v={video_id}" if not video_id.startswith('http') else video_id
                print(f"[Backend] Tentando baixar video ({entry_idx + 1}/{len(entries)}): {video_url}")
                
                # Filtro de duração opcional na primeira tentativa da primeira query para maior fidelidade
                use_duration_filter = (request.duration_ms and request.duration_ms > 0 and attempt_idx == 0 and entry_idx == start_idx)
                
                ydl_opts = {
                    'format': 'm4a/bestaudio/best',
                    'outtmpl': os.path.join(TEMP_DIR, f"{base_filename}.%(ext)s"),
                    'quiet': True,
                    'no_warnings': True,
                    'noplaylist': True,
                    'extract_audio': True,
                    'audio_format': 'm4a',
                    'nocheckcertificate': True,
                    'geo_bypass': True,
                    **_get_base_opts(),
                    'postprocessors': [{
                        'key': 'FFmpegMetadata',
                        'add_metadata': True,
                    }],
                }
                
                if use_duration_filter:
                    ydl_opts['match_filter'] = yt_dlp.utils.match_filter_func(
                        lambda info: 'duration' in info and (
                            abs(info['duration'] - request.duration_ms / 1000) < 60
                        )
                    )
                    
                try:
                    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                        info = ydl.extract_info(video_url, download=True)
                        ext = info.get('ext', 'm4a')
                        candidate_file = os.path.join(TEMP_DIR, f"{base_filename}.{ext}")
                        
                        if os.path.exists(candidate_file):
                            print(f"[Backend] Sucesso! Baixado: {video_url}")
                            downloaded_file = candidate_file
                            break
                except Exception as e:
                    print(f"[Backend] Falha ao baixar {video_url}: {e}")
                    # Limpa arquivos parciais/resíduos se existirem para evitar erros nas próximas tentativas
                    for ext in ['m4a', 'webm', 'mp3', 'part', 'ytdl']:
                        residual = os.path.join(TEMP_DIR, f"{base_filename}.{ext}")
                        if os.path.exists(residual):
                            try: os.remove(residual)
                            except: pass
                    continue
            
            if downloaded_file:
                break


    # Se todas as queries e vídeos falharem, levantamos erro
    if not downloaded_file or not os.path.exists(downloaded_file):
        if cover_path: cleanup_file(cover_path)
        raise HTTPException(status_code=500, detail="Não foi possível baixar nenhuma versão desta música após várias tentativas e termos de busca.")

    # Embutir ID3 Tags (Artista, Titulo, Album, Imagem) usando mutagen
    try:
        audio = MP4(downloaded_file)
        audio['\xa9nam'] = request.title
        audio['\xa9ART'] = request.artist
        audio['\xa9alb'] = request.album
        
        if cover_path and os.path.exists(cover_path):
            with open(cover_path, 'rb') as f:
                cover_data = f.read()
                audio['covr'] = [MP4Cover(cover_data, imageformat=MP4Cover.FORMAT_JPEG)]
                
        audio.save()
    except Exception as e:
        print(f"Aviso: falha ao embutir metadados extras com mutagen: {e}")

    # Agendar limpeza dos arquivos após o envio
    background_tasks.add_task(cleanup_file, downloaded_file)
    if cover_path:
        background_tasks.add_task(cleanup_file, cover_path)

    return FileResponse(
        path=downloaded_file,
        media_type='audio/mp4',
        filename=f"{request.artist} - {request.title}.m4a"
    )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
