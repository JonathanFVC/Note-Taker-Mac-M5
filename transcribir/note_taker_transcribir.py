"""Transcribe un video o audio con Whisper (modelo turbo) y deja el .txt y el .srt en una carpeta.

Lo lanzan la app y el comando de Note Taker al terminar una grabación; también se puede usar solo:
    python note_taker_transcribir.py grabacion.mov --out ~/Movies/Note-Taker/Note-Taker-Transcriptions --lang es --ultima

Note Taker usa un solo modelo, turbo, que instala `instalar_whisper.sh` en ~/.note-taker/whisper/modelos.
"""
import argparse
import fcntl
import os
import shutil
import sys

import whisper
from whisper.utils import get_writer

MODELO = "turbo"
CARPETA_SALIDA = os.path.join(os.path.expanduser("~/Movies"), "Note-Taker", "Note-Taker-Transcriptions")
# El modelo vive dentro de la carpeta de Note Taker (lo baja instalar_whisper.sh), no en ~/.cache.
CARPETA_MODELOS = os.path.join(os.path.expanduser("~/.note-taker"), "whisper", "modelos")
# Sin arrastrar el texto anterior como contexto: en la medición mejoró a turbo (3.6 % -> 3.2 % de error) y evita los bucles de
# repetición y las omisiones en juntas largas. La búsqueda en haz (beam search) no mejoró nada y tarda el doble, por eso no se usa.
OPCIONES_WHISPER = {"condition_on_previous_text": False}
# Cerrojo: solo una transcripción a la vez en toda la Mac (app, comando o varios clics); las demás esperan su turno.
CARPETA_TEMPORAL = os.path.join(os.path.expanduser("~/.note-taker"), "temporal")


def tomar_turno():
    os.makedirs(CARPETA_TEMPORAL, exist_ok=True)
    cerrojo = open(os.path.join(CARPETA_TEMPORAL, "transcribiendo.lock"), "w")
    try:
        fcntl.flock(cerrojo, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Hay otra transcripción en curso; esperando su turno...", flush=True)
        fcntl.flock(cerrojo, fcntl.LOCK_EX)
    return cerrojo  # se libera solo al terminar el proceso


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
        resultado = modelo.transcribe(ruta, language=idioma, verbose=False, fp16=fp16, **OPCIONES_WHISPER)
    except RuntimeError as error:
        if dispositivo != "mps":
            raise
        print(f"  Aviso: fallo en MPS ({error}); reintentando en CPU...", flush=True)
        resultado = modelo.to("cpu").transcribe(ruta, language=idioma, verbose=False, fp16=False, **OPCIONES_WHISPER)
        modelo.to(dispositivo)
    for formato in ("txt", "srt"):
        get_writer(formato, salida)(resultado, ruta)
    base = os.path.splitext(os.path.basename(ruta))[0]
    print(f"  -> Listo: {base}.txt y {base}.srt en {salida}", flush=True)
    return base


def main():
    analizador = argparse.ArgumentParser(description="Transcribe un video o audio con Whisper (modelo turbo).", allow_abbrev=False)
    analizador.add_argument("entradas", nargs="+", help="Archivo(s) de video o audio.")
    analizador.add_argument("--lang", default="es", help="Idioma del audio: es, en, ... o «auto» para detectarlo.")
    analizador.add_argument("--out", default=CARPETA_SALIDA, help=f"Carpeta de salida (por defecto: {CARPETA_SALIDA}).")
    analizador.add_argument("--model-dir", default=CARPETA_MODELOS, help=f"Carpeta del modelo (por defecto: {CARPETA_MODELOS}).")
    analizador.add_argument("--device", default=None, choices=["cuda", "mps", "cpu"], help="Forzar dispositivo.")
    analizador.add_argument("--ultima", action="store_true",
                            help="Además deja una copia como ULTIMA_TRANSCRIPCION.txt y .srt (siempre la más reciente).")
    argumentos = analizador.parse_args()

    idioma = None if argumentos.lang.lower() == "auto" else argumentos.lang
    dispositivo = argumentos.device or elegir_dispositivo()
    if dispositivo == "cpu":
        print("Aviso: no se detectó GPU (CUDA ni MPS); se usará CPU (más lento).", flush=True)
    os.makedirs(argumentos.out, exist_ok=True)
    _turno = tomar_turno()  # mientras viva esta variable, ninguna otra transcripción corre

    print(f"Cargando el modelo «{MODELO}» en {dispositivo} (la primera vez se descarga)...", flush=True)
    modelo = whisper.load_model(MODELO, device=dispositivo, download_root=argumentos.model_dir)

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
