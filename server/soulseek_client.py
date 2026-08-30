"""
Soulseek download client for LA Player.

Uses slskd's REST API (via slskd-api library or raw requests) to search and
download music from the Soulseek P2P network as a fallback when YouTube is
rate-limited or unavailable.

The slskd instance must be running (Docker) and accessible at SLSKD_HOST.
"""

import os
import re
import time
import shutil
import threading
import requests
from typing import Optional, List, Dict, Tuple

# ── Configuration ────────────────────────────────────────────────────────────
SLSKD_HOST = os.getenv("SLSKD_HOST", "http://127.0.0.1:5030")
SLSKD_API_KEY = os.getenv("SLSKD_API_KEY") or os.getenv("SLSKD_KEY") or "laplayer-slskd-api-key-2026"
SLSKD_URL_BASE = "/api/v0"

# Audio extensions ranked by quality preference (higher index = better)
_AUDIO_QUALITY_RANK = {
    ".flac": 100,
    ".wav":  90,
    ".alac": 85,
    ".m4a":  70,
    ".aac":  65,
    ".ogg":  60,
    ".opus": 60,
    ".mp3":  50,
    ".wma":  20,
}

# Minimum acceptable audio file extensions
_VALID_AUDIO_EXTS = set(_AUDIO_QUALITY_RANK.keys())


