"""
downloader.py — Download de áudio via yt-dlp nativo no celular com fallback ultra-resiliente.
EDICAO MEGA-VERBOSE: Inclui logs detalhados de rede, exceções e rastreamento completo de erros.
Otimizado para celular: baixa fluxos AAC nativos (formato 140/.m4a) sem precisar do FFmpeg.

Estratégias anti-bloqueio integradas:
1. Descoberta dinâmica de instâncias Piped e Invidious ativas + Filtro rigoroso de domínios escuros (Tor/I2P/Yggdrasil).
2. Fase 1: Busca via Piped/Invidious (IP limpo) + Download direto via yt-dlp.
3. Fase 2: Busca e download diretos via yt-dlp com rotação de client.
4. Fase 3: Download proxy via Piped API (100% livre de bloqueios de IP locais).
"""

import os
import time
import unicodedata
import json
import urllib.request
import urllib.parse
import re
import traceback
from typing import Dict, Any, Optional

import yt_dlp

from config import AUDIO_FORMAT, AUDIO_BITRATE, MAX_RETRIES, RETRY_SLEEP, SOCKET_TIMEOUT


def _debug_log(message: str):
    """Escreve log no console do celular/Flutter."""
    print(f"[Python-Downloader] {message}")


class _VerboseLogger:
    """Encaminha TODOS os outputs do yt-dlp diretamente para o debug log do celular."""
    def debug(self, msg):
        _debug_log(f"[yt-dlp DBG] {msg}")
    def info(self, msg):
        _debug_log(f"[yt-dlp INF] {msg}")
    def warning(self, msg):
        _debug_log(f"[yt-dlp WRN] {msg}")
    def error(self, msg):
        _debug_log(f"[yt-dlp ERR] {msg}")


def _to_ascii(text: str) -> str:
    """Converte texto Unicode para ASCII aproximado."""
    normalized = unicodedata.normalize("NFKD", text)
    return normalized.encode("ascii", "ignore").decode("ascii").strip()


def _is_unavailable_error(err: str) -> bool:
    err_lower = err.lower()
    return any(x in err_lower for x in [
        "not available", "private video", "video unavailable",
        "has been removed", "account has been terminated",
        "no video formats", "members-only",
    ])


def _is_no_results_error(err: str) -> bool:
    err_lower = err.lower()
    return any(x in err_lower for x in [
        "no results", "did not get any data", "no matching formats",
    ])


def _is_rate_limit_error(err: str) -> bool:
    err_lower = err.lower()
    return any(x in err_lower for x in [
        "429", "rate limit", "too many requests",
        "confirm you are not a robot", "sign in to confirm",
        "sign in to access", "precondition check failed",
    ])


def _clean_query(text: str) -> str:
    """Remove termos comuns que atrapalham a busca no YouTube."""
    text = re.sub(r'[\(\[][Ff]eat\..*?[\)\]]', '', text)
    text = re.sub(r'[\(\[][Rr]emastered.*?[\)\]]', '', text)
    text = re.sub(r'[\(\[][Ll]ive.*?[\)\]]', '', text)
    text = re.sub(r'[\(\[][Oo]fficial.*?[\)\]]', '', text)
    text = re.sub(r'[\(\[][Dd]eluxe.*?[\)\]]', '', text)
    return text.strip()


# Player clients do YouTube para rotação no yt-dlp
_PLAYER_CLIENTS = [
    "android_music",
    "ios",
    "mweb",
    "web",
]


# Cache de saúde de instâncias Piped/Invidious: {url: (is_healthy, timestamp)}
_instance_health_cache = {}


def _quick_health_check(url: str, proxy: str = None) -> bool:
    """Verifica rapidamente se uma instância está ativa e saudável, usando cache de 5 min."""
    now = time.time()
    if url in _instance_health_cache:
        is_healthy, timestamp = _instance_health_cache[url]
        if now - timestamp < 300:  # Cache de 5 minutos
            _debug_log(f"[Health Cache] Instancia {url} - Usando resultado em cache: {is_healthy}")
            return is_healthy

    _debug_log(f"[Health Check] Verificando saude de {url}...")
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
        )
        if proxy:
            proxy_handler = urllib.request.ProxyHandler({"https": proxy, "http": proxy})
            opener = urllib.request.build_opener(proxy_handler)
            with opener.open(req, timeout=3) as resp:
                code = resp.getcode()
        else:
            with urllib.request.urlopen(req, timeout=3) as resp:
                code = resp.getcode()
        is_healthy = (code == 200)
    except Exception as e:
        code = getattr(e, "code", None)
        if code in [200, 301, 302, 404, 403]:
            is_healthy = True
            _debug_log(f"[Health Check] Resposta HTTP em {url}: {code} (considerado saudavel)")
        else:
            _debug_log(f"[Health Check] Falha ao conectar em {url}: {e}")
            is_healthy = False

    _instance_health_cache[url] = (is_healthy, now)
    return is_healthy


