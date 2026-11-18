// Transcripción con Whisper al terminar la grabación (Python + openai-whisper; ver instalar_whisper.sh).
import Foundation

/// Carpeta de películas del usuario: en disco siempre es `Movies` (Finder la muestra como «Películas» en español).
let carpetaPeliculas = NSSearchPathForDirectoriesInDomains(.moviesDirectory, .userDomainMask, true).first ?? NSString(string: "~/Movies").expandingTildeInPath
/// Todo vive en <Películas>/Note-Taker: los videos en Note-Taker-Videos y las transcripciones en Note-Taker-Transcriptions.
let carpetaNoteTaker = carpetaPeliculas + "/Note-Taker"
let carpetaVideos = carpetaNoteTaker + "/Note-Taker-Videos"
/// Transcripciones; ULTIMA_TRANSCRIPCION.txt siempre es la más reciente.
let carpetaNotas = carpetaNoteTaker + "/Note-Taker-Transcriptions"

/// Carpeta propia de Note Taker: todo lo que instala o genera vive aquí (borrar `whisper/` desinstala Whisper y sus modelos).
let carpetaTrabajo = NSString(string: "~/.note-taker").expandingTildeInPath
/// Whisper: `entorno/` (Python + openai-whisper), `modelos/` y `note_taker_transcribir.py` (lo deja instalar_whisper.sh / el compilador).
let carpetaWhisper = carpetaTrabajo + "/whisper"
/// Registros de la app y de las transcripciones.
let carpetaRegistros = carpetaTrabajo + "/registros"
/// Archivos de trabajo de la grabación en curso (el crudo se borra al mezclar).
let carpetaTemporal = carpetaTrabajo + "/temporal"

enum EstadoTranscripcion: Equatable {
    case ninguna
    case enCurso(String)   // nombre del video
    case lista(String)     // ruta del .txt
    case error(String)
}

struct OpcionIdioma { let codigo: String; let nombre: String }
let idiomasWhisper = [
    OpcionIdioma(codigo: "es", nombre: "Español"),
    OpcionIdioma(codigo: "en", nombre: "English"),
    OpcionIdioma(codigo: "auto", nombre: "Detectar idioma")
]

/// Python del entorno de Whisper: variable NOTE_TAKER_PYTHON o ~/.note-taker/whisper/entorno (lo crea instalar_whisper.sh).
func rutaPythonWhisper() -> String? {
    if let e = ProcessInfo.processInfo.environment["NOTE_TAKER_PYTHON"], FileManager.default.isExecutableFile(atPath: e) { return e }
    let p = carpetaWhisper + "/entorno/bin/python"
    return FileManager.default.isExecutableFile(atPath: p) ? p : nil
}

func rutaScriptTranscribir() -> String? {
    if let r = Bundle.main.path(forResource: "note_taker_transcribir", ofType: "py") { return r }
    let p = carpetaWhisper + "/note_taker_transcribir.py"
    return FileManager.default.fileExists(atPath: p) ? p : nil
}

/// Corre Whisper (modelo turbo, el único de Note Taker) sobre el video (con prioridad baja) y devuelve la ruta del .txt, o el motivo del fallo.
/// No bloquea ningún hilo: lanza el proceso y espera su fin consultándolo (`esperarFin`, ver note_taker_app_motor.swift).
func transcribirVideo(_ video: URL, idioma: String) async -> (ok: Bool, texto: String) {
    guard let py = rutaPythonWhisper() else { return (false, "Whisper no está instalado: ejecuta instalar_whisper.sh (ver README).") }
    guard let script = rutaScriptTranscribir() else { return (false, "No se encontró note_taker_transcribir.py.") }
    try? FileManager.default.createDirectory(atPath: carpetaRegistros, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: carpetaNotas, withIntermediateDirectories: true)
    let log = carpetaRegistros + "/transcripcion.log"
    FileManager.default.createFile(atPath: log, contents: nil)
    let h = FileHandle(forWritingAtPath: log)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
    p.arguments = ["-n", "10", py, script, video.path, "--out", carpetaNotas, "--lang", idioma, "--ultima"]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["PYTHONUNBUFFERED"] = "1"
    p.environment = env
    p.standardOutput = h
    p.standardError = h
    let inicio = Date()
    do { try p.run() } catch { try? h?.close(); return (false, "No se pudo lanzar Whisper: \(error.localizedDescription)") }
    logApp("transcripción: inicio (\(video.lastPathComponent), pid \(p.processIdentifier))")
    let codigo = await esperarFin(p)
    try? h?.close()
    logApp("transcripción: fin (código \(codigo.map(String.init) ?? "sin código"), \(Int(Date().timeIntervalSince(inicio))) s)")
    let base = video.deletingPathExtension().lastPathComponent
    let txt = carpetaNotas + "/" + base + ".txt"
    // Sin código de salida (el proceso desapareció): vale el .txt solo si lo escribió esta corrida.
    let fechaTxt = (try? FileManager.default.attributesOfItem(atPath: txt)[.modificationDate]) as? Date
    let hayTxt = codigo == nil ? (fechaTxt.map { $0 >= inicio } ?? false) : FileManager.default.fileExists(atPath: txt)
    if (codigo == 0 || codigo == nil) && hayTxt { return (true, txt) }
    let cola = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(3).joined(separator: " · ")
    return (false, "Whisper terminó con error (\(codigo.map(String.init) ?? "sin código")). \(cola)")
}
