#!/bin/bash
# Instala Whisper para Note Taker: crea ~/.note-taker/whisper-venv con openai-whisper (necesita Homebrew).
set -euo pipefail
command -v brew >/dev/null || { echo "Falta Homebrew: https://brew.sh"; exit 1; }
for paquete in python@3.12 ffmpeg; do
  brew list --versions "$paquete" >/dev/null 2>&1 || brew install "$paquete"
done
PY="$(brew --prefix python@3.12)/bin/python3.12"
mkdir -p "$HOME/.note-taker"
[ -x "$HOME/.note-taker/whisper-venv/bin/python" ] || "$PY" -m venv "$HOME/.note-taker/whisper-venv"
"$HOME/.note-taker/whisper-venv/bin/python" -m pip install --upgrade pip openai-whisper
echo "Listo. La primera transcripción descarga el modelo «turbo» (~1.6 GB) y tarda más."