def _is_cookie_file_expired(cookie_file: str) -> bool:
    """
    Verifica se os cookies do YouTube no arquivo Netscape estão expirados.
    Retorna True se os cookies essenciais estiverem expirados ou ausentes.
    """
    if not cookie_file or not os.path.exists(cookie_file):
        return True
    try:
        now = time.time()
        essential_cookies = {}
        
        with open(cookie_file, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split('\t')
                if len(parts) >= 7:
                    name = parts[5]
                    expiry_str = parts[4]
                    if name in ['__Secure-3PSIDTS', 'SID', '__Secure-1PSIDTS']:
                        try:
                            essential_cookies[name] = int(expiry_str)
                        except ValueError:
                            essential_cookies[name] = 0
                            
        if not essential_cookies:
            return True
            
        for name, expiry in essential_cookies.items():
            if expiry > 0 and expiry < now:
                _debug_log(f"[Cookies Expiry] Cookie critico '{name}' EXPIRADO em {expiry} (agora: {int(now)})")
                return True
                
        return False
    except Exception as e:
        _debug_log(f"[Cookies Expiry] Erro ao checar expiracao de cookies: {e}")
        return False



# ── Rastreamento de Parâmetros de Entrada ─────────────────────────────────────

def _log_cookie_info(cookie_file: str):
    if not cookie_file:
        _debug_log("[Cookies] Nenhum arquivo de cookies foi passado nas configurações.")
        return
    if not os.path.exists(cookie_file):
        _debug_log(f"[Cookies] ARQUIVO NAO ENCONTRADO no caminho: {cookie_file}")
        return
    try:
        sz = os.path.getsize(cookie_file)
        _debug_log(f"[Cookies] Arquivo de cookies carregado: {cookie_file} ({sz} bytes)")
        with open(cookie_file, 'r', encoding='utf-8', errors='ignore') as f:
            first_lines = [f.readline() for _ in range(7)]
        _debug_log("[Cookies] Primeiras 7 linhas do arquivo de cookies:\n" + "".join(first_lines))
    except Exception as e:
        _debug_log(f"[Cookies] Erro ao analisar/ler arquivo de cookies: {e}")


def _log_proxy_info(proxy: str):
    if not proxy:
        _debug_log("[Proxy] Conexão Direta (Sem proxy configurado nas configurações).")
        return
    _debug_log(f"[Proxy] Usando Proxy/VPN local: {proxy}")


# ── Descoberta Dinâmica de Servidores Proxy ──────────────────────────────────

def _get_dynamic_invidious_instances() -> list:
    """Busca a lista de instâncias Invidious ativas e saudáveis do site oficial."""
    _debug_log("Descobrindo instâncias Invidious dinâmicas...")
    
    # Fallback robusto de domínios clearweb conhecidos
    fallback_list = [
        "https://iv.melmac.space",
        "https://inv.thepixora.com",
        "https://yt.chocolatemoo53.com",
    ]
    
    try:
        req = urllib.request.Request(
            "https://api.invidious.io/instances.json",
            headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            dynamic_list = []
            for item in data:
                try:
                    name, info = item[0], item[1]
                    if info.get("type") == "https" and info.get("uri"):
                        uri = info["uri"].rstrip("/").lower()
                        # FILTRAR RIGOROSO: Evitar domínios Tor (.onion), I2P (.i2p) ou Yggdrasil (.ygg / ygg)
                        # Emuladores/celulares comuns não conseguem resolver esses domínios de DNS alternativos
                        if any(x in uri for x in [".onion", ".i2p", ".ygg", "ygg"]):
                            continue
                        monitor = info.get("monitor")
                        if monitor and isinstance(monitor, dict):
                            if monitor.get("status") != "up":
                                continue
                        dynamic_list.append(info["uri"].rstrip("/"))
                except Exception:
                    continue
            
            # Une a lista dinâmica com a estática para garantir variedade e redundância
            combined = []
            for uri in dynamic_list:
                if uri not in combined:
                    combined.append(uri)
            for uri in fallback_list:
                if uri not in combined:
                    combined.append(uri)
                    
            if combined:
                _debug_log(f"Dynamic Invidious: Sucesso! Encontradas {len(combined)} instâncias clearweb: {combined[:6]}...")
                return combined
    except Exception as e:
        _debug_log(f"Dynamic Invidious: Falha ao obter da API: {e}. Usando fallback fixo.")
    
    return fallback_list


def _get_dynamic_piped_instances() -> list:
    """Busca a lista de instâncias Piped ativas e saudáveis do monitor oficial."""
    _debug_log("Descobrindo instâncias Piped dinâmicas...")
    
    fallback_list = [
        "https://api.piped.private.coffee",
    ]
    
    try:
        req = urllib.request.Request(
            "https://piped-instances.kavin.rocks/",
            headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            dynamic_list = []
            for item in data:
                try:
                    api_url = item.get("api_url")
                    if api_url:
                        uri = api_url.rstrip("/").lower()
                        # Filtro de redes escuras
                        if any(x in uri for x in [".onion", ".i2p", ".ygg", "ygg"]):
                            continue
                        uptime = item.get("uptime_24h", 0)
                        if uptime is None or uptime > 80:
                            dynamic_list.append(api_url.rstrip("/"))
                except Exception:
                    continue
            
            combined = []
            for uri in dynamic_list:
                if uri not in combined:
                    combined.append(uri)
            for uri in fallback_list:
                if uri not in combined:
                    combined.append(uri)
                    
            if combined:
                _debug_log(f"Dynamic Piped: Sucesso! Encontradas {len(combined)} instâncias clearweb: {combined[:6]}...")
                return combined
    except Exception as e:
        _debug_log(f"Dynamic Piped: Falha ao obter da API: {e}. Usando fallback fixo.")
    
    return fallback_list


# ── Configurações do yt-dlp ──────────────────────────────────────────────────

def _make_ydl_opts(
    output_dir: str,
    tmp_filename: str,
    cookie_file: str = None,
    player_client: str = "ios",
    proxy: str = None,
) -> dict:
    """Retorna opções base do yt-dlp para download."""
    extractor_args = {
        "youtube": {
            "player_client": [player_client],
            "skip": ["translated_subs"],
        }
    }
    opts = {
        "format": "140/bestaudio[ext=m4a]/best[ext=m4a]/bestaudio/best",
        "outtmpl": os.path.join(output_dir, f"{tmp_filename}.%(ext)s"),
        "quiet": False,
        "no_warnings": False,
        "logger": _VerboseLogger(),
        "socket_timeout": 20,
        "retries": 2,
        "fragment_retries": 2,
        "nooverwrites": True,
        "writethumbnail": False,
        "nocheckcertificate": True,
        "geo_bypass": True,
        "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "ignoreerrors": False,
        "extractor_args": extractor_args,
    }
    if cookie_file and os.path.exists(cookie_file):
        opts["cookiefile"] = cookie_file
    if proxy:
        opts["proxy"] = proxy
    return opts


def _make_search_opts(
    cookie_file: str = None,
    player_client: str = "ios",
    proxy: str = None,
) -> dict:
    """Retorna opções do yt-dlp para busca de metadados (sem download)."""
    extractor_args = {
        "youtube": {
            "player_client": [player_client],
            "skip": ["translated_subs"],
        }
    }
    opts = {
        "quiet": False,
        "no_warnings": False,
        "logger": _VerboseLogger(),
        "skip_download": True,
        "socket_timeout": 15,
        "nocheckcertificate": True,
        "geo_bypass": True,
        "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "ignoreerrors": True,
        "extractor_args": extractor_args,
    }
    if cookie_file and os.path.exists(cookie_file):
        opts["cookiefile"] = cookie_file
    if proxy:
        opts["proxy"] = proxy
    return opts


# ── Buscas em APIs Alternativas (Piped & Invidious) ──────────────────────────

def _piped_search(
    query: str,
    instance: str,
    duration_ms: int = 0,
    proxy: str = None,
) -> Optional[str]:
    """Busca no Piped API e retorna o URL do YouTube do melhor resultado."""
    try:
        encoded = urllib.parse.quote(query)
        api_url = f"{instance}/search?q={encoded}&filter=videos"
        _debug_log(f"[Piped Search] Fazendo requisição para: {api_url}")
        
        req = urllib.request.Request(
            api_url,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Accept": "application/json",
            }
        )
        
        if proxy:
            proxy_handler = urllib.request.ProxyHandler({"https": proxy, "http": proxy})
            opener = urllib.request.build_opener(proxy_handler)
            with opener.open(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        else:
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                
        results = data.get("items", [])
        _debug_log(f"[Piped Search] Sucesso! {instance} retornou {len(results)} resultados.")
        
        if not results or not isinstance(results, list):
            return None
            
        valid_results = []
        for r in results:
            if not isinstance(r, dict):
                continue
            url = r.get("url", "")
            if "watch?v=" in url:
                video_id = url.split("watch?v=")[1].split("&")[0]
                valid_results.append({
                    "videoId": video_id,
                    "duration": r.get("duration", 0),
                    "title": r.get("title", "")
                })
                
        if not valid_results:
            _debug_log(f"[Piped Search] Nenhum vídeo com formato watch?v= foi retornado.")
            return None
            
        if duration_ms > 0:
            duration_s = duration_ms / 1000.0
            best = min(valid_results, key=lambda r: abs(r.get("duration", 0) - duration_s))
            _debug_log(f"[Piped Search] Selecionou por duração mais próxima ({duration_s}s vs {best.get('duration')}s): {best.get('title')}")
        else:
            best = valid_results[0]
            _debug_log(f"[Piped Search] Selecionou primeiro resultado: {best.get('title')}")
            
        video_id = best["videoId"]
        return f"https://www.youtube.com/watch?v={video_id}"
        
    except Exception as e:
        _debug_log(f"[Piped Search Erro] Instância {instance} falhou. Mensagem: {e}")
        return None


def _invidious_search(
    query: str,
    instance: str,
    duration_ms: int = 0,
    proxy: str = None,
) -> Optional[str]:
    """Busca no Invidious API e retorna o URL do YouTube do melhor resultado."""
    try:
        encoded = urllib.parse.quote(query)
        api_url = f"{instance}/api/v1/search?q={encoded}&type=video&fields=videoId,lengthSeconds,title"
        _debug_log(f"[Invidious Search] Fazendo requisição para: {api_url}")

        req = urllib.request.Request(
            api_url,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Accept": "application/json",
            }
        )

        if proxy:
            proxy_handler = urllib.request.ProxyHandler({"https": proxy, "http": proxy})
            opener = urllib.request.build_opener(proxy_handler)
            with opener.open(req, timeout=5) as resp:
                results = json.loads(resp.read().decode("utf-8"))
        else:
            with urllib.request.urlopen(req, timeout=5) as resp:
                results = json.loads(resp.read().decode("utf-8"))

        _debug_log(f"[Invidious Search] Sucesso! {instance} retornou {len(results) if isinstance(results, list) else 0} resultados.")

        if not results or not isinstance(results, list):
            return None

        results = [r for r in results if isinstance(r, dict) and r.get("videoId")]
        if not results:
            return None

        if duration_ms > 0:
            duration_s = duration_ms / 1000.0
            best = min(results, key=lambda r: abs(r.get("lengthSeconds", 0) - duration_s))
            _debug_log(f"[Invidious Search] Match por duração ({duration_s}s vs {best.get('lengthSeconds')}s): {best.get('title')}")
        else:
            best = results[0]
            _debug_log(f"[Invidious Search] Seleção primária: {best.get('title')}")

        video_id = best["videoId"]
        return f"https://www.youtube.com/watch?v={video_id}"

    except Exception as e:
        _debug_log(f"[Invidious Search Erro] Instância {instance} falhou. Mensagem: {e}")
        return None


# ── Downloads Resilientes (Direto e Proxies) ─────────────────────────────────

def _yt_download_url(
    url: str,
    output_dir: str,
    tmp_filename: str,
    cookie_file: str = None,
    player_client: str = "ios",
    proxy: str = None,
) -> bool:
    """Download direto de URL do YouTube usando yt-dlp."""
    expected_file = os.path.join(output_dir, f"{tmp_filename}.{AUDIO_FORMAT}")
    if os.path.exists(expected_file):
        try:
            os.remove(expected_file)
        except Exception as ex:
            _debug_log(f"[Cleanup] Falha ao deletar arquivo temporário antigo: {ex}")

    _debug_log(f"[yt-dlp Direct] Executando download da URL {url} com client={player_client}...")
    opts = _make_ydl_opts(output_dir, tmp_filename, cookie_file, player_client, proxy)
    
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.download([url])
            
        success = os.path.exists(expected_file) and os.path.getsize(expected_file) > 1024
        if success:
            _debug_log(f"[yt-dlp Direct] Sucesso! Arquivo extraído com {os.path.getsize(expected_file)} bytes.")
        else:
            _debug_log(f"[yt-dlp Direct] Arquivo não gerado ou com tamanho muito pequeno (< 1KB).")
        return success
    except Exception as e:
        _debug_log(f"[yt-dlp Direct Erro] Falha crítica no client={player_client}: {e}")
        _debug_log(traceback.format_exc())
        if _is_rate_limit_error(str(e)):
            raise
        return False


def _piped_proxied_download(
    video_url: str,
    instance: str,
    output_dir: str,
    tmp_filename: str,
    proxy: str = None,
) -> bool:
    """
    Obtém o fluxo de áudio proxied do Piped (passa pelo IP do servidor deles)
    e faz download HTTP direto para o arquivo final. Totalmente imune a blocos locais.
    """
    try:
        if "v=" in video_url:
            video_id = video_url.split("v=")[1].split("&")[0]
        else:
            return False

        _debug_log(f"[Piped Proxy] Chamando API de streams do Piped para {video_id} via {instance}...")
        api_url = f"{instance}/streams/{video_id}"
        
        req = urllib.request.Request(
            api_url,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Accept": "application/json",
            }
        )
        
        if proxy:
            proxy_handler = urllib.request.ProxyHandler({"https": proxy, "http": proxy})
            opener = urllib.request.build_opener(proxy_handler)
            with opener.open(req, timeout=8) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        else:
            with urllib.request.urlopen(req, timeout=8) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                
        audio_streams = data.get("audioStreams", [])
        _debug_log(f"[Piped Proxy] Streams de áudio extraídos: {len(audio_streams)}")
        
        if not audio_streams:
            _debug_log(f"[Piped Proxy] A resposta do servidor Piped {instance} não continha fluxos de áudio.")
            return False
            
        m4a_streams = [s for s in audio_streams if s.get("format") == "M4A"]
        best_stream = None
        if m4a_streams:
            for s in m4a_streams:
                codec = s.get("codec", "")
                if "mp4a.40.2" in codec or "128" in s.get("quality", ""):
                    best_stream = s
                    break
            if not best_stream:
                best_stream = m4a_streams[0]
        else:
            best_stream = audio_streams[0]
            
        stream_url = best_stream.get("url")
        if not stream_url:
            _debug_log("[Piped Proxy] Erro: URL do fluxo de stream de áudio está vazia.")
            return False
            
        _debug_log(f"[Piped Proxy] URL de stream resolvida: {stream_url[:120]}...")
        expected_file = os.path.join(output_dir, f"{tmp_filename}.{AUDIO_FORMAT}")
        if os.path.exists(expected_file):
            try:
                os.remove(expected_file)
            except:
                pass
                
        _debug_log(f"[Piped Proxy] Fazendo download direto do áudio em partes (HTTP chunked)...")
        req_stream = urllib.request.Request(
            stream_url,
            headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
        )
        
        if proxy:
            proxy_handler = urllib.request.ProxyHandler({"https": proxy, "http": proxy})
            opener = urllib.request.build_opener(proxy_handler)
            response = opener.open(req_stream, timeout=30)
        else:
            response = urllib.request.urlopen(req_stream, timeout=30)
            
        bytes_written = 0
        t0 = time.time()
        with response as resp, open(expected_file, "wb") as f:
            content_len = resp.info().get('Content-Length', 'desconhecido')
            _debug_log(f"[Piped Proxy] Baixando... Content-Length: {content_len}")
            while True:
                chunk = resp.read(1024 * 128)  # 128KB chunks
                if not chunk:
                    break
                f.write(chunk)
                bytes_written += len(chunk)
                
        duration = time.time() - t0
        _debug_log(f"[Piped Proxy] Sucesso! Baixou {bytes_written} bytes em {duration:.1f}s.")
        
        if os.path.exists(expected_file) and os.path.getsize(expected_file) > 1024:
            return True
            
        return False
        
    except Exception as e:
        _debug_log(f"[Piped Proxy Erro] Download via {instance} falhou. Mensagem: {e}")
        return False


def _invidious_download(
    video_url: str,
    instance: str,
    output_dir: str,
    tmp_filename: str,
    cookie_file: str = None,
    proxy: str = None,
) -> bool:
    """Faz download via yt-dlp apontando para a instância Invidious como proxy."""
    try:
        if "v=" in video_url:
            video_id = video_url.split("v=")[1].split("&")[0]
        else:
            return False

        inv_url = f"{instance}/watch?v={video_id}"
        _debug_log(f"[Invidious Proxy] Iniciando download de {inv_url} via yt-dlp...")

        expected_file = os.path.join(output_dir, f"{tmp_filename}.{AUDIO_FORMAT}")
        if os.path.exists(expected_file):
            try:
                os.remove(expected_file)
            except:
                pass

        opts = {
            "format": "bestaudio[ext=m4a]/bestaudio/best",
            "outtmpl": os.path.join(output_dir, f"{tmp_filename}.%(ext)s"),
            "quiet": False,
            "no_warnings": False,
            "logger": _VerboseLogger(),
            "socket_timeout": 30,
            "retries": 2,
            "nocheckcertificate": True,
            "ignoreerrors": False,
        }
        if cookie_file and os.path.exists(cookie_file):
            opts["cookiefile"] = cookie_file
        if proxy:
            opts["proxy"] = proxy

        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.download([inv_url])

        for ext in ["m4a", "webm", "opus", "mp4"]:
            f = os.path.join(output_dir, f"{tmp_filename}.{ext}")
            if os.path.exists(f) and os.path.getsize(f) > 1024:
                if ext != AUDIO_FORMAT:
                    dest = os.path.join(output_dir, f"{tmp_filename}.{AUDIO_FORMAT}")
                    os.rename(f, dest)
                _debug_log(f"[Invidious Proxy] Sucesso! Baixou arquivo formato {ext}.")
                return True

        return False

    except Exception as e:
        _debug_log(f"[Invidious Proxy Erro] Download falhou: {e}")
        return False


def _yt_search_entries(
    query: str,
    cookie_file: str = None,
    player_client: str = "ios",
    proxy: str = None,
) -> list:
    """Busca entradas no YouTube via yt-dlp (ytsearch)."""
    query = query.replace("ytmsearch", "ytsearch")
    _debug_log(f"[YT Search Direct] Pesquisando '{query}' com client={player_client}...")
    opts = _make_search_opts(cookie_file, player_client, proxy)
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(query, download=False)
            if not info:
                _debug_log("[YT Search Direct] Resposta da busca está vazia.")
                return []
            if "entries" in info:
                entries = [e for e in info["entries"] if e]
                _debug_log(f"[YT Search Direct] Sucesso! Encontrados {len(entries)} resultados.")
                return entries
            _debug_log("[YT Search Direct] Apenas um resultado simples extraído.")
            return [info]
    except Exception as e:
        _debug_log(f"[YT Search Direct Erro] Falha no client={player_client}: {e}")
        if _is_rate_limit_error(str(e)):
            raise
        return []


def _pick_best_by_duration(
    entries: list,
    spotify_duration_ms: int,
    max_diff: int = 60,
    skip_index: int = 0,
) -> Optional[str]:
    """Seleciona o vídeo com duração mais próxima à da faixa do Spotify."""
    if not entries:
        return None

    spotify_duration_s = spotify_duration_ms / 1000 if spotify_duration_ms else 0
    _debug_log(f"[Match Duração] Comparando resultados com duração alvo do Spotify: {spotify_duration_s}s...")
    valid = []

    for entry in entries:
        if not entry:
            continue
        yt_dur = entry.get("duration") or 0
        diff = abs(yt_dur - spotify_duration_s) if spotify_duration_s > 0 else 0
        url = entry.get("webpage_url") or entry.get("url")
        if url:
            valid.append((diff, url, entry.get("title"), yt_dur))

    if not valid:
        _debug_log("[Match Duração] Nenhuma entrada de áudio válida retornada.")
        return None

    valid.sort(key=lambda x: x[0])
    for idx, item in enumerate(valid[:5]):
        _debug_log(f"  #{idx+1}: '{item[2]}' ({item[3]}s) | Diferença: {item[0]:.1f}s | URL: {item[1]}")

    acceptable = [m for m in valid if m[0] <= max_diff]
    pool = acceptable if acceptable else valid
    best = pool[skip_index % len(pool)]
    _debug_log(f"[Match Duração] Match Selecionado: '{best[2]}' com diferença de {best[0]:.1f}s.")
    return best[1]


# ── Função Principal ─────────────────────────────────────────────────────────

def download_track(
    track_data: Dict[str, Any],
    output_dir: str,
    tmp_filename: str = "__tmp_track",
    retry_mode: bool = False,
    skip_index: int = 0,
    cookie_file: str = None,
    proxy: str = None,
) -> Optional[str]:
    """
    Função chamada via ponte Kotlin do Chaquopy.
    Retorna o caminho do arquivo .m4a baixado, ou None em caso de falha.
    """
    # Converte Java HashMap para Python dict nativo
    py_track = {}
    try:
        keys = list(track_data.keys()) if hasattr(track_data, "keys") else [
            "artist", "title", "album", "isrc", "duration_ms"
        ]
        for key in keys:
            val = track_data.get(key)
            if val is not None:
                py_track[str(key)] = val
    except Exception:
        for key in ["artist", "title", "album", "isrc", "duration_ms"]:
            try:
                val = track_data.get(key)
                if val is not None:
                    py_track[key] = val
            except Exception:
                pass
    track_data = py_track

    os.makedirs(output_dir, exist_ok=True)
    artist = track_data.get("artist", "")
    title = track_data.get("title", "")
    duration_ms = int(track_data.get("duration_ms", 0) or 0)
    expected_file = os.path.join(output_dir, f"{tmp_filename}.{AUDIO_FORMAT}")

    _debug_log("==============================================================")
    _debug_log(f"=== [EXECUÇÃO] INICIANDO DOWNLOAD: {artist} - {title} ===")
    _debug_log(f"=== Diretório de saída: {output_dir}")
    _debug_log(f"=== Arquivo temporário alvo: {expected_file}")
    _debug_log("==============================================================")
    
    if cookie_file and os.path.exists(cookie_file):
        if _is_cookie_file_expired(cookie_file):
            _debug_log("[Cookies Expiry] ATENCAO: Arquivo de cookies foi ignorado pois os cookies criticos estao expirados!")
            cookie_file = None

    _log_cookie_info(cookie_file)
    _log_proxy_info(proxy)

    if os.path.exists(expected_file):
        try:
            os.remove(expected_file)
            _debug_log("[Downloader] Limpeza efetuada! Arquivo temporário deletado.")
        except Exception as e:
            _debug_log(f"[Downloader] Falha ao efetuar limpeza do temporário: {e}")

    c_title = _clean_query(title)
    c_artist = _clean_query(artist)
    queries = [
        f"{c_artist} {c_title} official audio",
        f"{c_artist} {c_title}",
        f"{artist} {title}",
    ]
    _debug_log(f"[Downloader] Queries limpas preparadas: {queries}")

    # Descoberta dinâmica das instâncias no momento do download
    p_instances = _get_dynamic_piped_instances()
    i_instances = _get_dynamic_invidious_instances()

    # ── FASE 1: Busca via Piped/Invidious API + Download YouTube Direto ──────
    _debug_log("--------------------------------------------------------------")
    _debug_log("--- FASE 1: Busca via Piped/Invidious (IP de data center) ---")
    _debug_log("--------------------------------------------------------------")
    video_url = None

    # Tenta obter a URL do vídeo via Invidious API primeiro (3 working clearweb instances)
    _debug_log("[Fase 1] Iniciando busca via Invidious...")
    for idx, instance in enumerate(i_instances[:6]):
        if not _quick_health_check(instance, proxy):
            _debug_log(f"[Fase 1] Ignorando Invidious não saudável: {instance}")
            continue
        _debug_log(f"[Fase 1] Tentando Invidious #{idx+1}: {instance}")
        for q in queries[:2]:
            video_url = _invidious_search(q, instance, duration_ms, proxy)
            if video_url:
                _debug_log(f"[Fase 1] Sucesso na busca Invidious via {instance}")
                break
        if video_url:
            break

    # Fallback de busca para Piped se Invidious falhar
    if not video_url:
        _debug_log("[Fase 1] Invidious falhou em obter URL. Tentando Piped...")
        for idx, instance in enumerate(p_instances[:5]):
            if not _quick_health_check(instance, proxy):
                _debug_log(f"[Fase 1] Ignorando Piped não saudável: {instance}")
                continue
            _debug_log(f"[Fase 1] Tentando Piped #{idx+1}: {instance}")
            for q in queries[:2]:
                video_url = _piped_search(q, instance, duration_ms, proxy)
                if video_url:
                    _debug_log(f"[Fase 1] Sucesso na busca Piped via {instance}")
                    break
            if video_url:
                break

    # Se encontramos o vídeo na busca via API (Invidious/Piped), tenta baixar usando Proxy de áudio
    if video_url:
        _debug_log(f"[Fase 1] URL localizada com sucesso: {video_url}. Tentando Piped/Invidious Proxy (sem necessidade de JS local)...")
        # 1. Piped Proxy (HTTP chunked download direto do servidor de streams do Piped)
        for idx, instance in enumerate(p_instances[:5]):
            if not _quick_health_check(instance, proxy):
                continue
            _debug_log(f"[Fase 1] Baixando áudio proxied via Piped #{idx+1}: {instance}...")
            if _piped_proxied_download(video_url, instance, output_dir, tmp_filename, proxy):
                _debug_log(f"=== [Fase 1 SUCESSO] Download proxied via Piped {instance}! ===")
                return expected_file

        # 2. Invidious Proxy (Baixa através do player do Invidious usando yt-dlp sem criptografia)
        for idx, instance in enumerate(i_instances[:4]):
            if not _quick_health_check(instance, proxy):
                continue
            _debug_log(f"[Fase 1] Baixando áudio proxied via Invidious #{idx+1}: {instance}...")
            if _invidious_download(video_url, instance, output_dir, tmp_filename, cookie_file, proxy):
                _debug_log(f"=== [Fase 1 SUCESSO] Download proxied via Invidious {instance}! ===")
                return expected_file

        # 3. Fallback de último caso: Direct yt-dlp (provavelmente falhará no emulador sem JS engine)
        _debug_log("[Fase 1] Proxies falharam. Tentando direct yt-dlp de fallback...")
        for pc in _PLAYER_CLIENTS:
            _debug_log(f"[Fase 1] Executando direct yt-dlp com client={pc}...")
            try:
                if _yt_download_url(video_url, output_dir, tmp_filename, cookie_file, pc, proxy):
                    _debug_log(f"=== [Fase 1 SUCESSO] Download direto bem-sucedido com client={pc}! ===")
                    return expected_file
            except Exception as e:
                if _is_rate_limit_error(str(e)):
                    _debug_log(f"[Fase 1 Rate Limit] YouTube retornou rate-limit no client {pc}. Pulando client...")
                    time.sleep(1)
                continue
    else:
        _debug_log("[Fase 1] Nenhuma URL de vídeo pôde ser resolvida pelas buscas de API.")

    # ── FASE 2: Busca e Download no YouTube usando busca direta e download proxied ──
    _debug_log("--------------------------------------------------------------")
    _debug_log("--- FASE 2: Busca Direta e Download via Piped/Invidious Proxy ---")
    _debug_log("--------------------------------------------------------------")
    yt_queries_normal = [
        f"ytsearch1:{c_artist} - {c_title} official audio",
        f"ytsearch1:{artist} - {title}",
    ]
    isrc = track_data.get("isrc", "")
    if isrc:
        yt_queries_normal.insert(0, f"ytsearch1:{isrc}")

    yt_queries_retry = [
        f"ytsearch5:{c_artist} {c_title}",
        f"ytsearch5:{c_title} lyrics",
    ]

    all_yt_queries = yt_queries_retry if retry_mode else yt_queries_normal
    all_yt_queries += yt_queries_retry if not retry_mode else yt_queries_normal
    all_yt_queries.append(f"ytsearch1:{c_artist} {c_title}")
    
    _debug_log(f"[Fase 2] Lista completa de buscas ytsearch: {all_yt_queries[:4]}...")

    for pc in _PLAYER_CLIENTS:
        _debug_log(f"[Fase 2] Testando extração e busca com client={pc}...")
        for query in all_yt_queries[:3]:
            try:
                # Resolve a URL do vídeo primeiro usando busca simples de metadados
                # (Isso é imune a falhas de assinatura porque download=False e não puxamos streams de mídia cifrados)
                entries = _yt_search_entries(query, cookie_file, pc, proxy)
                if not entries:
                    continue
                url = _pick_best_by_duration(entries, duration_ms, skip_index=skip_index)
                if not url:
                    continue
                    
                # Tentamos baixar usando Piped/Invidious Proxies para evitar signature solving
                _debug_log(f"[Fase 2] URL resolvida: {url}. Tentando download proxied...")
                for instance in p_instances[:3]:
                    if not _quick_health_check(instance, proxy):
                        continue
                    _debug_log(f"[Fase 2] Baixando proxied via Piped: {instance}...")
                    if _piped_proxied_download(url, instance, output_dir, tmp_filename, proxy):
                        _debug_log(f"=== [Fase 2 SUCESSO] Download proxied via Piped {instance}! ===")
                        return expected_file
                        
                for instance in i_instances[:3]:
                    if not _quick_health_check(instance, proxy):
                        continue
                    _debug_log(f"[Fase 2] Baixando proxied via Invidious: {instance}...")
                    if _invidious_download(url, instance, output_dir, tmp_filename, cookie_file, proxy):
                        _debug_log(f"=== [Fase 2 SUCESSO] Download proxied via Invidious {instance}! ===")
                        return expected_file

                # Último recurso: direct yt-dlp
                _debug_log(f"[Fase 2] Proxies falharam para {url}. Tentando direct yt-dlp...")
                if _yt_download_url(url, output_dir, tmp_filename, cookie_file, pc, proxy):
                    _debug_log(f"=== [Fase 2 SUCESSO] Download direto bem-sucedido com client={pc}! ===")
                    return expected_file
            except Exception as e:
                err = str(e)
                if _is_rate_limit_error(err):
                    _debug_log(f"[Fase 2 Rate Limit] client={pc} retornou rate limit. Pulando client...")
                    break
                if _is_unavailable_error(err) or _is_no_results_error(err):
                    continue
                _debug_log(f"[Fase 2 Erro] Ocorreu erro não-fatal na query '{query}': {err[:120]}")

    # ── FASE 3: Proxied Download de emergência com novas buscas em Piped ──────
    _debug_log("--------------------------------------------------------------")
    _debug_log("--- FASE 3: Busca e Download Proxied de Emergência via API  ---")
    _debug_log("--------------------------------------------------------------")
    if not video_url:
        _debug_log("[Fase 3] Nenhuma URL de vídeo resolvida nas fases anteriores. Buscando URL...")
        for instance in p_instances[:3]:
            if not _quick_health_check(instance, proxy):
                continue
            for q in queries[:2]:
                video_url = _piped_search(q, instance, duration_ms, proxy)
                if video_url: break
            if video_url: break

    if video_url:
        _debug_log(f"[Fase 3] URL resolvida: {video_url}. Tentando download proxied...")
        
        # Piped Proxy
        for idx, instance in enumerate(p_instances[:6]):
            if not _quick_health_check(instance, proxy):
                continue
            _debug_log(f"[Fase 3] Baixando áudio proxied via Piped #{idx+1}: {instance}...")
            if _piped_proxied_download(video_url, instance, output_dir, tmp_filename, proxy):
                _debug_log(f"=== [Fase 3 SUCESSO] Download proxied via Piped {instance}! ===")
                return expected_file

        # Fallback Invidious Proxy
        for idx, instance in enumerate(i_instances[:4]):
            if not _quick_health_check(instance, proxy):
                continue
            _debug_log(f"[Fase 3] Baixando áudio proxied via Invidious #{idx+1}: {instance}...")
            if _invidious_download(video_url, instance, output_dir, tmp_filename, cookie_file, proxy):
                _debug_log(f"=== [Fase 3 SUCESSO] Download proxied via Invidious {instance}! ===")
                return expected_file
    else:
        _debug_log("[Fase 3] Erro: Não foi possível obter URL do vídeo mesmo para o download proxied.")

    _debug_log("==============================================================")
    _debug_log(f"=== [FALHA CRÍTICA] TODOS OS RECURSOS E FASES FALHARAM! ===")
    _debug_log(f"=== Música que falhou: {artist} - {title}")
    _debug_log("==============================================================")
    return None
