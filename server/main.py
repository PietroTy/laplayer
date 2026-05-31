import os
import time
import shutil
import re
import http.cookiejar
import random
import threading
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

# ── Ghost Watcher (Simulador de navegação humana para aquecer cookies) ──
_GHOST_VIDEOS = [
    "jfKfPfyJRdk",  # Lofi Girl
    "tQ0yjYUFKAE",  # Classical music
    "5qap5aO4i9A",  # Lofi Hip Hop
    "DWcUYDK81dQ",  # Nature sounds
    "dQw4w9WgXcQ",  # Rickroll
]

def simulate_ghost_watch():
    try:
        video_id = random.choice(_GHOST_VIDEOS)
        print(f"[GhostWatcher] Simulando visualização do vídeo '{video_id}' para aquecer cookies...")
        
        session = requests.Session()
        session.headers.update({
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        })
        
        # Carrega os cookies Netscape se o arquivo existir
        if os.path.exists(_COOKIES_FILE):
            jar = http.cookiejar.MozillaCookieJar(_COOKIES_FILE)
            try:
                jar.load(ignore_discard=True, ignore_expires=True)
                session.cookies = jar
            except Exception as e:
                print(f"[GhostWatcher] Aviso ao ler MozillaCookieJar: {e}")
            
        resp = session.get(f"https://www.youtube.com/watch?v={video_id}", timeout=10)
        if resp.status_code == 200:
            print(f"[GhostWatcher] Vídeo '{video_id}' carregado com sucesso (cookies aquecidos!).")
        else:
            print(f"[GhostWatcher] Erro ao carregar vídeo: HTTP {resp.status_code}")
    except Exception as e:
        print(f"[GhostWatcher] Erro ao simular visualização: {e}")

def trigger_ghost_watch_async():
    # Roda em thread separada daemon para não travar a inicialização ou requisições
    threading.Thread(target=simulate_ghost_watch, daemon=True).start()

@app.on_event("startup")
async def startup_event():
    print("[Backend] Iniciando Ghost Watcher na inicialização do servidor...")
    trigger_ghost_watch_async()

TEMP_DIR = "temp_downloads"
os.makedirs(TEMP_DIR, exist_ok=True)

# Formatos suportados e suas configurações de yt-dlp
_AUDIO_FORMATS = {
    # formato → (yt_format_selector, postprocessor_preferredcodec, extensão_final)
    "opus":  ("bestaudio[ext=webm]/bestaudio/best",  "opus",  "opus"),
    "m4a":   ("m4a/bestaudio[ext=m4a]/bestaudio/best", "aac",   "m4a"),
    "mp3":   ("bestaudio/best",                        "mp3",   "mp3"),
    "flac":  ("bestaudio/best",                        "flac",  "flac"),
}

# Mapeamento de qualidade (bitrate alvo para extração/conversão)
_QUALITY_MAP = {
    "low":    "64",
    "medium": "128",
    "high":   "192",
    "best":   "0",   # 0 = melhor disponível (sem reencoding de bitrate)
}

