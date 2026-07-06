#!/usr/bin/env bash
#
# bundle.sh — gera dist/FactorJ.app a partir do build release do SwiftPM.
#
# Assinatura ad-hoc (distribuição sem notarização). Developer ID + notarização ficam
# para a Fase 3 (ver docs/especificacao.md §9).

set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Build release…"
# Scratch próprio: evita disputa pelo build.db com o SourceKit do editor.
SCRATCH=".build-release"
BIN="$SCRATCH/release/FactorJ"
# Em alguns ambientes o llbuild reporta erro benigno ao gravar o build.db
# mesmo com o build concluído; validamos o artefato em vez do exit code.
rm -f "$BIN"
swift build -c release --scratch-path "$SCRATCH" || true
[[ -x "$BIN" ]] || { echo "ERRO: build release falhou (binário ausente)."; exit 1; }
APP="dist/FactorJ.app"

echo "==> Montando ${APP} …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FactorJ"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Factor J</string>
    <key>CFBundleDisplayName</key>
    <string>Factor J</string>
    <key>CFBundleIdentifier</key>
    <string>com.factorj.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>FactorJ</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Factor J — 100% offline. Licença MIT.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>O Factor J usa o microfone para gravar reuniões. Nada sai do seu Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>O Factor J captura o áudio do sistema para transcrever reuniões. Nada sai do seu Mac.</string>
</dict>
</plist>
PLIST

# Ícone do app (gerado por scripts/make_icon.swift)
if [[ -f assets/AppIcon.icns ]]; then
    cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Assinando (ad-hoc)…"
# Remove xattrs/resource forks que o codesign rejeita ("detritus not allowed").
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "✅ Pronto: $APP"
echo "   Arraste para /Applications ou rode: open $APP"
