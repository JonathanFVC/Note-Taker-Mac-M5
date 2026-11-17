// Transcripción con Whisper al terminar la grabación (Python + openai-whisper; ver instalar_whisper.sh).
import Foundation

/// Carpeta del escritorio con las transcripciones; ULTIMA_TRANSCRIPCION.txt siempre es la más reciente.
let carpetaNotas = NSString(string: "~/Desktop/Note-Taker").expandingTildeInPath

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

/// Python del entorno de Whisper: variable NOTE_TAKER_PYTHON o ~/.note-taker/whisper-venv (lo crea instalar_whisper.sh).
func rutaPythonWhisper() -> String? {
    if let e = ProcessInfo.processInfo.environment["NOTE_TAKER_PYTHON"], FileManager.default.isExecutableFile(atPath: e) { return e }
    let p = NSString(string: "~/.note-taker/whisper-venv/bin/python").expandingTildeInPath
    return FileManager.default.isExecutableFile(atPath: p) ? p : nil
}

func rutaScriptTranscribir() -> String? {
    if let r = Bundle.main.path(forResource: "note_taker_transcribir", ofType: "py") { return r }
    let p = NSString(string: "~/.note-taker/note_taker_transcribir.py").expandingTildeInPath
    return FileManager.default.fileExists(atPath: p) ? p : nil
}

/// Corre Whisper sobre el video (con prioridad baja) y devuelve la ruta del .txt, o el motivo del fallo.
func transcribirVideo(_ video: URL, idioma: String, modelo: String = "turbo") async -> (ok: Bool, texto: String) {
    guard let py = rutaPythonWhisper() else { return (false, "Whisper no está instalado: ejecuta instalar_whisper.sh (ver README).") }
    guard let script = rutaScriptTranscribir() else { return (false, "No se encontró note_taker_transcribir.py.") }
    return await Task.detached(priority: .utility) { () -> (Bool, String) in
        let trabajo = NSString(string: "~/.note-taker").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: trabajo, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: carpetaNotas, withIntermediateDirectories: true)
        let log = trabajo + "/transcripcion.log"
        FileManager.default.createFile(atPath: log, contents: nil)
        let h = FileHandle(forWritingAtPath: log)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        p.arguments = ["-n", "10", py, script, video.path, "--out", carpetaNotas, "--model", modelo, "--lang", idioma, "--ultima"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        p.standardOutput = h
        p.standardError = h
        do { try p.run() } catch { return (false, "No se pudo lanzar Whisper: \(error.localizedDescription)") }
        p.waitUntilExit()
        try? h?.close()
        let base = video.deletingPathExtension().lastPathComponent
        let txt = carpetaNotas + "/" + base + ".txt"
        if p.terminationStatus == 0 && FileManager.default.fileExists(atPath: txt) { return (true, txt) }
        let cola = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(3).joined(separator: " · ")
        return (false, "Whisper terminó con error (\(p.terminationStatus)). \(cola)")
    }.value
}
