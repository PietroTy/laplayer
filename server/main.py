import unicodedata
import os
import time
import shutil
import re
import http.cookiejar
import random
import threading
import concurrent.futures
import subprocess
import json
from contextlib import asynccontextmanager
from fastapi import FastAPI, BackgroundTasks, HTTPException, Header, Query, Depends
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import Optional
import yt_dlp
import requests
from mutagen.mp4 import MP4, MP4Cover
from soulseek_client import get_soulseek_client

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
    """Detect and return cookie options if cookies.txt is valid, or empty dict."""
    if os.path.exists(_COOKIES_FILE):
        try:
            jar = http.cookiejar.MozillaCookieJar(_COOKIES_FILE)
            jar.load(ignore_discard=True, ignore_expires=True)
            if len(jar) > 0:
                print(f"[Backend] ✅ cookies.txt carregado com {len(jar)} cookies (necessário para buscar conteúdo NSFW/age-restricted)")
                return {"cookiefile": _COOKIES_FILE}
        except Exception as e:
            print(f"[Backend] ⚠ cookies.txt encontrado mas inválido: {e}")
    print("[Backend] ⚠ Nenhum cookies.txt válido — buscas de conteúdo NSFW/age-restricted podem falhar")
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
    """Common yt-dlp options shared across all calls (cookies + JS runtime + timeout protection)."""
    opts = {**_COOKIE_OPTS}
    if _NODE_PATH:
        opts["js_runtimes"] = {"node": {"path": _NODE_PATH}}
    
    # Enable the remote component challenge solver script needed for YouTube JS challenge solving
    opts["remote_components"] = "ejs:github"
    opts["extractor_args"] = {"youtube": {"player_client": ["android", "web"]}}

    # Proteção estrita contra travamento/throttling de rede do YouTube
    opts["socket_timeout"] = 10  # Timeout de 10 segundos por socket TCP
    opts["retries"] = 2          # Máximo 2 retentativas de requisição
    opts["fragment_retries"] = 2 # Máximo 2 retentativas por pedaço de áudio
    opts["concurrent_fragment_downloads"] = 1
    opts["http_chunk_size"] = 1048576  # Baixa em blocos de 1MB para evitar throttling e travamento do YouTube
    return opts

# Print configuration status on import
print(f"[Backend] Node.js detectado para resolver desafios do YouTube: {_NODE_PATH}")

# ── Sistema de Chaves de Acesso (App License Keys) ──────────────────────
VALID_KEYS = {
    "LAPLAYER-Pietro-7717",
    "LAPLAYER-Alpha-9901",
    "LAPLAYER-VIP-8812",
    "LAPLAYER-Beta-4521",
    "LAPLAYER-Friend-3021",
    "LAPLAYER-Secret-5541",
}

def verify_access_key(
    x_access_key: Optional[str] = Header(None, alias="X-Access-Key"),
    key: Optional[str] = Query(None)
):
    provided_key = x_access_key or key
    if not provided_key or provided_key.strip() not in VALID_KEYS:
        print(f"[Backend] Acesso REJEITADO para a chave fornecida: '{provided_key}'")
        raise HTTPException(
            status_code=401,
            detail="Acesso não autorizado: Chave de acesso inválida, inativa ou ausente."
        )
    print(f"[Backend] Acesso LIBERADO para a chave: '{provided_key}'")

# ── Logging de Chaves e Downloads ─────────────────────────────────────────
_STATS_FILE = os.path.join(_SCRIPT_DIR, "key_stats.json")
_LOG_FILE = os.path.join(_SCRIPT_DIR, "key_downloads.log")
_stats_lock = threading.Lock()

