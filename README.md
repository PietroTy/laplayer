# 🎵 Localify

**Offline-first music player com sync do seu servidor de backup Spotify.**

Localify conecta ao `spotify_backup.py` e serve sua biblioteca pessoal para um app Android nativo, com playback em background, sync incremental e UI premium.

---

## Arquitetura

```
┌──────────────────────────────────────────────────────┐
│  PC / Servidor doméstico                             │
│                                                      │
│  spotify_backup.py  →  output/                       │
│                          └── MinhaPlaylist/          │
│                                ├── 0001. Track.m4a   │
│                                ├── tracks_metadata.json │
│                                └── progress.json     │
│                                                      │
│  server.py  (FastAPI :8888)  ← expõe a biblioteca   │
└───────────────────┬──────────────────────────────────┘
                    │  Wi-Fi local  (HTTP + WebSocket)
                    │
         ┌──────────▼──────────┐
         │  App Android        │
         │  (Flutter)          │
         │                     │
         │  • Player offline   │
         │  • Sync incremental │
         │  • Background audio │
         │  • SQLite local     │
         └─────────────────────┘
```

---

## Estrutura de Arquivos

```
localify/
├── server/
│   ├── server.py                 ← Servidor FastAPI (coloca junto com o backup)
│   └── requirements_server.txt  ← fastapi + uvicorn
│
└── mobile/
    ├── pubspec.yaml
    └── lib/
        ├── main.dart
        ├── app.dart
        ├── core/
        │   ├── theme.dart        ← Tema escuro premium
        │   ├── constants.dart
        │   └── router.dart       ← Navegação GoRouter
        ├── data/
        │   ├── models/
        │   │   ├── track.dart
        │   │   ├── playlist.dart
        │   │   └── player_state.dart
        │   ├── database/
        │   │   └── database.dart ← SQLite local
        │   └── services/
        │       ├── api_service.dart    ← HTTP client (Dio)
        │       ├── audio_handler.dart  ← Background audio
        │       └── sync_service.dart   ← Sync incremental com hash
        ├── providers/
        │   ├── player_provider.dart   ← Estado do player (Riverpod)
        │   └── library_provider.dart  ← Playlists, tracks, search
        └── screens/
            ├── home_screen.dart
            ├── library_screen.dart
            ├── playlist_screen.dart
            ├── player_screen.dart
            ├── settings_screen.dart
            └── widgets/
                ├── scaffold_with_nav.dart
                ├── mini_player.dart
                └── track_tile.dart
```

---

## Setup do Servidor

### 1. Instalar dependências extras

```bash
# Na pasta do spotify_backup.py
pip install fastapi uvicorn --break-system-packages
# ou
pip install -r server/requirements_server.txt
```

### 2. Copiar server.py para a pasta do backup

```bash
copy server\server.py .
# ou no Linux:
cp server/server.py .
```

### 3. Rodar o servidor

```bash
python server.py
```

O servidor abre em `http://0.0.0.0:8888`.

Verifique que o PC e o celular estão na **mesma rede Wi-Fi**.

Para descobrir o IP do seu PC:
- Windows: `ipconfig` → IPv4 Address
- Linux/Mac: `ip addr` ou `ifconfig`

---

## Setup do App Flutter

### Pré-requisitos

- Flutter SDK 3.22+ instalado
- Android SDK (API 21+)
- Dispositivo Android ou emulador

### Instalar dependências

```bash
cd mobile
flutter pub get
```

> ⚠️ O app usa `go_router` para navegação — adicione ao pubspec.yaml:
> ```yaml
> go_router: ^14.0.0
> ```
> (não incluído no gerado para deixar a versão em aberto)

### Rodar

```bash
flutter run
```

### Build APK

```bash
flutter build apk --release
# O APK fica em build/app/outputs/flutter-apk/app-release.apk
```

---

## Primeiros Passos no App

1. Abra o app → vá em **Configurações** (aba 3)
2. Digite o IP do seu PC e a porta (padrão: `8888`)
3. Toque em **Testar conexão** para verificar
4. Volte para **Home** e toque no ícone de sync (↻)
5. O app importa todas as playlists e metadados do servidor
6. Toque em uma playlist → **Tocar tudo**

---

## Sync Incremental

O sync compara **SHA-256** dos arquivos M4A:

```
Servidor → lista hashes de todos os .m4a
App      → compara com cache local
Diferente → baixa apenas o que mudou
```

Funciona igual ao Git — rápido e econômico em dados.

Para forçar re-sync de uma playlist específica, entre na playlist e toque no ícone de sync.

---

## Funcionalidades

| Feature                     | Status |
|-----------------------------|--------|
| Player offline              | ✅     |
| Streaming pelo servidor     | ✅     |
| Background audio + notif.   | ✅     |
| Sync incremental (hash)     | ✅     |
| SQLite local                | ✅     |
| Favoritos                   | ✅     |
| Histórico de reprodução     | ✅     |
| Shuffle / Repeat            | ✅     |
| Metadados completos         | ✅     |
| Capa do álbum               | ✅     |
| Busca local                 | ✅     |
| WebSocket (logs em tempo real) | ✅  |
| Letras (lyrics)             | ⏳ v2  |
| Sync P2P (sem internet)     | ⏳ v2  |
| Equalizer                   | ⏳ v2  |

---

## API do Servidor

| Método | Endpoint                            | Descrição                    |
|--------|-------------------------------------|------------------------------|
| GET    | `/health`                           | Ping / status                |
| GET    | `/playlists`                        | Lista de playlists            |
| GET    | `/playlists/{id}/tracks`            | Tracks de uma playlist        |
| GET    | `/tracks/{playlist}/{file}/stream`  | Stream do arquivo M4A         |
| GET    | `/sync/manifest`                    | Manifesto completo de hashes  |
| GET    | `/sync/playlist/{id}`               | Manifesto de uma playlist     |
| POST   | `/download`                         | Dispara download (body: {url})|
| WS     | `/ws`                               | WebSocket de eventos          |

---

## Tecnologias

**App:**
- Flutter + Dart
- just_audio + audio_service (background playback)
- Riverpod (state management)
- SQLite via sqflite
- Dio (HTTP)
- GoRouter (navegação)

**Servidor:**
- FastAPI + Uvicorn
- WebSocket nativo
- Integração direta com output do spotify_backup.py

---

## Licença

Uso pessoal. Respeite os termos de serviço do Spotify e as leis de direitos autorais da sua região.
