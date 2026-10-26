# 🎵 LA Player

Player de música Android: busca no Spotify, baixa pelo servidor (YouTube via yt-dlp, Soulseek quando o YouTube bloqueia) e toca offline.

**Versão final congelada: v2.6.0.** O LaPlayer vai ser refeito do zero; esta é a última versão que funciona.
Página com o APK e o passo a passo: https://pietroty.com.br (Projetos → LaPlayer).

## Usar

1. Instale o `laplayer.apk` (Android 8.0+).
2. Em Configurações → Servidor, coloque o endereço e a chave de acesso do seu servidor (o APK público vem sem nenhum).

## Rodar o servidor (`server/`)

Precisa de Python 3.12, ffmpeg e Node (o yt-dlp usa para os desafios do YouTube).

```sh
cd server
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 3004
```

Ou com Docker: `docker build -t laplayer-server . && docker run -d -p 3004:3004 --env-file .env laplayer-server`.

- Chaves e senhas ficam só no `.env` (na pasta do LaPlayer ou em `server/`), fora do git:
  `LAPLAYER_KEYS=chave1,chave2` (chaves aceitas; sem nenhuma o servidor recusa tudo) e `SLSKD_API_KEY`.
- Soulseek (opcional): `docker compose up -d` sobe o slskd; entre numa conta Soulseek pela interface (porta 5030)
  e use a mesma `SLSKD_API_KEY` no slskd e no servidor.
- Para o celular alcançar o servidor de fora de casa, exponha a porta 3004 com um túnel
  (por exemplo `cloudflared tunnel --url http://localhost:3004`) e use esse endereço no app.

## Compilar o app

```sh
./build_apk.sh          # laplayer.apk: versão pública, sem servidor nem chave
./build_apk.sh pessoal  # laplayer-pessoal.apk: já com LAPLAYER_SERVER e LAPLAYER_APP_KEY do .env
```

Feito por [@PietroTy](https://github.com/PietroTy) · 2026
