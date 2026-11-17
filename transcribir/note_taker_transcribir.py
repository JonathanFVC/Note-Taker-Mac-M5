"""Transcribe un video o audio con Whisper y deja el .txt y el .srt en una carpeta.

Lo lanzan la app y el comando de Note Taker al terminar una grabación; también se puede usar solo:
    python note_taker_transcribir.py grabacion.mov --out ~/Movies/Note-Taker/Note-Taker-Transcriptions --lang es --ultima
"""
import argparse
import os
import shutil
import sys

import whisper
from whisper.utils import get_writer

CARPETA_SALIDA = os.path.join(os.path.expanduser("~/Movies"), "Note-Taker", "Note-Taker-Transcriptions")


def elegir_dispositivo():
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda"
        if torch.backends.mps.is_available():
            return "mps"
    except ImportError:
        pass
    return "cpu"


def transcribir(modelo, ruta, salida, idioma, dispositivo):
    print(f"Transcribiendo: {ruta}", flush=True)
    fp16 = dispositivo == "cuda"  # en MPS se fuerza fp32; si falla, se reintenta una vez en CPU
    try:
        resultado = modelo.transcribe(ruta, language=idioma, verbose=False, fp16=fp16)
    except RuntimeError as error:
        if dispositivo != "mps":
            raise
        print(f"  Aviso: fallo en MPS ({error}); reintentando en CPU...", flush=True)
        resultado = modelo.to("cpu").transcribe(ruta, language=idioma, verbose=False, fp16=False)
        modelo.to(dispositivo)
    for formato in ("txt", "srt"):
        get_writer(formato, salida)(resultado, ruta)
    base = os.path.splitext(os.path.basename(ruta))[0]
    print(f"  -> Listo: {base}.txt y {base}.srt en {salida}", flush=True)
    return base


def main():
    analizador = argparse.ArgumentParser(description="Transcribe un video o audio con Whisper.")
    analizador.add_argument("entradas", nargs="+", help="Archivo(s) de video o audio.")
    analizador.add_argument("--model", default="turbo", help="Modelo de Whisper (por defecto: turbo).")
    analizador.add_argument("--lang", default="es", help="Idioma del audio: es, en, ... o «auto» para detectarlo.")
    analizador.add_argument("--out", default=CARPETA_SALIDA, help=f"Carpeta de salida (por defecto: {CARPETA_SALIDA}).")
    analizador.add_argument("--device", default=None, choices=["cuda", "mps", "cpu"], help="Forzar dispositivo.")
    analizador.add_argument("--ultima", action="store_true",
                            help="Además deja una copia como ULTIMA_TRANSCRIPCION.txt y .srt (siempre la más reciente).")
    argumentos = analizador.parse_args()

    idioma = None if argumentos.lang.lower() == "auto" else argumentos.lang
    dispositivo = argumentos.device or elegir_dispositivo()
    if dispositivo == "cpu":
        print("Aviso: no se detectó GPU (CUDA ni MPS); se usará CPU (más lento).", flush=True)
    os.makedirs(argumentos.out, exist_ok=True)

    print(f"Cargando el modelo «{argumentos.model}» en {dispositivo} (la primera vez se descarga)...", flush=True)
    modelo = whisper.load_model(argumentos.model, device=dispositivo)

    for ruta in argumentos.entradas:
        if not os.path.isfile(ruta):
            print(f"No existe el archivo: {ruta}", flush=True)
            sys.exit(1)
        base = transcribir(modelo, ruta, argumentos.out, idioma, dispositivo)
        if argumentos.ultima:
            for extension in ("txt", "srt"):
                shutil.copyfile(os.path.join(argumentos.out, f"{base}.{extension}"),
                                os.path.join(argumentos.out, f"ULTIMA_TRANSCRIPCION.{extension}"))
            print("  -> Copia actualizada: ULTIMA_TRANSCRIPCION.txt y .srt", flush=True)


if __name__ == "__main__":
    main()
