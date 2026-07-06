#!/usr/bin/env bash
#
# fetch_models.sh — passo único de setup do FactorJ (§1.1 da especificação).
#
# Baixa os modelos de ML para ~/Library/Application Support/FactorJ/Models
# e gera o SHA256SUMS.txt usado na verificação de integridade do app.
# Este é o ÚNICO momento em que há rede envolvida; o app em si nunca conecta.
#
# Uso:
#   ./scripts/fetch_models.sh             # turbo + diarização (~1,7 GB)
#   ./scripts/fetch_models.sh --with-base  # inclui Whisper base (~+150 MB)
#   ./scripts/fetch_models.sh --with-large # inclui large-v3 completo (~+3 GB)
#   ./scripts/fetch_models.sh --with-vbx   # inclui diarização VBx (~+40 MB)
#
# Alternativa ao assistente do próprio app (Ajustes → Modelos).
# Requer o CLI do Hugging Face (hf ou huggingface-cli). Se não tiver:
#   pip3 install --user -U "huggingface_hub[cli]"   (ou pipx/brew)

set -euo pipefail

MODELS_DIR="${FACTORJ_MODELS_DIR:-$HOME/Library/Application Support/FactorJ/Models}"
WITH_BASE=0
WITH_LARGE=0
WITH_VBX=0
for arg in "$@"; do
    [[ "$arg" == "--with-base" ]] && WITH_BASE=1
    [[ "$arg" == "--with-large" ]] && WITH_LARGE=1
    [[ "$arg" == "--with-vbx" ]] && WITH_VBX=1
done

# Localiza o CLI do Hugging Face.
HF=""
for candidate in hf huggingface-cli; do
    if command -v "$candidate" >/dev/null 2>&1; then
        HF="$candidate"
        break
    fi
done
if [[ -z "$HF" ]]; then
    echo "ERRO: CLI do Hugging Face não encontrado."
    echo "Instale com: pip3 install --user -U 'huggingface_hub[cli]' (ou pipx/brew)"
    exit 1
fi

echo "==> Modelos serão instalados em: $MODELS_DIR"
mkdir -p "$MODELS_DIR"

# Espaço em disco (turbo + diarização ≈ 1,7 GB).
FREE_GB=$(df -g "$HOME" | awk 'NR==2 {print $4}')
echo "==> Espaço livre: ${FREE_GB} GB (necessário: ~2 GB)"
if [[ "$FREE_GB" -lt 4 ]]; then
    echo "AVISO: menos de 4 GB livres. Continue por sua conta (ctrl-C para abortar)."
    sleep 5
fi

TURBO="openai_whisper-large-v3-v20240930_turbo"
LARGE="openai_whisper-large-v3-v20240930"
BASE="openai_whisper-base"

echo ""
echo "==> [1/4] Whisper large-v3-turbo (CoreML, ~1,6 GB)…"
"$HF" download argmaxinc/whisperkit-coreml \
    --include "$TURBO/*" \
    --local-dir "$MODELS_DIR/whisperkit"

echo ""
echo "==> [2/4] Tokenizer do large-v3 (offline)…"
"$HF" download openai/whisper-large-v3 \
    tokenizer.json tokenizer_config.json config.json \
    --local-dir "$MODELS_DIR/whisperkit/tokenizers/$TURBO"

if [[ "$WITH_LARGE" == "1" ]]; then
    echo ""
    echo "==> [extra] Whisper large-v3 completo (~3 GB)…"
    "$HF" download argmaxinc/whisperkit-coreml \
        --include "$LARGE/*" \
        --local-dir "$MODELS_DIR/whisperkit"
    "$HF" download openai/whisper-large-v3 \
        tokenizer.json tokenizer_config.json config.json \
        --local-dir "$MODELS_DIR/whisperkit/tokenizers/$LARGE"
fi

if [[ "$WITH_BASE" == "1" ]]; then
    echo ""
    echo "==> [extra] Whisper base + tokenizer…"
    "$HF" download argmaxinc/whisperkit-coreml \
        --include "$BASE/*" \
        --local-dir "$MODELS_DIR/whisperkit"
    "$HF" download openai/whisper-base \
        tokenizer.json tokenizer_config.json config.json \
        --local-dir "$MODELS_DIR/whisperkit/tokenizers/$BASE"
fi

echo ""
echo "==> [3/4] Diarização: pyannote segmentation + WeSpeaker (CoreML, ~30 MB)…"
"$HF" download FluidInference/speaker-diarization-coreml \
    --include "pyannote_segmentation.mlmodelc/*" "wespeaker_v2.mlmodelc/*" \
    --local-dir "$MODELS_DIR/diarization"

if [[ "$WITH_VBX" == "1" ]]; then
    echo ""
    echo "==> [extra] Diarização VBx (alta precisão, ~40 MB)…"
    "$HF" download FluidInference/speaker-diarization-coreml \
        --include "Segmentation.mlmodelc/*" "FBank.mlmodelc/*" \
                  "Embedding.mlmodelc/*" "PldaRho.mlmodelc/*" \
        --local-dir "$MODELS_DIR/speaker-diarization-coreml"
    "$HF" download FluidInference/speaker-diarization-coreml \
        plda-parameters.json \
        --local-dir "$MODELS_DIR/speaker-diarization-coreml"
fi

echo ""
echo "==> [4/4] Gerando SHA256SUMS.txt (verificação de integridade)…"
(
    cd "$MODELS_DIR"
    # Ignora caches do hub e o próprio arquivo de somas.
    find . -type f \
        ! -path "*/.cache/*" \
        ! -name "SHA256SUMS.txt" \
        ! -name ".DS_Store" \
        -print0 | sort -z | xargs -0 shasum -a 256 | sed 's| \./| |' > SHA256SUMS.txt
)

# Remove caches de download do hub (economiza SSD).
rm -rf "$MODELS_DIR/whisperkit/.cache" "$MODELS_DIR/diarization/.cache" 2>/dev/null || true

echo ""
echo "✅ Modelos instalados. Abra o Factor J e confira em Ajustes → Modelos."
du -sh "$MODELS_DIR" 2>/dev/null || true
