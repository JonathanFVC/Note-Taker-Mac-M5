// note-taker: pantalla completa + audio del sistema + micrófono (ScreenCaptureKit), sin dispositivos virtuales.
// Detalle y trampas: README.md
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Opciones

struct Opciones {
    var segundos: Double? = nil
    var mic = true
    var micPredeterminado = false
    var micNombre: String? = nil
    var nativa = false
    var fps = 10
    var fpsExplicito = false
    var calidad = "baja"
    var bpp = 0.05
    var minBitrate = 250_000
    var pantalla: Int? = nil
    var salida = carpetaVideos
    var transcribir = true
    var idioma = "es"
    var conservarCrudo = false
    var detener = false
}

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
let dirTrabajo = carpetaTemporal
let archivoPid = dirTrabajo + "/grabando.pid"

func ayuda() -> Never {
    print("""
    note-taker — graba la pantalla completa con el audio del sistema y tu micrófono (sin BlackHole).

      note-taker                 inicia; Ctrl+C detiene, deja el .mov en Películas/Note-Taker/Note-Taker-Videos y lo transcribe con Whisper
      note-taker stop            detiene una grabación en curso (desde otra terminal)
      --segundos N                    se detiene solo a los N segundos
      --sin-mic                       solo audio del sistema
      --mic-predeterminado            usa la entrada elegida en el sistema (por defecto: el micrófono integrado de la Mac)
      --mic-nombre TEXTO              usa el micrófono cuyo nombre contenga TEXTO
      --calidad NIVEL                 del video: ultra (128 px, 1 cuadro/s), baja (960, por defecto), media (1280) o alta (1920); el audio no cambia
      --nativa                        resolución nativa del video
      --fps N                         cuadros por segundo (por defecto, los del nivel)
      --pantalla N                    pantalla número N (por defecto la principal)
      --salida DIR                    carpeta de salida del video (por defecto ~/Movies/Note-Taker/Note-Taker-Videos)
      --sin-transcribir               no transcribe con Whisper al terminar
      --idioma CODIGO                 idioma de la transcripción: es (por defecto), en o auto
      --conservar-crudo               conserva el archivo con las pistas separadas (diagnóstico)
    """)
    exit(0)
}

func leerOpciones() -> Opciones {
    var o = Opciones()
    var a = Array(CommandLine.arguments.dropFirst())
    func siguiente() -> String { a.isEmpty ? "" : a.removeFirst() }
    while !a.isEmpty {
        let x = a.removeFirst()
        switch x {
        case "stop", "detener": o.detener = true
        case "--segundos": o.segundos = Double(siguiente())
        case "--sin-mic": o.mic = false
        case "--mic-predeterminado": o.micPredeterminado = true
        case "--mic-nombre": o.micNombre = siguiente()
        case "--nativa": o.nativa = true
        case "--fps": o.fps = max(1, min(60, Int(siguiente()) ?? 10)); o.fpsExplicito = true
        case "--calidad": o.calidad = siguiente().lowercased()
        case "--pantalla": o.pantalla = Int(siguiente())
        case "--salida": o.salida = NSString(string: siguiente()).expandingTildeInPath
        case "--conservar-crudo": o.conservarCrudo = true
        case "--sin-transcribir": o.transcribir = false
        case "--idioma": o.idioma = siguiente().lowercased()
        case "-h", "--ayuda", "--help": ayuda()
        default: print("Opción desconocida: \(x)"); ayuda()
        }
    }
    if !(["ultra", "ultra-ahorro", "ultraahorro", "baja", "media", "alta"].contains(o.calidad)) { print("Nivel «\(o.calidad)» desconocido; se usa baja."); o.calidad = "baja" }
    return o
}

// MARK: - Utilidades

