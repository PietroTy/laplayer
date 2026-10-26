#!/usr/bin/env bash
# Gera o APK do LaPlayer.
#   ./build_apk.sh          → laplayer.apk: a versão pública, sem servidor nem chave (quem instala preenche)
#   ./build_apk.sh pessoal  → laplayer-pessoal.apk: já com LAPLAYER_SERVER e LAPLAYER_APP_KEY do .env
set -e
cd "$(dirname "$0")"
export PATH="$HOME/flutter-sdk/bin:$PATH" JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
defines=()
out=laplayer.apk
if [ "$1" = pessoal ]; then
    set -a; . ./.env; set +a
    : "${LAPLAYER_SERVER:?falta LAPLAYER_SERVER no .env}" "${LAPLAYER_APP_KEY:?falta LAPLAYER_APP_KEY no .env}"
    defines=(--dart-define=LAPLAYER_SERVER="$LAPLAYER_SERVER" --dart-define=LAPLAYER_KEY="$LAPLAYER_APP_KEY")
    out=laplayer-pessoal.apk
fi
(cd mobile && flutter build apk --release "${defines[@]}")
cp mobile/build/app/outputs/flutter-apk/app-release.apk "$out"
echo "✅ $out"
