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

    # Tenta cada query de busca
    for attempt_idx, query in enumerate(queries):
        print(f"[Backend] Tentando busca ({attempt_idx + 1}/{len(queries)}): {query}")
        
        # Buscamos os primeiros 5 resultados (sem baixar) usando o prefixo ytsearch5:
        search_opts = {
            'extract_flat': True,
            'quiet': True,
            'no_warnings': True,
            'nocheckcertificate': True,
            'geo_bypass': True,
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