/// Presets de video (mismos que la app): ancho máximo, cuadros por segundo, bits por píxel y mínimo de bitrate.
func presetCLI(_ nombre: String) -> (ancho: Double, fps: Int, bpp: Double, minBr: Int) {
    switch nombre {
    case "ultra", "ultra-ahorro", "ultraahorro": return (128, 1, 0.10, 10_000)
    case "media": return (1280, 30, 0.05, 1_200_000)
    case "alta": return (1920, 30, 0.07, 2_000_000)
    default: return (960, 30, 0.04, 500_000)
    }
}

/// Corre Whisper sobre el video y deja la transcripción en ~/Movies/Note-Taker/Note-Taker-Transcriptions (ULTIMA_TRANSCRIPCION.txt es siempre la más reciente).
func transcribirCLI(_ video: URL, idioma: String) -> Bool {
    let envPy = ProcessInfo.processInfo.environment["NOTE_TAKER_PYTHON"]
    let porDefecto = carpetaWhisper + "/entorno/bin/python"
    guard let python = [envPy, porDefecto].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        aviso("⚠️ Whisper no está instalado: ejecuta instalar_whisper.sh (ver README).")
        return false
    }
    let script = carpetaWhisper + "/note_taker_transcribir.py"
    guard FileManager.default.fileExists(atPath: script) else {
        aviso("⚠️ Falta \(script): vuelve a ejecutar note_taker_cli_compilar.sh.")
        return false
    }
    let carpeta = carpetaNotas
    print("📝 Transcribiendo con Whisper (modelo turbo, idioma: \(idioma)); puede tardar unos minutos…")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
    p.arguments = ["-n", "10", python, script, video.path, "--out", carpeta, "--lang", idioma, "--ultima"]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    p.environment = env
    do { try p.run() } catch { aviso("⚠️ No se pudo lanzar Whisper: \(error.localizedDescription)"); return false }
    p.waitUntilExit()
    let base = video.deletingPathExtension().lastPathComponent
    guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: carpeta + "/" + base + ".txt") else {
        aviso("⚠️ Whisper terminó con error (\(p.terminationStatus)).")
        return false
    }
    print("✅ Transcripción: \(carpeta)/\(base).txt   (copia siempre actualizada: ULTIMA_TRANSCRIPCION.txt)")
    return true
}

func dbDe(_ p: Float) -> Double { p <= 0.00003 ? -90 : 20 * log10(Double(p)) }
func dbTexto(_ p: Float) -> String { p <= 0.0001 ? "silencio" : String(format: "%.0f dB", dbDe(p)) }
func mmss(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }
func aviso(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func pico(_ sb: CMSampleBuffer) -> Float {
    guard let fd = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return 0 }
    var p: Float = 0
    let esFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    try? sb.withAudioBufferList { abl, _ in
        for buf in abl {
            guard let d = buf.mData else { continue }
            if esFloat && asbd.mBitsPerChannel == 32 {
                let n = Int(buf.mDataByteSize) / 4
                let f = d.assumingMemoryBound(to: Float.self)
                for i in 0..<n { p = max(p, abs(f[i])) }
            } else if asbd.mBitsPerChannel == 16 {
                let n = Int(buf.mDataByteSize) / 2
                let s = d.assumingMemoryBound(to: Int16.self)
                for i in 0..<n { p = max(p, abs(Float(s[i])) / 32768) }
            }
        }
    }
    return p
}

/// Micrófono a usar: por defecto el integrado de la Mac (los de audífonos Bluetooth suenan mal y cambian el perfil de salida).
func elegirMicrofono(_ o: Opciones) -> AVCaptureDevice? {
    let todos = AVCaptureDevice.devices(for: .audio)
    if let n = o.micNombre, !n.isEmpty { return todos.first { $0.localizedName.localizedCaseInsensitiveContains(n) } }
    if o.micPredeterminado { return AVCaptureDevice.default(for: .audio) }
    let integrado: Int32 = 0x626C746E // 'bltn' = kAudioDeviceTransportTypeBuiltIn
    return todos.first { $0.transportType == integrado } ?? AVCaptureDevice.default(for: .audio)
}

