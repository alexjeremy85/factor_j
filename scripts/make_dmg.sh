#!/usr/bin/env bash
#
# make_dmg.sh — gera o DMG de distribuição (dist/FactorJ-<versão>.dmg).
#
# O app é assinado ad-hoc (sem notarização): na primeira abertura o usuário
# precisa usar botão direito → Abrir. Documentado no README.

set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

VERSION=$(defaults read "$PWD/dist/FactorJ.app/Contents/Info" CFBundleShortVersionString)
STAGING="dist/dmg-staging"
DMG="dist/FactorJ-${VERSION}.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R dist/FactorJ.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Factor J" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "✅ ${DMG}"
echo "   Publique com: gh release create v${VERSION} ${DMG} --title \"Factor J ${VERSION}\""
