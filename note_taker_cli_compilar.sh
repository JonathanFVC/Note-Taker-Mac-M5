#!/bin/bash
# Compila note-taker en ~/.local/bin (ver README.md)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin" "$HOME/.note-taker"
cp "$DIR/transcribir/note_taker_transcribir.py" "$HOME/.note-taker/"
swiftc -O "$DIR/note_taker_cli.swift" -o "$HOME/.local/bin/note-taker"
echo "Listo: $HOME/.local/bin/note-taker"