func ajustesAAC(_ sb: CMSampleBuffer, kbps: Int?) -> [String: Any]? {
    guard let fd = CMSampleBufferGetFormatDescription(sb),
          let a = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
    let ch = Int(min(max(a.mChannelsPerFrame, 1), 2))
    var s: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: a.mSampleRate, AVNumberOfChannelsKey: ch]
    if let k = kbps { s[AVEncoderBitRateKey] = k * 1000 }
    return s
}

// MARK: - Grabador

final class Grabador: NSObject, SCStreamOutput, SCStreamDelegate {
    let q = DispatchQueue(label: "note-taker.captura")
    let op: Opciones
    let ancho: Int, alto: Int
    let urlCrudo: URL
    var stream: SCStream?
    var alDetenerElSistema: ((String) -> Void)?

    var writer: AVAssetWriter?
    var vIn: AVAssetWriterInput?, sIn: AVAssetWriterInput?, mIn: AVAssetWriterInput?
    var iniciado = false, rendirseMic = false, rendirseSis = false
    var pendV: CMSampleBuffer?
    var pendS: [CMSampleBuffer] = [], pendM: [CMSampleBuffer] = []
    var t0 = CMTime.invalid
    var finAudio = CMTime.zero
    var ultimoVideo: CMSampleBuffer?
    var ultimoVideoPTS = CMTime.zero
    var picoSis: Float = 0, picoMic: Float = 0, segSis: Float = 0, segMic: Float = 0
    var nV = 0, nS = 0, nM = 0, descartados = 0
    var errorEscritor: String?
    let reloj = Date()
    var ultimaLinea = 0

    init(op: Opciones, ancho: Int, alto: Int, urlCrudo: URL) {
        self.op = op; self.ancho = ancho; self.alto = alto; self.urlCrudo = urlCrudo
    }

    var tieneSis: Bool { sIn != nil }
    var tieneMic: Bool { mIn != nil }

