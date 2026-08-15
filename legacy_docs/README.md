# LA Player - Legacy Backup (yt-dlp & Cloudflare)

Este diretório contém o backup do sistema de download antigo do LA Player, antes da migração para a arquitetura nativa com `librespot` (Spotify direto).

## Arquivos Preservados:

### 1. `python_downloader_legacy.py`
**O que fazia:**
Era o script Python embutido no app (Chaquopy) responsável por baixar músicas usando o `yt-dlp`. 
Ele não usava o Spotify para baixar áudio, mas sim pesquisava o título e o artista no YouTube. 

**Características incríveis de resiliência (Engenharia de Fallback):**
- Tinha uma lógica avançada para descobrir instâncias dinâmicas e ativas do Piped e do Invidious (evitando IPs da darkweb como .onion ou .i2p).
- Buscava os vídeos e filtrava pelo "melhor match" de duração (para bater com a duração da faixa no Spotify).
- Tentava baixar via proxies do Piped caso o YouTube bloqueasse o download direto (Evitando Erro 429 - Too Many Requests).
- Tentava baixar diretamente trocando os `player_client` do YouTube (`ios`, `android_music`, `mweb`).
- Extraía o formato `140/.m4a` puro do YouTube.

### 2. `server_downloader_legacy.dart`
**O que fazia:**
Era a implementação no Dart (Flutter) que se comunicava com um servidor Python remoto.
- Buscava a URL pública do servidor no GitHub (`server_url.txt` gerado automaticamente pelo `start_server.ps1`).
- Fazia a ponte com o servidor que rodava atrás de um Cloudflare Tunnel.
- Esse servidor remoto fazia o download pesado via `yt-dlp` e enviava os bytes do `.m4a` para o celular do usuário.
*(Totalmente deletado na nova versão, pois o app agora baixa sozinho via Spotify).*

### 3. `standalone_downloader_legacy.dart`
**O que fazia:**
Era o fallback nativo no próprio Dart que usava o pacote `youtube_explode_dart`.
Se o servidor Cloudflare não respondesse, o celular assumia o controle e baixava a música diretamente do YouTube no próprio aplicativo Flutter.

---
**Por que mudamos?**
Mudamos para o `librespot` para baixar a música original e pura (.ogg 320kbps) diretamente dos servidores oficias do Spotify, usando uma conta Spotify Premium, ao invés de buscar aproximações (com possíveis introduções de clipes musicais) no YouTube.
