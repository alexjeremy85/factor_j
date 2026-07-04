#!/usr/bin/env bash
#
# test.sh — roda a suíte de testes.
#
# Com Xcode completo instalado, `swift test` puro funciona. Com apenas os
# Command Line Tools, o SwiftPM não adiciona sozinho os caminhos do
# framework Swift Testing — este script injeta as flags necessárias.

set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p)"

if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
    FW="$DEV_DIR/Library/Developer/Frameworks"
    LIB="$DEV_DIR/Library/Developer/usr/lib"
    exec swift test \
        -Xswiftc -F"$FW" \
        -Xlinker -F"$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$LIB" \
        "$@"
else
    exec swift test "$@"
fi