    // Callbacks de ScreenCaptureKit (todos llegan por `q`)
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of tipo: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch tipo {
        case .screen: video(sb)
        case .audio: audio(sb, mic: false)
        default:
            if #available(macOS 15.0, *), tipo == .microphone { audio(sb, mic: true) }
        }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        alDetenerElSistema?("El sistema detuvo la captura: \(error.localizedDescription)")
    }

    func video(_ sb: CMSampleBuffer) {
        guard CMSampleBufferGetImageBuffer(sb) != nil else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let crudo = arr.first?[.status] as? Int, let st = SCFrameStatus(rawValue: crudo), st != .complete { return }
        nV += 1
        ultimoVideo = sb
        ultimoVideoPTS = CMSampleBufferGetPresentationTimeStamp(sb)
        if !iniciado {
            if pendV == nil { pendV = sb }
            intentarIniciar()
        } else {
            escribir(vIn, sb)
        }
    }

    func audio(_ sb: CMSampleBuffer, mic: Bool) {
        let p = pico(sb)
        if mic { nM += 1; picoMic = max(picoMic, p); segMic = max(segMic, p) }
        else { nS += 1; picoSis = max(picoSis, p); segSis = max(segSis, p) }
        if !iniciado {
            if mic { pendM.append(sb) } else { pendS.append(sb) }
            intentarIniciar()
        } else {
            escribir(mic ? mIn : sIn, sb)
        }
    }

    // Se crea el archivo cuando ya llegó el primer cuadro y el primer audio de cada fuente (o se agotó la espera).
    func intentarIniciar() {
        guard !iniciado, let v = pendV else { return }
        if pendS.isEmpty && !rendirseSis { return }
        if op.mic && pendM.isEmpty && !rendirseMic { return }
        do {
            let w = try AVAssetWriter(outputURL: urlCrudo, fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            let bitrate = max(op.minBitrate, Int(Double(ancho * alto * op.fps) * op.bpp))
            let vAjustes: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: ancho, AVVideoHeightKey: alto,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: max(10, op.fps * 10),
                    AVVideoMaxKeyFrameIntervalDurationKey: 10,
                    AVVideoExpectedSourceFrameRateKey: op.fps
                ] as [String: Any]
            ]
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: vAjustes)
            vi.expectsMediaDataInRealTime = true
            guard w.canAdd(vi) else { throw NSError(domain: "grabar", code: 1, userInfo: [NSLocalizedDescriptionKey: "no se pudo agregar la pista de video"]) }
            w.add(vi); vIn = vi
            if let primero = pendS.first, let aj = ajustesAAC(primero, kbps: 128) {
                let si = AVAssetWriterInput(mediaType: .audio, outputSettings: aj, sourceFormatHint: CMSampleBufferGetFormatDescription(primero))
                si.expectsMediaDataInRealTime = true
                if w.canAdd(si) { w.add(si); sIn = si }
            }
            if let primero = pendM.first, let aj = ajustesAAC(primero, kbps: nil) {
                let mi = AVAssetWriterInput(mediaType: .audio, outputSettings: aj, sourceFormatHint: CMSampleBufferGetFormatDescription(primero))
                mi.expectsMediaDataInRealTime = true
                if w.canAdd(mi) { w.add(mi); mIn = mi }
            }
            guard w.startWriting() else { throw w.error ?? NSError(domain: "grabar", code: 2, userInfo: [NSLocalizedDescriptionKey: "startWriting falló"]) }
            t0 = CMSampleBufferGetPresentationTimeStamp(v)
            w.startSession(atSourceTime: t0)
            writer = w; iniciado = true
            escribir(vIn, v); pendV = nil
            for b in pendS { escribir(sIn, b) }; pendS = []
            for b in pendM { escribir(mIn, b) }; pendM = []
        } catch {
            errorEscritor = "No se pudo iniciar el archivo: \(error.localizedDescription)"
            alDetenerElSistema?(errorEscritor!)
        }
    }

    func escribir(_ input: AVAssetWriterInput?, _ sb: CMSampleBuffer) {
        guard let input = input, let w = writer, w.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if CMTimeCompare(pts, t0) < 0 { return }
        guard input.isReadyForMoreMediaData else { descartados += 1; return }
        if input.append(sb) {
            if input === sIn || input === mIn {
                let d = CMSampleBufferGetDuration(sb)
                let fin = CMTimeAdd(pts, d.isValid ? d : .zero)
                if CMTimeCompare(fin, finAudio) > 0 { finAudio = fin }
            }
        } else {
            errorEscritor = w.error?.localizedDescription ?? "falló append"
        }
    }

    // Cierra las pistas (en `q`); luego quien llama espera finishWriting().
    func prepararCierre() -> AVAssetWriter? {
        guard iniciado, let w = writer, w.status == .writing else { return nil }
        let fin = CMTimeCompare(finAudio, ultimoVideoPTS) > 0 ? finAudio : ultimoVideoPTS
        // Si la pantalla quedó quieta al final, se repite el último cuadro para que el video dure lo mismo que el audio.
        if let lv = ultimoVideo, let vi = vIn, vi.isReadyForMoreMediaData,
           CMTimeGetSeconds(CMTimeSubtract(fin, ultimoVideoPTS)) > 0.5 {
            var info = CMSampleTimingInfo(duration: .invalid,
                                          presentationTimeStamp: CMTimeSubtract(fin, CMTime(value: 1, timescale: 10)),
                                          decodeTimeStamp: .invalid)
            var copia: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lv,
                                                  sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleBufferOut: &copia)
            if let c = copia { vi.append(c) }
        }
        vIn?.markAsFinished(); sIn?.markAsFinished(); mIn?.markAsFinished()
        w.endSession(atSourceTime: fin)
        return w
    }

    func duracionGrabada() -> Double {
        guard t0.isValid else { return 0 }
        let fin = CMTimeCompare(finAudio, ultimoVideoPTS) > 0 ? finAudio : ultimoVideoPTS
        return max(0, CMTimeGetSeconds(CMTimeSubtract(fin, t0)))
    }

    func imprimirEstado() {
        let t = Date().timeIntervalSince(reloj)
        let sSis = segSis, sMic = segMic
        segSis = 0; segMic = 0
        let estado = iniciado
            ? "⏺ \(mmss(t))   sistema \(dbTexto(sSis))   mic \(op.mic ? (tieneMic ? dbTexto(sMic) : "no disponible") : "apagado")"
            : "⏳ iniciando…"
        if isatty(2) != 0 {
            FileHandle.standardError.write(("\r\u{1B}[2K" + estado).data(using: .utf8)!)
        } else if Int(t) - ultimaLinea >= 10 {
            ultimaLinea = Int(t); aviso(estado)
        }
    }
}