def log_key_download(key: str, artist: str, title: str):
    if not key:
        return
    with _stats_lock:
        data = {"keys": {}}
        if os.path.exists(_STATS_FILE):
            try:
                with open(_STATS_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception as e:
                print(f"[Backend] Erro ao carregar arquivo de estatísticas: {e}")
        
        if "keys" not in data:
            data["keys"] = {}
            
        if key not in data["keys"]:
            data["keys"][key] = {
                "downloads_count": 0,
                "last_download_at": "",
                "history": []
            }
            
        key_data = data["keys"][key]
        key_data["downloads_count"] += 1
        key_data["last_download_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
        key_data["history"].append({
            "title": title,
            "artist": artist,
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")
        })
        
        if len(key_data["history"]) > 100:
            key_data["history"] = key_data["history"][-100:]
            
        try:
            with open(_STATS_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
        except Exception as e:
            print(f"[Backend] Erro ao salvar arquivo de estatísticas: {e}")

        # Também grava o log simples em texto corrido
        try:
            with open(_LOG_FILE, "a", encoding="utf-8") as f:
                f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Key: {key} | Baixou: {artist} - {title}\n")
        except Exception as e:
            print(f"[Backend] Erro ao gravar log de downloads em texto: {e}")

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

# ── Lifespan (substitui @app.on_event deprecado) ──────────────────────────
@asynccontextmanager
async def lifespan(app):
    print("[Backend] Iniciando Ghost Watcher na inicialização do servidor...")
    trigger_ghost_watch_async()
    # Verifica se o slskd está disponível
    slsk = get_soulseek_client()
    if slsk.is_available():
        print("[Backend] ✅ Soulseek (slskd) disponível como fonte de fallback")
    else:
        print("[Backend] ⚠ Soulseek (slskd) não disponível — apenas YouTube será usado")
    yield

app = FastAPI(
    title="Localify Backend Server",
    dependencies=[Depends(verify_access_key)],
    lifespan=lifespan,
)

TEMP_DIR = "temp_downloads"
os.makedirs(TEMP_DIR, exist_ok=True)

# ── Rate-limit tracking ────────────────────────────────────────────────────
# Tracks when YouTube rate-limiting was last detected so we can skip YouTube
# entirely for a cooldown period and go straight to Soulseek.
_yt_rate_limit_until: float = 0.0
_yt_rate_limit_lock = threading.Lock()
_YT_RATE_LIMIT_COOLDOWN = 300  # 5 minutos de cooldown após rate-limit

def _mark_yt_rate_limited():
    """Mark YouTube as rate-limited for the cooldown period."""
    global _yt_rate_limit_until
    with _yt_rate_limit_lock:
        _yt_rate_limit_until = time.time() + _YT_RATE_LIMIT_COOLDOWN
        print(f"[Backend] ⚠ YouTube rate-limited! Pulando para Soulseek pelos próximos {_YT_RATE_LIMIT_COOLDOWN}s")

def _is_yt_rate_limited() -> bool:
    """Check if YouTube is currently in cooldown from rate-limiting."""
    with _yt_rate_limit_lock:
        return time.time() < _yt_rate_limit_until

def _is_rate_limit_error(error_msg: str) -> bool:
    """Detect if an error message indicates YouTube rate-limiting or bot detection."""
    rate_limit_indicators = [
        "rate-limited",
        "rate limit",
        "try again later",
        "This content isn't available",
        "HTTP Error 429",
        "Sign in to confirm",
        "confirm you're not a bot",
        "confirm you’re not a bot",
        "bot",
        "timeout",
        "timed out",
        "read timeout",
        "incompleteread",
        "connection reset",
        "connection refused",
        "network is unreachable",
        "throttled",
    ]
    error_lower = str(error_msg).lower()
    return any(indicator.lower() in error_lower for indicator in rate_limit_indicators)

# Formatos suportados e suas configurações de yt-dlp
_AUDIO_FORMATS = {
    # formato → (yt_format_selector, postprocessor_preferredcodec, extensão_final)
    "opus":  ("bestaudio[ext=webm]/bestaudio/best", "opus",  "opus"),
    "m4a":   ("bestaudio[ext=m4a]/bestaudio/best",  "aac",   "m4a"),
    "mp3":   ("bestaudio/best",                      "mp3",   "mp3"),
    "flac":  ("bestaudio/best",                      "flac",  "flac"),
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
    # 1. Normaliza fontes Unicode/Vaporwave/Fullwidth (NFKC)
    title = unicodedata.normalize('NFKC', title)
    artist = unicodedata.normalize('NFKC', artist)
    
    # 2. Trata artistas com caracteres de Braille ou Kaomojis densos (ex: ⣎⡇ꉺლ):
    has_braille = any(0x2800 <= ord(c) <= 0x28FF for c in artist) or 'ꉺლ' in artist
    if has_braille:
        artist_clean = re.sub(r'[\(\)\[\]\}/\\\|]', '', artist)
        artist = artist_clean[:6].strip()
    else:
        # Remove kaomojis decorativos e seus parênteses (ex: (◍•ᴗ•◍), ( ͡° ͜ʖ ͡°), ♡, ⚡, ♫)
        title = re.sub(r'[\(（\[【\{][^\w\s\u00C0-\u017F\u3040-\u30FF\u4E00-\u9FFF]*[\)）\]】\}]', '', title)
        artist = re.sub(r'[\(（\[【\{][^\w\s\u00C0-\u017F\u3040-\u30FF\u4E00-\u9FFF]*[\)）\]】\}]', '', artist)
        
        title = re.sub(r'[\◍\•\ᴗ\♡\⚡\♫\🌈\😺\͡\°\͜\ʖ\╯\□\°\）\╯\︵\┻\━\┻]', '', title)
        artist = re.sub(r'[\◍\•\ᴗ\♡\⚡\♫\🌈\😺\͡\°\͜\ʖ\╯\□\°\）\╯\︵\┻\━\┻]', '', artist)

    # 3. Limpa parênteses vazios residuais e junta letras isoladas por espaço
    title = re.sub(r'[\(\)\[\]\{\}]', '', title)
    artist = re.sub(r'[\(\)\[\]\{\}]', '', artist)
    
    title = re.sub(r'(?<=\b[A-Za-z])\s+(?=[A-Za-z]\b)', '', title)
    artist = re.sub(r'(?<=\b[A-Za-z])\s+(?=[A-Za-z]\b)', '', artist)
    
    query = f"{artist.strip()} {title.strip()}"
    return re.sub(r'\s+', ' ', query).strip()

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
async def download_track(
    request: TrackRequest,
    background_tasks: BackgroundTasks,
    x_access_key: Optional[str] = Header(None, alias="X-Access-Key"),
    key: Optional[str] = Query(None)
):
    raw_key = x_access_key if isinstance(x_access_key, str) else (key if isinstance(key, str) else "UNKNOWN-KEY")
    provided_key = raw_key.strip()
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
        """Constrói as opções yt-dlp sem re-encoding desnecessário do FFmpeg (extração direta)."""
        postprocessors = []
        # Converte apenas se o container original for incompatível
        pp = {
            'key': 'FFmpegExtractAudio',
            'preferredcodec': preferred_codec,
            'preferredquality': audio_quality_val, # respeita a qualidade configurada no app (64, 128, 192, ou 0=best)
        }
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
        # Busca qualquer arquivo com o base_filename e uma extensão de áudio/vídeo
        for ext in [expected_ext, 'opus', 'm4a', 'mp3', 'flac', 'webm', 'ogg', 'mp4', 'mkv', 'aac']:
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
    raw_query = f"{request.artist} {request.title}"

    # Query sem termos restritos/bloqueados do YouTube (ex: 'sex', 'ex', 'explicit')
    # que causam 0 resultados na busca do yt-dlp/YouTube API
    unrestricted_query = re.sub(r'\b(sex|ex|explicit|nsfw|nude|porn)\b', '', raw_query, flags=re.IGNORECASE)
    unrestricted_query = re.sub(r'[\'\"’]', '', unrestricted_query)
    unrestricted_query = re.sub(r'\s+', ' ', unrestricted_query).strip()

    # Query somente com artista + título sem termos em parênteses
    title_clean = re.sub(r'[\(\[][^\)\]]*[\)\]]', '', request.title).strip()
    title_only_query = f"{request.artist} {title_clean}".strip()

    candidate_queries = [
        clean_base,
        f"{request.artist} {request.title} official audio",
        f"{request.artist} {request.title} audio",
        raw_query,
        unrestricted_query,
        title_only_query,
        request.title
    ]

    # Remove duplicatas mantendo a ordem
    queries = []
    seen_q = set()
    for q in candidate_queries:
        norm = q.lower().strip()
        if norm and norm not in seen_q:
            seen_q.add(norm)
            queries.append(q)

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

    # Detecta se a música/artista é puramente ruído de símbolos/Zalgo
    def _is_mostly_symbols(s: str) -> bool:
        clean = re.sub(r'[\s\(\)\[\]\-_]', '', s)
        if not clean: return True
        letters = len(re.findall(r'[\w\u3040-\u30FF\u4E00-\u9FFF]', clean))
        symbols = len(clean) - letters
        return symbols > letters or letters < 2

    # Se for Zalgo/Símbolos puros, inclui busca fallback por "Artista Topic"
    if _is_mostly_symbols(request.title) or _is_mostly_symbols(request.artist):
        topic_query = f"{request.artist} Topic"
        if topic_query not in queries:
            queries.insert(0, topic_query)

    # ── Fluxo normal: busca por queries ──────────────────────────────────────
    # Se o YouTube estiver rate-limited, pula direto pro Soulseek
    yt_skipped = False
    if not downloaded_file and _is_yt_rate_limited():
        print(f"[Backend] YouTube em cooldown por rate-limit. Pulando direto para Soulseek.")
        yt_skipped = True

    if not downloaded_file and not yt_skipped:
        for attempt_idx, query in enumerate(queries):
            print(f"[Backend] Tentando busca rápida ({attempt_idx + 1}/{len(queries)}): {query}")
            
            # Buscamos os primeiros 8 resultados (sem baixar) usando o prefixo ytsearch8:
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
                    search_results = ydl.extract_info(f"ytsearch8:{query}", download=False)
                    if search_results and 'entries' in search_results:
                        entries = list(search_results['entries'])
            except Exception as e:
                print(f"[Backend] Erro ao buscar '{query}': {e}")
                continue
                
            if not entries:
                print(f"[Backend] Nenhum resultado para '{query}'")
                continue

            # ── Algoritmo Inteligente de Ranking v2.5 (Desempate por Nome em Durações Iguais) ──
            def _score_entry(e):
                title = (e.get('title') or '').lower()
                uploader = (e.get('uploader') or e.get('channel') or '').lower()
                dur = e.get('duration') or 0
                expected_s = (request.duration_ms or 0) / 1000

                score = 0
                
                # 1. Validação do Artista (Previne Topic Channel de outro artista)
                artist_clean = re.sub(r'[^\w\s]', '', request.artist.lower())
                artist_words = set(artist_clean.split())
                uploader_words = set(re.sub(r'[^\w\s]', '', uploader).split())
                title_words = set(re.sub(r'[^\w\s]', '', title).split())
                
                artist_in_uploader = len(artist_words & uploader_words) > 0 if artist_words else False
                artist_in_title = len(artist_words & title_words) > 0

                # Bônus de Canal Topic APENAS se o artista bater
                if 'topic' in uploader:
                    if artist_in_uploader or artist_in_title:
                        score += 120
                    else:
                        score -= 150 # Penaliza Topic Channel de OUTRO artista!

                # 2. Similaridade e Coincidência de Palavras do Título (Desempate por Nome)
                expected_title_clean = re.sub(r'[\(\[][^\)\]]*[\)\]]', '', request.title).lower()
                expected_title_words = set(re.sub(r'[^\w\s]', '', expected_title_clean).split())
                
                name_similarity_score = 0
                if expected_title_words:
                    overlap_ratio = len(expected_title_words & title_words) / len(expected_title_words)
                    name_similarity_score = int(overlap_ratio * 100)
                    score += name_similarity_score
                    
                    if overlap_ratio < 0.15:
                        score -= 200 # Título totalmente incompatível

                # 3. Áudio Oficial vs Vídeo
                if 'official audio' in title or 'audio oficial' in title:
                    score += 60
                elif 'audio' in title:
                    score += 30
                elif 'lyric' in title or 'legendado' in title:
                    score += 20

                # Versões específicas (Remix, Edit, Live, Radio, Acoustic, Instrumental, Mix, etc.)
                version_keywords = ['remix', 'edit', 'radio', 'live', 'ao vivo', 'acoustic', 'acustico', 'instrumental', 'mix', 'ice pop', 'club']
                expected_full_lower = f"{request.title} {request.artist}".lower()
                for kw in version_keywords:
                    if kw in expected_full_lower and kw in title:
                        score += 50
                    elif kw in expected_full_lower and kw not in title:
                        score -= 40
                    elif kw not in expected_full_lower and kw in title:
                        score -= 30 # Vídeo é um remix/live mas o Spotify pede a versão original solo!

                # 4. Proximidade de Duração com Desempate por Nome quando as Durações são Iguais
                if expected_s > 0 and dur > 0:
                    diff = abs(dur - expected_s)
                    if diff <= 2:
                        # Duração praticamente idêntica: usa a similaridade do nome como critério decisivo de desempate!
                        score += 80 + name_similarity_score
                    elif diff <= 5:
                        score += 50 + (name_similarity_score // 2)
                    elif diff <= 15:
                        score += 10
                    elif diff <= 25:
                        score -= 60
                    else:
                        score -= 250 # Diferença grotesca de duração (compilação ou versão errada)

                return score

            entries.sort(key=_score_entry, reverse=True)
    
            # Se for o primeiro termo de busca e skip_match for fornecido, pulamos os primeiros N resultados
            start_idx = request.skip_match if (request.skip_match and request.skip_match > 0 and attempt_idx == 0) else 0
            if start_idx >= len(entries):
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
                        
                        # Rejeita vídeos extremamente curtos (como teasers, ringtones ou sound effects)
                        # Aceita apenas se tiver pelo menos 50% da duração esperada (para músicas com mais de 10s)
                        min_allowed_s = expected_s * 0.5
                        if video_duration_s < min_allowed_s and expected_s > 10:
                            print(f"[Backend] Pulando vídeo extremamente curto: {video_duration_s:.0f}s < {min_allowed_s:.0f}s min (esperado {expected_s:.0f}s) | {video_id}")
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
                    
                # ── Download via subprocesso com timeout REAL (SIGKILL) ──
                _DL_TIMEOUT = 30  # segundos máximo por vídeo
                outtmpl_arg = f"{outtmpl_base}.%(ext)s"
                cmd = [
                    "yt-dlp",
                    "--no-playlist",
                    "--no-check-certificates",
                    "--geo-bypass",
                    "--quiet", "--no-warnings",
                    "--socket-timeout", "10",
                    "--retries", "2",
                    "--fragment-retries", "2",
                    "--http-chunk-size", "1M",
                    "--extractor-args", "youtube:player_client=android,web",
                    "-x", "--audio-format", preferred_codec,
                    "--audio-quality", audio_quality_val,
                    "--embed-metadata",
                    "-o", outtmpl_arg,
                    video_url,
                ]
                # Adiciona cookies se existirem
                cookie_file = _COOKIE_OPTS.get("cookiefile")
                if cookie_file and os.path.isfile(cookie_file):
                    cmd.insert(1, "--cookies")
                    cmd.insert(2, cookie_file)

                try:
                    result = subprocess.run(
                        cmd,
                        cwd=os.path.dirname(os.path.abspath(__file__)),
                        capture_output=True, text=True,
                        timeout=_DL_TIMEOUT,
                    )
                    # Verifica se o arquivo foi baixado (ffprobe warnings causam exit code != 0 mas o arquivo existe)
                    found = _find_downloaded_file(outtmpl_base, final_ext)
                    if found:
                        fsize = os.path.getsize(found)
                        if fsize > 10000:  # > 10KB = arquivo válido
                            print(f"[Backend] Sucesso! Baixado: {video_url} -> {found}")
                            downloaded_file = found
                            break
                        else:
                            print(f"[Backend] Arquivo muito pequeno ({fsize}B), descartando: {found}")
                            os.remove(found)
                    # Sem arquivo: trata como erro
                    if result.returncode != 0:
                        error_str = result.stderr or result.stdout or f"exit code {result.returncode}"
                        print(f"[Backend] Falha ao baixar {video_url}: {error_str[:300]}")
                        if _is_rate_limit_error(error_str):
                            _mark_yt_rate_limited()
                            for ext_clean in [final_ext, 'opus', 'm4a', 'mp3', 'flac', 'webm', 'ogg', 'mp4', 'part', 'ytdl']:
                                residual = os.path.join(TEMP_DIR, f"{base_filename}.{ext_clean}")
                                if os.path.exists(residual):
                                    try: os.remove(residual)
                                    except: pass
                            break
                except subprocess.TimeoutExpired:
                    print(f"[Backend] ⏰ TIMEOUT ({_DL_TIMEOUT}s)! Download travou em {video_url} — pulando")
                    # Após 2 timeouts seguidos, marca como rate-limited e pula pro Soulseek
                    if entry_idx >= 1:
                        _mark_yt_rate_limited()
                        for ext_clean in [final_ext, 'opus', 'm4a', 'mp3', 'flac', 'webm', 'ogg', 'mp4', 'part', 'ytdl']:
                            residual = os.path.join(TEMP_DIR, f"{base_filename}.{ext_clean}")
                            if os.path.exists(residual):
                                try: os.remove(residual)
                                except: pass
                        break
                except Exception as e:
                    error_str = str(e)
                    print(f"[Backend] Falha ao baixar {video_url}: {error_str}")
                    if _is_rate_limit_error(error_str):
                        _mark_yt_rate_limited()
                        break
                # Limpa arquivos parciais entre tentativas
                for ext_clean in [final_ext, 'opus', 'm4a', 'mp3', 'flac', 'webm', 'ogg', 'mp4', 'part', 'ytdl']:
                    residual = os.path.join(TEMP_DIR, f"{base_filename}.{ext_clean}")
                    if os.path.exists(residual):
                        try: os.remove(residual)
                        except: pass
                time.sleep(0.5)
                continue
            
            if downloaded_file:
                break
            # Se foi rate-limited, sai do loop de queries também
            if _is_yt_rate_limited():
                break


    # ── Fallback Soulseek: tenta buscar no Soulseek se YouTube falhou ──────
    if not downloaded_file or not os.path.exists(downloaded_file):
        print(f"[Backend] YouTube falhou para '{request.artist} - {request.title}'. Tentando Soulseek...")
        try:
            slsk = get_soulseek_client()
            if slsk.is_available():
                outtmpl_base = os.path.join(TEMP_DIR, base_filename)
                slsk_result = slsk.search_and_download(
                    artist=request.artist,
                    title=request.title,
                    target_path=f"{outtmpl_base}.{final_ext}",
                    search_timeout=30,
                    download_timeout=120,
                )
                if slsk_result and os.path.exists(slsk_result):
                    downloaded_file = slsk_result
                    # Atualiza a extensão final se o Soulseek baixou em formato diferente
                    actual_ext = os.path.splitext(slsk_result)[1].lstrip('.')
                    if actual_ext and actual_ext != final_ext:
                        final_ext = actual_ext
                    print(f"[Backend] ✅ Download via Soulseek concluído: {slsk_result}")
            else:
                print("[Backend] Soulseek não disponível para fallback")
        except Exception as e:
            print(f"[Backend] Erro no fallback Soulseek: {e}")

    # Se YouTube e Soulseek falharem, levantamos 404 Not Found
    if not downloaded_file or not os.path.exists(downloaded_file):
        if cover_path: cleanup_file(cover_path)
        raise HTTPException(
            status_code=404,
            detail=f"Nenhuma versão da música '{request.artist} - {request.title}' foi encontrada no YouTube nem no Soulseek após várias tentativas."
        )


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

    # Registrar o download bem sucedido associado à chave de acesso
    log_key_download(provided_key, request.artist, request.title)

    return FileResponse(
        path=downloaded_file,
        media_type=media_type,
        filename=f"{request.artist} - {request.title}.{final_ext}"
    )

# ── Spotify Proxy Endpoints ────────────────────────────────────────────────
_spotify_token_cache: Optional[str] = None
_spotify_token_time: float = 0

def fetch_fresh_spotify_token() -> Optional[str]:
    """Obtém um access_token do Spotify (Client Credentials oficial ou fallback)."""
    client_id = os.getenv("SPOTIFY_CLIENT_ID")
    client_secret = os.getenv("SPOTIFY_CLIENT_SECRET")

    # 1. Fluxo Oficial: Client Credentials se SPOTIFY_CLIENT_ID e SPOTIFY_CLIENT_SECRET existirem no .env
    if client_id and client_secret:
        try:
            resp = requests.post(
                "https://accounts.spotify.com/api/token",
                data={"grant_type": "client_credentials"},
                auth=(client_id.strip(), client_secret.strip()),
                timeout=5,
            )
            if resp.status_code == 200:
                data = resp.json()
                token = data.get("access_token")
                if token:
                    print("[Backend] ✅ Token do Spotify obtido com sucesso via Client Credentials API!")
                    return token
            else:
                print(f"[Backend] ⚠ Erro ao obter token do Spotify via API oficial: HTTP {resp.status_code}")
        except Exception as e:
            print(f"[Backend] Exceção ao solicitar token do Spotify: {e}")

    # 2. Tenta método de web scrape em embed pages (legado)
    session = requests.Session()
    session.headers.update({
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Accept-Language": "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    })
    
    urls = [
        "https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT",
    ]
    
    for url in urls:
        try:
            resp = session.get(url, timeout=5)
            if resp.status_code == 200:
                match = re.search(r'"accessToken":"([^"]+)"', resp.text)
                if match and match.group(1):
                    return match.group(1)
        except Exception as e:
            print(f"[Backend] Erro ao obter token do Spotify via {url}: {e}")
            
    return None

@app.get("/api/spotify/token")
async def get_spotify_token(force_refresh: bool = False):
    """
    Obtém um access_token do Spotify com cache inteligente e renovação em caso de erro.
    """
    global _spotify_token_cache, _spotify_token_time
    now = time.time()
    
    if not force_refresh and _spotify_token_cache and (now - _spotify_token_time < 1800):
        return {"access_token": _spotify_token_cache}
        
    token = fetch_fresh_spotify_token()
    if token:
        _spotify_token_cache = token
        _spotify_token_time = now
        return {"access_token": token}
        
    if _spotify_token_cache:
        return {"access_token": _spotify_token_cache}
        
    raise HTTPException(status_code=500, detail="Não foi possível obter token do Spotify no momento.")

@app.get("/api/spotify/search")
async def spotify_search_proxy(q: str, limit: int = 20):
    """
    Busca faixas resiliente (Spotify API com retry em 429 e fallback gracioso para busca online).
    """
    if not q or not q.strip():
        return {"tracks": {"items": []}}

    limit = max(1, min(limit, 50))
    
    # ── Tentativa 1 & 2: API do Spotify com auto-refresh de token ──
    for attempt in range(2):
        try:
            token_res = await get_spotify_token(force_refresh=(attempt > 0))
            token = token_res["access_token"]
            
            headers = {
                "Authorization": f"Bearer {token}",
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            }
            
            resp = requests.get(
                "https://api.spotify.com/v1/search",
                params={"q": q, "type": "track", "limit": limit},
                headers=headers,
                timeout=6
            )
            
            if resp.status_code == 200:
                data = resp.json()
                items = data.get("tracks", {}).get("items", [])
                if items:
                    return data
            elif resp.status_code in (429, 401, 403):
                print(f"[Backend] Spotify API retornou HTTP {resp.status_code}. Forçando renovação do token...")
                global _spotify_token_cache
                _spotify_token_cache = None
        except Exception as e:
            print(f"[Backend] Erro na busca do Spotify (tentativa {attempt + 1}): {e}")

    # ── Fallback Gracioso: Busca via YouTube convertida para o modelo de faixas do Spotify ──
    print(f"[Backend] Spotify API indisponível/rate-limited. Executando busca online via YouTube fallback para '{q}'...")
    try:
        search_opts = {
            'extract_flat': True,
            'quiet': True,
            'no_warnings': True,
            'nocheckcertificate': True,
            'geo_bypass': True,
            **_get_base_opts(),
        }
        with yt_dlp.YoutubeDL(search_opts) as ydl:
            results = ydl.extract_info(f"ytsearch{limit}:{q.strip()}", download=False)
            
        entries = results.get("entries", []) if results else []
        spotify_items = []
        
        for entry in entries:
            if not entry: continue
            vid_id = entry.get("id") or ""
            raw_title = entry.get("title") or ""
            uploader = entry.get("uploader") or entry.get("channel") or ""
            duration = int((entry.get("duration") or 0) * 1000)
            
            # Limpa uploader
            clean_artist = re.sub(r'\s*-\s*Topic$', '', uploader, flags=re.IGNORECASE).strip()
            # Limpa sufixos de vídeo do título: (Official Video), (Lyric Video), etc.
            clean_title = re.sub(r'[\(\[][^\)\]]*(official|video|lyric|audio|hd|4k)[^\)\]]*[\)\]]', '', raw_title, flags=re.IGNORECASE).strip()
            
            track_name = clean_title
            artist_name = clean_artist or "Artista Desconhecido"
            
            if " - " in clean_title:
                parts = clean_title.split(" - ", 1)
                artist_name = parts[0].strip()
                track_name = parts[1].strip()
            
            thumbnails = entry.get("thumbnails") or []
            thumb_url = thumbnails[-1].get("url") if thumbnails else ""
            
            spotify_items.append({
                "id": f"yt_{vid_id}",
                "name": track_name,
                "artists": [{"name": artist_name}],
                "album": {"name": "Single", "images": [{"url": thumb_url}] if thumb_url else []},
                "duration_ms": duration,
            })
            
        return {"tracks": {"items": spotify_items}}
    except Exception as e:
        print(f"[Backend] Erro no fallback de busca: {e}")
        return {"tracks": {"items": []}}

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 3004))
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=True)