class SoulseekDownloader:
    """Manages search and download operations against a local slskd instance."""

    def __init__(self, host: str = None, api_key: str = None):
        h = host or os.getenv("SLSKD_HOST", "http://127.0.0.1:5030")
        self.host = h.rstrip("/")
        self.api_key = api_key or os.getenv("SLSKD_API_KEY") or os.getenv("SLSKD_KEY") or "laplayer-slskd-api-key-2026"
        self.base = f"{self.host}{SLSKD_URL_BASE}"
        self._session = requests.Session()
        self._lock = threading.Lock()

    def _headers(self) -> dict:
        key = self.api_key or os.getenv("SLSKD_API_KEY") or os.getenv("SLSKD_KEY") or "laplayer-slskd-api-key-2026"
        return {
            "X-API-Key": key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    # ── Health ─────────────────────────────────────────────────────────────
    def is_available(self) -> bool:
        """Check whether the slskd instance is reachable and authenticated."""
        try:
            r = self._session.get(f"{self.base}/application", headers=self._headers(), timeout=3)
            if r.status_code == 200:
                data = r.json()
                srv = data.get("server", {})
                if srv.get("isLoggedIn"):
                    return True
                # Se estiver em processo de login, aguarda até 5s
                if srv.get("isConnected") or srv.get("isLoggingIn"):
                    for _ in range(10):
                        time.sleep(0.5)
                        try:
                            r2 = self._session.get(f"{self.base}/application", headers=self._headers(), timeout=1.5)
                            if r2.status_code == 200 and r2.json().get("server", {}).get("isLoggedIn"):
                                return True
                        except Exception:
                            pass
                return True
        except Exception:
            pass

        # Se não estiver rodando na porta 5030, tenta auto-iniciar slskd local se o binário existir
        slskd_bin = os.path.join(os.path.dirname(os.path.abspath(__file__)), "slskd-bin")
        if os.path.isdir(slskd_bin):
            try:
                print("[Soulseek] Daemon slskd não detectado na porta 5030 — iniciando automaticamente...")
                import subprocess
                subprocess.Popen(
                    ["./slskd", "--app-dir", "./data"],
                    cwd=slskd_bin,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                for _ in range(16):  # Poll por até 8s para subir e fazer login
                    time.sleep(0.5)
                    try:
                        r = self._session.get(f"{self.base}/application", headers=self._headers(), timeout=1.5)
                        if r.status_code == 200:
                            data = r.json()
                            srv = data.get("server", {})
                            if srv.get("isLoggedIn"):
                                print("[Soulseek] ✅ Daemon slskd iniciado e logado com sucesso na porta 5030!")
                                return True
                    except Exception:
                        pass
            except Exception as e:
                print(f"[Soulseek] Erro ao auto-iniciar slskd: {e}")

        return False

    # ── Search ─────────────────────────────────────────────────────────────
    def search(
        self,
        artist: str,
        title: str,
        timeout: int = 30,
        max_results: int = 50,
    ) -> Optional[Dict]:
        """
        Search Soulseek for a track matching *artist* and *title*.

        Returns the best matching file entry as a dict with keys:
            username, filename, size, bitRate, sampleRate, bitDepth, extension
        or None if nothing suitable is found within *timeout* seconds.
        """
        # Clean up search query for Soulseek
        clean_artist = re.sub(r'[\,\.\-_]', ' ', artist).strip()
        clean_title = re.sub(r'[\,\.\-_]', ' ', title).strip()
        query = f"{clean_artist} {clean_title}".strip()
        query = re.sub(r'\s+', ' ', query)
        if not query:
            return None

        print(f"[Soulseek] Buscando: '{query}' (timeout={timeout}s)")

        # 1. Create search
        try:
            r = self._session.post(
                f"{self.base}/searches",
                json={"searchText": query},
                headers=self._headers(),
                timeout=10,
            )
            if r.status_code == 409:
                # Daemon em processo de login — aguarda 3s e tenta criar a busca novamente
                print("[Soulseek] Daemon efetuando login na rede Soulseek, aguardando 3s...")
                time.sleep(3)
                r = self._session.post(
                    f"{self.base}/searches",
                    json={"searchText": query},
                    headers=self._headers(),
                    timeout=10,
                )
            if r.status_code not in (200, 201):
                print(f"[Soulseek] Erro ao criar busca: HTTP {r.status_code} — {r.text[:200]}")
                return None
            search_data = r.json()
            search_id = search_data.get("id")
            if not search_id:
                print("[Soulseek] Resposta de busca sem 'id'")
                return None
        except Exception as e:
            print(f"[Soulseek] Exceção ao criar busca: {e}")
            return None

        # 2. Poll until completed or timeout (allow at least 5s for responses to arrive)
        start_time = time.time()
        deadline = start_time + timeout
        while time.time() < deadline:
            try:
                r = self._session.get(f"{self.base}/searches/{search_id}", headers=self._headers(), timeout=5)
                if r.status_code == 200:
                    data = r.json()
                    state = str(data.get("state", ""))
                    response_count = data.get("responseCount", 0)
                    elapsed = time.time() - start_time
                    
                    if "Completed" in state or "completed" in state.lower():
                        break
                    # Wait at least 4 seconds and 10+ peer responses for best candidate selection
                    if elapsed >= 4 and response_count >= 15:
                        break
            except Exception:
                pass
            time.sleep(1.5)

        # 3. Fetch responses
        try:
            r = self._session.get(
                f"{self.base}/searches/{search_id}/responses",
                headers=self._headers(),
                timeout=10,
            )
            if r.status_code != 200:
                print(f"[Soulseek] Erro ao buscar respostas: HTTP {r.status_code}")
                self._delete_search(search_id)
                return None
            responses = r.json()
        except Exception as e:
            print(f"[Soulseek] Exceção ao buscar respostas: {e}")
            self._delete_search(search_id)
            return None

        # 4. Rank and pick best files
        candidates = self._rank_results(responses, artist, title)

        # 5. Clean up search
        self._delete_search(search_id)

        if candidates:
            best = candidates[0]
            print(f"[Soulseek] Encontrados {len(candidates)} candidatos. Melhor: {best['username']} — {best['filename']} "
                  f"({best.get('bitRate', '?')}kbps, {best.get('size', 0) / 1024 / 1024:.1f}MB)")
        else:
            print(f"[Soulseek] Nenhum resultado válido para '{query}'")

        return candidates

    # ── Download ───────────────────────────────────────────────────────────
    def download(
        self,
        username: str,
        filename: str,
        size: int,
        target_path: str,
        timeout: int = 120,
    ) -> Optional[str]:
        """
        Enqueue a download from *username* for *filename* and wait for it to
        finish.  Copies the completed file to *target_path* and returns its
        final path, or None on failure.
        """
        print(f"[Soulseek] Baixando de '{username}': {filename}")

        # 1. Enqueue the transfer
        try:
            r = self._session.post(
                f"{self.base}/transfers/downloads/{username}",
                json=[{
                    "filename": filename,
                    "size": size,
                }],
                headers=self._headers(),
                timeout=10,
            )
            if r.status_code not in (200, 201, 204):
                print(f"[Soulseek] Erro ao enfileirar download: HTTP {r.status_code} — {r.text[:200]}")
                return None
        except Exception as e:
            print(f"[Soulseek] Exceção ao enfileirar download: {e}")
            return None

        # 2. Poll transfer status until done or timeout
        deadline = time.time() + timeout
        completed = False
        while time.time() < deadline:
            try:
                r = self._session.get(
                    f"{self.base}/transfers/downloads/{username}",
                    headers=self._headers(),
                    timeout=10,
                )
                if r.status_code == 200:
                    transfers = r.json()
                    for transfer in self._flatten_transfers(transfers):
                        tf_filename = transfer.get("filename", "")
                        tf_state = transfer.get("state", "").lower()
                        if tf_filename == filename or filename.endswith(tf_filename.split("\\")[-1]):
                            if "completed" in tf_state and "succeeded" in tf_state:
                                completed = True
                                break
                            elif "errored" in tf_state or "rejected" in tf_state or "cancelled" in tf_state:
                                print(f"[Soulseek] Transfer falhou: state={tf_state}")
                                return None
                    if completed:
                        break
            except Exception:
                pass
            time.sleep(2)

        if not completed:
            print(f"[Soulseek] Timeout aguardando download de '{filename}'")
            return None

        # 3. Find the downloaded file and copy to target
        downloaded_file = self._find_downloaded_file(username, filename)
        if not downloaded_file:
            print("[Soulseek] Arquivo baixado não encontrado no diretório de downloads")
            return None

        try:
            # Determine final extension
            ext = os.path.splitext(downloaded_file)[1].lower()
            if not ext:
                ext = ".mp3"

            final_path = target_path
            if not final_path.endswith(ext):
                # Replace target extension with the actual downloaded extension
                base_no_ext = os.path.splitext(target_path)[0]
                final_path = f"{base_no_ext}{ext}"

            shutil.copy2(downloaded_file, final_path)
            print(f"[Soulseek] Download concluído: {final_path} ({os.path.getsize(final_path) / 1024 / 1024:.1f}MB)")
            return final_path
        except Exception as e:
            print(f"[Soulseek] Erro ao copiar arquivo: {e}")
            return None

    # ── Convenience: search + download in one call ─────────────────────────
    def search_and_download(
        self,
        artist: str,
        title: str,
        target_path: str,
        search_timeout: int = 30,
        download_timeout: int = 120,
    ) -> Optional[str]:
        """
        Search for a track and download the best result.
        Returns the path to the downloaded file, or None.
        """
        if not self.is_available():
            print("[Soulseek] slskd não está disponível")
            return None

        candidates = self.search(artist, title, timeout=search_timeout)
        if not candidates:
            return None

        for idx, cand in enumerate(candidates):
            print(f"[Soulseek] Tentando candidato ({idx + 1}/{len(candidates)}): {cand['username']} — {cand['filename']}")
            res = self.download(
                username=cand["username"],
                filename=cand["filename"],
                size=cand.get("size", 0),
                target_path=target_path,
                timeout=download_timeout,
            )
            if res and os.path.exists(res):
                return res
            print(f"[Soulseek] ⚠ Candidato '{cand['username']}' falhou/timed out. Tentando próximo...")

        return None

    # ── Internal helpers ───────────────────────────────────────────────────
    def _delete_search(self, search_id: str):
        """Delete a search to clean up resources."""
        try:
            self._session.delete(f"{self.base}/searches/{search_id}", headers=self._headers(), timeout=5)
        except Exception:
            pass

    def _rank_results(
        self,
        responses: list,
        artist: str,
        title: str,
    ) -> Optional[Dict]:
        """
        Rank all files from all responses and return the single best match.

        Ranking criteria (in order of importance):
        1. Audio file type (must be a valid audio extension)
        2. Filename match quality (contains artist + title keywords)
        3. Audio quality (format rank + bitrate)
        4. User queue availability (free upload slots)
        """
        artist_lower = artist.lower().strip()
        title_lower = title.lower().strip()

        # Build keyword sets for matching
        artist_words = set(re.sub(r'[^\w\s]', '', artist_lower).split())
        title_words = set(re.sub(r'[^\w\s]', '', title_lower).split())
        # Remove very short words that cause false positives
        artist_words = {w for w in artist_words if len(w) > 1}
        title_words = {w for w in title_words if len(w) > 1}

        candidates: List[Tuple[int, Dict]] = []

        for response in responses:
            username = response.get("username", "")
            free_slots = response.get("freeUploadSlots", 0)
            files = response.get("files", [])

            for f in files:
                fname = f.get("filename", "")
                ext = os.path.splitext(fname)[1].lower()

                # Must be a recognized audio file
                if ext not in _VALID_AUDIO_EXTS:
                    continue

                size = f.get("size", 0)
                bit_rate = f.get("bitRate", 0) or 0
                sample_rate = f.get("sampleRate", 0) or 0
                bit_depth = f.get("bitDepth", 0) or 0

                # Skip suspiciously small files (< 500KB = probably not a real track)
                if size < 512 * 1024:
                    continue

                # ── Score calculation ──
                score = 0

                # 1. Filename keyword matching
                fname_lower = fname.lower().replace("\\", "/")
                fname_basename = fname_lower.split("/")[-1]
                fname_no_ext = os.path.splitext(fname_basename)[0]
                fname_clean = re.sub(r'[^\w\s]', ' ', fname_no_ext)
                fname_words = set(fname_clean.split())

                title_overlap = len(title_words & fname_words)
                artist_overlap = len(artist_words & fname_words)

                if title_words:
                    score += int((title_overlap / len(title_words)) * 200)
                if artist_words:
                    score += int((artist_overlap / len(artist_words)) * 100)

                # Penalty if no title words match at all
                if title_overlap == 0:
                    score -= 500

                # 2. Format quality
                score += _AUDIO_QUALITY_RANK.get(ext, 0)

                # 3. Bitrate bonus
                if bit_rate > 0:
                    if bit_rate >= 320:
                        score += 50
                    elif bit_rate >= 256:
                        score += 35
                    elif bit_rate >= 192:
                        score += 20
                    elif bit_rate >= 128:
                        score += 10
                    else:
                        score -= 10  # Low quality

                # 4. Free slots bonus
                if free_slots > 0:
                    score += 30

                # 5. Reasonable file size bonus (2-50MB for typical tracks)
                size_mb = size / (1024 * 1024)
                if 2 <= size_mb <= 50:
                    score += 15
                elif size_mb > 100:
                    score -= 50  # Probably not a single track

                candidates.append((score, {
                    "username": username,
                    "filename": fname,
                    "size": size,
                    "bitRate": bit_rate,
                    "sampleRate": sample_rate,
                    "bitDepth": bit_depth,
                    "extension": ext,
                    "score": score,
                }))

        if not candidates:
            return []

        # Sort by score descending
        candidates.sort(key=lambda x: x[0], reverse=True)

        # Return top candidates (up to 5)
        return [c[1] for c in candidates[:5]]

    def _flatten_transfers(self, data) -> list:
        """Flatten the transfers response which can be nested by directory."""
        results = []
        if isinstance(data, list):
            for item in data:
                if isinstance(item, dict):
                    if "files" in item:
                        # Directory-level grouping
                        results.extend(item.get("files", []))
                    elif "filename" in item:
                        results.append(item)
                    else:
                        # Recurse
                        for v in item.values():
                            if isinstance(v, (list, dict)):
                                results.extend(self._flatten_transfers(v))
        elif isinstance(data, dict):
            if "files" in data:
                results.extend(data.get("files", []))
            elif "filename" in data:
                results.append(data)
            for v in data.values():
                if isinstance(v, (list, dict)):
                    results.extend(self._flatten_transfers(v))
        return results

    def _find_downloaded_file(self, username: str, filename: str) -> Optional[str]:
        """
        Look for the downloaded file in the slskd downloads directory.
        slskd organizes downloads as: <downloads_dir>/<username>/<folder>/<file>
        """
        # The downloads directory is mapped as a Docker volume
        # We check the host-mapped path
        downloads_dir = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "slskd-downloads",
        )

        if not os.path.isdir(downloads_dir):
            return None

        # Extract just the filename from the Soulseek path
        target_name = filename.replace("\\", "/").split("/")[-1]

        # Walk the downloads directory looking for the file
        for root, dirs, files in os.walk(downloads_dir):
            for f in files:
                if f == target_name:
                    full_path = os.path.join(root, f)
                    # Verify file has content
                    if os.path.getsize(full_path) > 1024:
                        return full_path

        return None


# ── Module-level singleton ────────────────────────────────────────────────
_default_client: Optional[SoulseekDownloader] = None
_init_lock = threading.Lock()


def get_soulseek_client() -> SoulseekDownloader:
    """Return the module-level SoulseekDownloader singleton."""
    global _default_client
    if _default_client is None:
        with _init_lock:
            if _default_client is None:
                _default_client = SoulseekDownloader()
    return _default_client
