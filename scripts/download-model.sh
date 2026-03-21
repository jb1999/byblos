#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${HOME}/Library/Application Support/Byblos/models"
mkdir -p "$MODELS_DIR"

MODEL="${1:-whisper-base-en}"

case "$MODEL" in
    whisper-tiny-en)
        URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
        FILE="ggml-tiny.en.bin"
        ;;
    whisper-base-en)
        URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
        FILE="ggml-base.en.bin"
        ;;
    whisper-small-en)
        URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
        FILE="ggml-small.en.bin"
        ;;
    whisper-medium-en)
        URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin"
        FILE="ggml-medium.en.bin"
        ;;
    *)
        echo "Unknown model: $MODEL"
        echo "Available: whisper-tiny-en, whisper-base-en, whisper-small-en, whisper-medium-en"
        exit 1
        ;;
esac

DEST="$MODELS_DIR/$FILE"

if [ -f "$DEST" ]; then
    echo "Model already downloaded: $DEST"
    exit 0
fi

echo "Downloading $MODEL..."
curl -L --progress-bar -o "$DEST" "$URL"
echo "Downloaded to: $DEST"
