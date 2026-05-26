# 🎵 LA Player

Player de música Android que baixa suas playlists do Spotify via YouTube e toca offline, com background audio e sync automático.

---

## Como funciona

```
PC (servidor) ──cloudflare tunnel──► GitHub (server_url.txt) ◄── App Android
      │                                                                │
      └──────────────── download via yt-dlp ◄────────────────────────┘
```

1. O servidor busca músicas no YouTube via `yt-dlp` e entrega como `.m4a`
2. A URL pública do servidor é publicada automaticamente no GitHub a cada início
3. O app Android descobre o servidor via GitHub e baixa/toca as músicas

---

## Rodar o servidor

```bash
# Instalar dependências (primeira vez)
pip install fastapi uvicorn yt-dlp mutagen requests --break-system-packages

# Iniciar
cd ~/Programas/Apps/laplayer
./start_server.sh
```

O script faz tudo: sobe o backend, cria o túnel Cloudflare e publica a URL no GitHub.

> **Requisito:** `cloudflared` instalado (`which cloudflared` para verificar)

---

## App Android

O APK compilado está em:
```
mobile/build/app/outputs/flutter-apk/app-release.apk
```

Para recompilar:
```bash
export PATH="/home/pit/Programas/flutter/bin:$PATH"
export ANDROID_HOME="/home/pit/Android/Sdk"
cd mobile && flutter build apk --release
```

### Primeiro uso
1. Instale o APK no Android
2. Vá em **Configurações → Spotify API** e adicione seu `Client ID` e `Client Secret`
3. Volte para **Home** e toque em **Sincronizar** — o app encontra o servidor automaticamente

---

## Stack

| Camada | Tecnologia |
|--------|-----------|
| App | Flutter + Dart |
| Áudio | just_audio + audio_service |
| Estado | Riverpod |
| Banco local | SQLite (sqflite) |
| HTTP | Dio |
| Servidor | FastAPI + Uvicorn |
| Download | yt-dlp |
| Tunnel | Cloudflare Tunnel |
| Discovery | GitHub raw (server_url.txt) |

---

## Funcionalidades

- ✅ Player offline com background audio e notificação
- ✅ Download via YouTube (busca automática por título + artista)
- ✅ Sync incremental com Spotify (metadados, capas, playlists)
- ✅ Busca local, favoritos, histórico, shuffle/repeat
- ✅ Discovery automático do servidor via GitHub
- ⏳ Letras sincronizadas (v2)
- ⏳ Equalizer (v2)