// MARK: - Mezcla final con ffmpeg

func rutaFfmpeg() -> String? {
    for r in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: r) { return r }
    return nil
}

/// Une las pistas en un solo audio (sistema + micrófono) y deja el .mov definitivo. Devuelve nil si salió bien, o el motivo.
func mezclarYEntregar(crudo: URL, final: URL, dosPistas: Bool) -> String? {
    guard let ff = rutaFfmpeg() else { return "ffmpeg no está instalado (brew install ffmpeg)" }
    var args = ["-y", "-loglevel", "error", "-i", crudo.path]
    if dosPistas {
        args += ["-filter_complex",
                 "[0:a:0]aresample=48000,aformat=channel_layouts=stereo[s];[0:a:1]aresample=48000,aformat=channel_layouts=stereo[m];[s][m]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.97[a]",
                 "-map", "0:v:0", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k"]
    } else {
        args += ["-map", "0", "-c", "copy"]
    }
    args += ["-movflags", "+faststart", final.path]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ff)
    p.arguments = args
    let pipe = Pipe(); p.standardError = pipe
    do { try p.run() } catch { return "no se pudo ejecutar ffmpeg: \(error.localizedDescription)" }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return "ffmpeg falló: \(msg.prefix(300))"
    }
    return nil
}

// MARK: - Control de la grabación

var grabador: Grabador?
var deteniendo = false
var opciones = leerOpciones()
var fuentesSenal: [DispatchSourceSignal] = []
var urlFinal: URL!
var actividad: NSObjectProtocol?

