#!/bin/bash
# ─────────────────────────────────────────────────────
# Rlink Release Builder
# Собирает билды для всех платформ в build/releases/
# Использование: ./build_release.sh [версия]
# Пример: ./build_release.sh 0.0.1
# ─────────────────────────────────────────────────────

set -e

VERSION="${1:-0.0.1}"
OUT="build/releases/v${VERSION}"
mkdir -p "$OUT"

echo "═══════════════════════════════════════"
echo "  Rlink v${VERSION} — Release Builder"
echo "═══════════════════════════════════════"

# ── Android APK ──────────────────────────────────────
echo ""
echo "📱 Building Android APK..."
flutter build apk --release \
  --build-name="$VERSION" \
  --build-number="$(date +%Y%m%d%H)" 2>&1 | tail -3
cp build/app/outputs/flutter-apk/app-release.apk "$OUT/Rlink-v${VERSION}.apk"
echo "✅ Android: $OUT/Rlink-v${VERSION}.apk"

# ── macOS ────────────────────────────────────────────
if [[ "$(uname)" == "Darwin" ]]; then
  echo ""
  echo "🍎 Building macOS..."
  flutter build macos --release \
    --build-name="$VERSION" \
    --build-number="$(date +%Y%m%d%H)" 2>&1 | tail -3
  # Find the .app — name may differ (mesh_chat.app, Rlink.app, etc.)
  APP_PATH=$(find build/macos/Build/Products/Release/ -maxdepth 1 -name "*.app" -type d | head -1)
  if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
    APP_NAME=$(basename "$APP_PATH")
    cd build/macos/Build/Products/Release/
    zip -r -y "../../../../../$OUT/Rlink-v${VERSION}_macos.zip" "$APP_NAME" > /dev/null
    cd ../../../../../
    echo "✅ macOS: $OUT/Rlink-v${VERSION}_macos.zip"
  else
    echo "⚠️  macOS .app not found at $APP_PATH"
  fi
fi

# ── Windows (только на Windows) ──────────────────────
if [[ "$(uname -s)" == *"MINGW"* ]] || [[ "$(uname -s)" == *"MSYS"* ]]; then
  echo ""
  echo "🪟 Building Windows..."
  flutter build windows --release \
    --build-name="$VERSION" \
    --build-number="$(date +%Y%m%d%H)" 2>&1 | tail -3
  WIN_PATH="build/windows/x64/runner/Release"
  if [ -d "$WIN_PATH" ]; then
    cd "$WIN_PATH"
    zip -r "../../../../$OUT/Rlink-v${VERSION}_windows.zip" . > /dev/null
    cd ../../../../
    echo "✅ Windows: $OUT/Rlink-v${VERSION}_windows.zip"
  fi
fi

# ── Linux (только на Linux) ──────────────────────────
if [[ "$(uname)" == "Linux" ]]; then
  echo ""
  echo "🐧 Building Linux..."
  flutter build linux --release \
    --build-name="$VERSION" \
    --build-number="$(date +%Y%m%d%H)" 2>&1 | tail -3
  LIN_PATH="build/linux/x64/release/bundle"
  if [ -d "$LIN_PATH" ]; then
    tar -czf "$OUT/Rlink-v${VERSION}_linux.tar.gz" -C "$LIN_PATH" .
    echo "✅ Linux: $OUT/Rlink-v${VERSION}_linux.tar.gz"
  fi
fi

echo ""
echo "═══════════════════════════════════════"
echo "  📦 Все файлы в: $OUT/"
echo "═══════════════════════════════════════"
ls -lh "$OUT/"

echo ""
echo "Для загрузки в GitHub Releases:"
echo "  gh release create v${VERSION} $OUT/* --repo MihailKashintsev/Rlink-releases --title \"Rlink v${VERSION}\" --notes \"Rlink v${VERSION}\""
