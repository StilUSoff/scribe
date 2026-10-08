#!/usr/bin/env bash
# Сборка Scribe.app: release-сборка, бандл с Info.plist, подпись, установка в ~/Applications.
#   ./scripts/build-app.sh            — собрать и установить
#   SCRIBE_SIGN="Apple Development: …" — явно задать сертификат (иначе первый Apple Development)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release --product Scribe
BIN="$(swift build -c release --show-bin-path)"

APP=dist/Scribe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Scribe" "$APP/Contents/MacOS/Scribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # перерисовать: swift scripts/make-icon.swift
# Личная часть словаря (имена, внутренние термины) — не в git, но попадает в приложение, если файл есть.
if [ -f Resources/glossary.private.txt ]; then cp Resources/glossary.private.txt "$APP/Contents/Resources/"; fi
# Ресурсные бандлы SwiftPM (если зависимостям они нужны) кладём рядом с бинарником.
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

SIGN="${SCRIBE_SIGN:-$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')}"
# codesign отказывается подписывать файлы с расширенными атрибутами (метки Finder, карантин и т.п.).
xattr -cr "$APP"
# Постоянная подпись нужна, чтобы macOS не забывала разрешение на микрофон после каждой пересборки.
codesign --force --deep --sign "${SIGN:--}" "$APP"
codesign --verify --verbose=1 "$APP"

mkdir -p "$HOME/Applications"
if pgrep -xq Scribe; then pkill -x Scribe; sleep 1; fi
rm -rf "$HOME/Applications/Scribe.app"
cp -R "$APP" "$HOME/Applications/Scribe.app"
echo "Установлено: $HOME/Applications/Scribe.app"