func pidVivo(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

func detenerOtra() -> Never {
    guard let t = try? String(contentsOfFile: archivoPid, encoding: .utf8), let pid = Int32(t.trimmingCharacters(in: .whitespacesAndNewlines)), pidVivo(pid) else {
        print("No hay ninguna grabación en curso."); exit(0)
    }
    kill(pid, SIGINT)
    print("Deteniendo la grabación (pid \(pid))… se está cerrando y mezclando el audio.")
    for _ in 0..<240 { if !pidVivo(pid) { print("Listo. La ruta del video salió en la terminal donde grababas."); exit(0) }; Thread.sleep(forTimeInterval: 0.5) }
    print("Sigue cerrándose; revisa la terminal original."); exit(1)
}

func parar(_ motivo: String?) async {
    if deteniendo { return }
    deteniendo = true
    guard let g = grabador else { exit(1) }
    if isatty(2) != 0 { FileHandle.standardError.write("\r\u{1B}[2K".data(using: .utf8)!) }
    if let m = motivo { aviso("⚠️ \(m)") }
    print("⏹ Deteniendo y cerrando el archivo…")
    do { try await g.stream?.stopCapture() } catch { aviso("⚠️ stopCapture: \(error.localizedDescription)") }
    var w: AVAssetWriter?
    g.q.sync { w = g.prepararCierre() }
    guard let escritor = w else {
        aviso("❌ No se grabó nada (no llegó ningún cuadro de video).")
        try? FileManager.default.removeItem(atPath: archivoPid)
        exit(1)
    }
    await escritor.finishWriting()
    if escritor.status != .completed {
        aviso("❌ El archivo no se cerró bien: \(escritor.error?.localizedDescription ?? "?"). El crudo quedó en \(g.urlCrudo.path)")
        try? FileManager.default.removeItem(atPath: archivoPid)
        exit(1)
    }
    let dos = g.tieneSis && g.tieneMic
    if let fallo = mezclarYEntregar(crudo: g.urlCrudo, final: urlFinal, dosPistas: dos) {
        aviso("⚠️ No se pudo mezclar (\(fallo)). Se conserva el archivo con pistas separadas.")
        try? FileManager.default.moveItem(at: g.urlCrudo, to: urlFinal)
    } else if !opciones.conservarCrudo {
        try? FileManager.default.removeItem(at: g.urlCrudo)
    }
    try? FileManager.default.removeItem(atPath: archivoPid)
    let tam = ((try? FileManager.default.attributesOfItem(atPath: urlFinal.path)[.size]) as? NSNumber)?.doubleValue ?? 0
    print("✅ Listo: \(urlFinal.path)")
    print("   duración \(mmss(g.duracionGrabada()))  ·  \(String(format: "%.1f", tam / 1_048_576)) MB  ·  cuadros \(g.nV)  ·  descartados \(g.descartados)")
    print("   pico del audio del sistema: \(g.tieneSis ? dbTexto(g.picoSis) : "SIN PISTA")   ·   micrófono: \(op_micTexto(g))")
    if !g.tieneSis || g.picoSis <= 0.0001 {
        aviso("⚠️ No se captó audio del sistema. ¿Estaba sonando algo? Contenido con DRM (Netflix, Spotify) no se puede grabar. Si es la primera vez, revisa el permiso «Grabación de pantalla y audio del sistema» de esta terminal.")
    }
    if opciones.mic && (!g.tieneMic || g.picoMic <= 0.0001) {
        aviso("⚠️ El micrófono no registró sonido. Revisa el permiso de Micrófono de esta terminal y que el micrófono de entrada esté bien elegido.")
    }
    if opciones.transcribir { _ = transcribirCLI(urlFinal, idioma: opciones.idioma) }
    exit(0)
}

func op_micTexto(_ g: Grabador) -> String {
    if !opciones.mic { return "apagado" }
    return g.tieneMic ? dbTexto(g.picoMic) : "SIN PISTA"
}

func principal() async {
    if opciones.detener { detenerOtra() }
    try? FileManager.default.createDirectory(atPath: dirTrabajo, withIntermediateDirectories: true)
    if let t = try? String(contentsOfFile: archivoPid, encoding: .utf8), let pid = Int32(t.trimmingCharacters(in: .whitespacesAndNewlines)), pidVivo(pid) {
        aviso("Ya hay una grabación en curso (pid \(pid)). Usa «note-taker stop»."); exit(1)
    }
    if opciones.mic {
        var st = AVCaptureDevice.authorizationStatus(for: .audio)
        if st == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio); st = AVCaptureDevice.authorizationStatus(for: .audio) }
        if st != .authorized {
            aviso("⚠️ Sin permiso de Micrófono para esta terminal (Ajustes del Sistema › Privacidad y seguridad › Micrófono). Se graba solo el audio del sistema.")
            opciones.mic = false
        }
    }
    do {
        let contenido = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pantallas = contenido.displays
        guard !pantallas.isEmpty else { aviso("❌ No se encontró ninguna pantalla (¿falta el permiso de Grabación de pantalla?)."); exit(1) }
        var pantalla = pantallas.first(where: { $0.displayID == CGMainDisplayID() }) ?? pantallas[0]
        if let n = opciones.pantalla, n >= 1, n <= pantallas.count { pantalla = pantallas[n - 1] }
        let modo = CGDisplayCopyDisplayMode(pantalla.displayID)
        let pw = modo?.pixelWidth ?? pantalla.width * 2, ph = modo?.pixelHeight ?? pantalla.height * 2
        let pre = presetCLI(opciones.calidad)
        if !opciones.fpsExplicito { opciones.fps = pre.fps }
        opciones.bpp = pre.bpp; opciones.minBitrate = pre.minBr
        let escala = opciones.nativa ? 1.0 : min(1.0, pre.ancho / Double(pw))
        let ancho = (Int(Double(pw) * escala) / 2) * 2, alto = (Int(Double(ph) * escala) / 2) * 2

        let ts = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f.string(from: Date()) }()
        try? FileManager.default.createDirectory(atPath: opciones.salida, withIntermediateDirectories: true)
        urlFinal = URL(fileURLWithPath: opciones.salida + "/nota_\(ts).mov")
        let urlCrudo = URL(fileURLWithPath: dirTrabajo + "/crudo_\(ts).mov")

        let cfg = SCStreamConfiguration()
        cfg.width = ancho; cfg.height = alto
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(opciones.fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 6
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = false
        var nombreMic = "apagado"
        if opciones.mic {
            cfg.captureMicrophone = true
            if let m = elegirMicrofono(opciones) { cfg.microphoneCaptureDeviceID = m.uniqueID; nombreMic = m.localizedName }
            else if opciones.micNombre != nil { aviso("⚠️ No encontré un micrófono con ese nombre; se usa la entrada del sistema."); nombreMic = "entrada del sistema" }
            else { nombreMic = "entrada del sistema" }
        }

        let g = Grabador(op: opciones, ancho: ancho, alto: alto, urlCrudo: urlCrudo)
        grabador = g
        g.alDetenerElSistema = { motivo in Task { await parar(motivo) } }
        let filtro = SCContentFilter(display: pantalla, excludingApplications: [], exceptingWindows: [])
        let s = SCStream(filter: filtro, configuration: cfg, delegate: g)
        g.stream = s
        try s.addStreamOutput(g, type: .screen, sampleHandlerQueue: g.q)
        try s.addStreamOutput(g, type: .audio, sampleHandlerQueue: g.q)
        if opciones.mic { try s.addStreamOutput(g, type: .microphone, sampleHandlerQueue: g.q) }

        actividad = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Grabando pantalla")
        try await s.startCapture()
        try? "\(getpid())".write(toFile: archivoPid, atomically: true, encoding: .utf8)

        g.q.asyncAfter(deadline: .now() + 2.5) { g.rendirseMic = true; g.intentarIniciar() }
        g.q.asyncAfter(deadline: .now() + 6.0) { g.rendirseSis = true; g.rendirseMic = true; g.intentarIniciar() }
        let temporizador = DispatchSource.makeTimerSource(queue: g.q)
        temporizador.schedule(deadline: .now() + 1, repeating: 1)
        temporizador.setEventHandler { g.imprimirEstado() }
        temporizador.resume()
        fuentesSenal = [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { Task { await parar(nil) } }
            src.resume()
            return src
        }
        print("⏺ Grabando pantalla \(ancho)x\(alto) a \(opciones.fps) fps · audio del sistema + micrófono: \(nombreMic) → \(urlFinal.path)")
        print("  Ctrl+C (o «note-taker stop» desde otra terminal) para detener.")
        if let seg = opciones.segundos {
            try? await Task.sleep(nanoseconds: UInt64(seg * 1_000_000_000))
            await parar(nil)
        }
    } catch {
        aviso("❌ No se pudo iniciar la captura: \(error.localizedDescription)")
        aviso("   Si es la primera vez: Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema, activa esta terminal y vuelve a abrirla.")
        exit(1)
    }
}

Task { await principal() }
dispatchMain()
