#!/bin/bash
# Instala Whisper dentro de la carpeta de Note Taker (~/.note-taker/whisper): entorno de Python y modelos. Ver README.md
# Uso: bash instalar_whisper.sh      (instala el entorno y el modelo turbo, el único que usa Note Taker)
set -euo pipefail
command -v brew >/dev/null || { echo "Falta Homebrew: https://brew.sh"; exit 1; }
for paquete in python@3.12 ffmpeg; do
  brew list --versions "$paquete" >/dev/null 2>&1 || brew install "$paquete"
done
PY="$(brew --prefix python@3.12)/bin/python3.12"
RAIZ="$HOME/.note-taker/whisper"
ENTORNO="$RAIZ/entorno"
MODELOS="$RAIZ/modelos"
mkdir -p "$MODELOS"
[ -x "$ENTORNO/bin/python" ] || "$PY" -m venv "$ENTORNO"
"$ENTORNO/bin/python" -m pip install --quiet --upgrade pip openai-whisper
# El modelo turbo (~1.6 GB) se baja a la carpeta de Note Taker (no a ~/.cache) si falta.
echo "Modelo «turbo»: descargando si falta…"
"$ENTORNO/bin/python" -c "import sys, whisper; whisper.load_model('turbo', device='cpu', download_root=sys.argv[1])" "$MODELOS"
echo "Listo. Whisper quedó en ${RAIZ} (entorno y modelo turbo). Borrar esa carpeta lo desinstala."