class TrackRequest(BaseModel):
    title: str
    artist: str
    album: str
    imageUrl: Optional[str] = None
    duration_ms: Optional[int] = 0
    skip_match: Optional[int] = 0
    youtube_url: Optional[str] = None  # Se fornecido, baixa diretamente sem busca
    audio_format: Optional[str] = "m4a"   # opus | m4a | mp3 | flac
    audio_quality: Optional[str] = "high" # low | medium | high | best

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

    # ── Verificar espaço em disco antes de qualquer coisa ──────────────────
    disk = shutil.disk_usage(TEMP_DIR)
    if disk.free < 50 * 1024 * 1024:  # menos de 50 MB livres
        raise HTTPException(
            status_code=507,
            detail=f"Sem espaço em disco no servidor. Livre: {disk.free // (1024*1024)} MB."
        )

    # ── Resolver configurações de formato/qualidade ────────────────────────
    fmt_key = (request.audio_format or "m4a").lower()
    if fmt_key not in _AUDIO_FORMATS:
        fmt_key = "m4a"
    yt_format_selector, preferred_codec, final_ext = _AUDIO_FORMATS[fmt_key]

    quality_key = (request.audio_quality or "high").lower()
    audio_quality_val = _QUALITY_MAP.get(quality_key, "192")

    print(f"[Backend] Formato={fmt_key}, Qualidade={quality_key} ({audio_quality_val}kbps)")

    def _build_ydl_opts(outtmpl_base: str) -> dict:
        """Constrói as opções yt-dlp com postprocessors para o formato escolhido."""
        postprocessors = []
        # Converte para o codec/formato alvo via FFmpeg
        pp = {
            'key': 'FFmpegExtractAudio',
            'preferredcodec': preferred_codec,
        }
        if audio_quality_val != "0":
            pp['preferredquality'] = audio_quality_val
        postprocessors.append(pp)
        # Embute metadados
        postprocessors.append({'key': 'FFmpegMetadata', 'add_metadata': True})

        return {
            'format': yt_format_selector,
            'outtmpl': outtmpl_base,
            'quiet': True,
            'no_warnings': True,
            'noplaylist': True,
            'nocheckcertificate': True,
            'geo_bypass': True,
            **_get_base_opts(),
            'postprocessors': postprocessors,
        }

    def _find_downloaded_file(base: str, expected_ext: str) -> Optional[str]:
        """Acha o arquivo gerado pelo yt-dlp (pode ser com extensão diferente)."""
        # Primeiro tenta a extensão esperada
        expected = f"{base}.{expected_ext}"
        if os.path.exists(expected) and os.path.getsize(expected) > 1024:
            return expected
        # Busca qualquer arquivo com o base_filename e uma extensão de áudio
        for ext in [expected_ext, 'opus', 'm4a', 'mp3', 'flac', 'webm', 'ogg']:
            candidate = f"{base}.{ext}"
            if os.path.exists(candidate) and os.path.getsize(candidate) > 1024:
                # Renomeia para a extensão final correta se necessário
                if ext != expected_ext:
                    renamed = f"{base}.{expected_ext}"
                    os.rename(candidate, renamed)
                    return renamed
                return candidate
        return None

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
        print(f"[Backend] Download direto de URL: {request.youtube_url} [{fmt_key}]")
        outtmpl_base = os.path.join(TEMP_DIR, base_filename)
        ydl_opts = _build_ydl_opts(f"{outtmpl_base}.%(ext)s")
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                ydl.extract_info(request.youtube_url, download=True)
                found = _find_downloaded_file(outtmpl_base, final_ext)
                if found:
                    downloaded_file = found
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

                # ── Filtro de duração PREVENTIVO (antes de baixar) ─────────────
                # Rejeita vídeos exageradamente longos (ex: lives de 3 horas ou compilações gigantes)
                video_duration_s = entry.get('duration') or 0
                if video_duration_s > 0:
                    if request.duration_ms and request.duration_ms > 0:
                        expected_s = request.duration_ms / 1000
                        # Aceita até 3x a duração esperada ou 25 minutos absolutos (o que for maior)
                        # para dar segurança contra compilações mas sem capar músicas longas de verdade
                        max_allowed_s = max(expected_s * 3.0 + 60, 1500)
                        if video_duration_s > max_allowed_s:
                            print(f"[Backend] Pulando vídeo extremamente longo: {video_duration_s:.0f}s > {max_allowed_s:.0f}s max | {video_id}")
                            continue
                    else:
                        # Sem duração de referência: rejeita vídeos com mais de 25 minutos (provável compilação de horas)
                        if video_duration_s > 1500:
                            print(f"[Backend] Pulando vídeo sem referência muito longo: {video_duration_s:.0f}s > 1500s | {video_id}")
                            continue

                video_url = f"https://www.youtube.com/watch?v={video_id}" if not video_id.startswith('http') else video_id
                print(f"[Backend] Tentando baixar video ({entry_idx + 1}/{len(entries)}): {video_url} [{video_duration_s:.0f}s]")
                
                outtmpl_base = os.path.join(TEMP_DIR, base_filename)
                ydl_opts = _build_ydl_opts(f"{outtmpl_base}.%(ext)s")
                    
                try:
                    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                        ydl.extract_info(video_url, download=True)
                        found = _find_downloaded_file(outtmpl_base, final_ext)
                        if found:
                            print(f"[Backend] Sucesso! Baixado: {video_url} → {found}")
                            downloaded_file = found
                            break
                except Exception as e:
                    print(f"[Backend] Falha ao baixar {video_url}: {e}")
                    # Limpa arquivos parciais/resíduos para evitar erros nas próximas tentativas
                    for ext in [final_ext, 'opus', 'm4a', 'mp3', 'flac', 'webm', 'ogg', 'part', 'ytdl']:
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
    # Apenas para m4a — outros formatos têm metadados embutidos pelo FFmpegMetadata
    if final_ext == 'm4a':
        try:
            from mutagen.mp4 import MP4, MP4Cover as _MP4Cover
            audio = MP4(downloaded_file)
            audio['\xa9nam'] = request.title
            audio['\xa9ART'] = request.artist
            audio['\xa9alb'] = request.album
            if cover_path and os.path.exists(cover_path):
                with open(cover_path, 'rb') as f:
                    cover_data = f.read()
                    audio['covr'] = [_MP4Cover(cover_data, imageformat=_MP4Cover.FORMAT_JPEG)]
            audio.save()
        except Exception as e:
            print(f"Aviso: falha ao embutir metadados m4a: {e}")

    # ── Informações de disco para diagnóstico ──────────────────────────────
    file_size_mb = os.path.getsize(downloaded_file) / (1024 * 1024)
    disk_after = shutil.disk_usage(TEMP_DIR)
    print(f"[Backend] Arquivo final: {file_size_mb:.1f} MB | Disco livre: {disk_after.free // (1024*1024)} MB")

    # Agendar limpeza dos arquivos após o envio
    background_tasks.add_task(cleanup_file, downloaded_file)
    if cover_path:
        background_tasks.add_task(cleanup_file, cover_path)

    # Determina o media_type correto para cada formato
    _media_types = {
        'm4a':  'audio/mp4',
        'opus': 'audio/ogg',
        'mp3':  'audio/mpeg',
        'flac': 'audio/flac',
    }
    media_type = _media_types.get(final_ext, 'audio/mpeg')

    # 10% de chance de simular uma visualização aleatória em background para manter os cookies ativos e quentes
    if random.random() < 0.10:
        trigger_ghost_watch_async()

    return FileResponse(
        path=downloaded_file,
        media_type=media_type,
        filename=f"{request.artist} - {request.title}.{final_ext}"
    )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
