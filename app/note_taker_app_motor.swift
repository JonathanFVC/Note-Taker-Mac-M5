// Motor de la app Note Taker: misma captura que el comando note-taker, con ganancias en vivo y medidores.
// Detalle: README.md
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreAudio

struct ResultadoGrabacion {
    var ruta: String
    var duracion: Double
    var megas: Double
    var picoSis: Float
    var picoMic: Float
    var avisos: [String]
    /// Notas informativas (no son fallos): se muestran en gris.
    var notas: [String] = []
}

/// Presets de video: solo cambian la imagen; el audio no se toca.
struct PresetVideo {
    let nombre: String
    let ancho: Double
    let fps: Int
    let bpp: Double
    let minBitrate: Int
    let mbPorHora: Int
    var nota: String = ""
}
let presetsVideo = [
    PresetVideo(nombre: "Ultra ahorro", ancho: 128, fps: 1, bpp: 0.10, minBitrate: 10_000, mbPorHora: 5, nota: "casi solo audio"),
    PresetVideo(nombre: "Baja", ancho: 960, fps: 30, bpp: 0.04, minBitrate: 500_000, mbPorHora: 320),
    PresetVideo(nombre: "Media", ancho: 1280, fps: 30, bpp: 0.05, minBitrate: 1_200_000, mbPorHora: 715),
    PresetVideo(nombre: "Alta", ancho: 1920, fps: 30, bpp: 0.07, minBitrate: 2_000_000, mbPorHora: 2200)
]

/// Crea `registros/` una sola vez (los globales de Swift se inicializan al primer uso).
private let registrosListos: Bool = { try? FileManager.default.createDirectory(atPath: carpetaRegistros, withIntermediateDirectories: true); return true }()

/// Formato de hora del registro, creado una sola vez (crear un DateFormatter en cada línea es caro).
private let formatoLog: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

func logApp(_ s: String) {
    _ = registrosListos
    let ruta = carpetaRegistros + "/app.log"
    let linea = "\(formatoLog.string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: ruta) { h.seekToEndOfFile(); h.write(Data(linea.utf8)); try? h.close() }
    else { try? linea.write(toFile: ruta, atomically: true, encoding: .utf8) }
}

func nombreModoMic(_ m: AVCaptureDevice.MicrophoneMode) -> String {
    switch m {
    case .standard: return "Estándar"
    case .wideSpectrum: return "Espectro amplio"
    case .voiceIsolation: return "Aislamiento de voz"
    @unknown default: return "Otro"
    }
}

func dbDe(_ p: Float) -> Double { p <= 0.00003 ? -90 : 20 * log10(Double(p)) }
func mmss(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }

func picoDe(_ sb: CMSampleBuffer) -> Float {
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

/// Multiplica el audio por `g` en el sitio (con tope en ±1).
func escalarAudio(_ sb: CMSampleBuffer, _ g: Float) {
    guard let fd = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return }
    let esFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    try? sb.withAudioBufferList { abl, _ in
        for buf in abl {
            guard let d = buf.mData else { continue }
            if esFloat && asbd.mBitsPerChannel == 32 {
                let n = Int(buf.mDataByteSize) / 4
                let f = d.assumingMemoryBound(to: Float.self)
                for i in 0..<n { f[i] = max(-1, min(1, f[i] * g)) }
            } else if asbd.mBitsPerChannel == 16 {
                let n = Int(buf.mDataByteSize) / 2
                let s = d.assumingMemoryBound(to: Int16.self)
                for i in 0..<n { s[i] = Int16(max(-32768, min(32767, Float(s[i]) * g))) }
            }
        }
    }
}

func ajustesAAC(_ sb: CMSampleBuffer, kbps: Int?) -> [String: Any]? {
    guard let fd = CMSampleBufferGetFormatDescription(sb),
          let a = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
    let ch = Int(min(max(a.mChannelsPerFrame, 1), 2))
    var s: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: a.mSampleRate, AVNumberOfChannelsKey: ch]
    if let k = kbps { s[AVEncoderBitRateKey] = k * 1000 }
    return s
}

// MARK: - Micrófonos y volumen de entrada del sistema

func microfonosDisponibles() -> [(id: String, nombre: String)] {
    AVCaptureDevice.devices(for: .audio).map { ($0.uniqueID, $0.localizedName) }
}

func microfonoIntegrado() -> AVCaptureDevice? {
    let integrado: Int32 = 0x626C746E // 'bltn'
    return AVCaptureDevice.devices(for: .audio).first { $0.transportType == integrado }
}

func idAudio(uid: String) -> AudioDeviceID? {
    var cf = uid as CFString
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let st = withUnsafeMutablePointer(to: &cf) { p in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
    }
    return (st == noErr && id != 0) ? id : nil
}

func volumenEntrada(uid: String) -> Double? {
    guard let id = idAudio(uid: uid) else { return nil }
    for el in 0...2 {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: AudioObjectPropertyElement(el))
        if AudioObjectHasProperty(id, &a) {
            var f: Float32 = 0; var s = UInt32(4)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &s, &f) == noErr { return Double(f) * 100 }
        }
    }
    return nil
}

func ponerVolumenEntrada(uid: String, porcentaje: Double) {
    guard let id = idAudio(uid: uid) else { return }
    var f = Float32(max(0, min(100, porcentaje)) / 100)
    for el in 0...2 {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: AudioObjectPropertyElement(el))
        var ajustable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &a), AudioObjectIsPropertySettable(id, &a, &ajustable) == noErr, ajustable.boolValue {
            AudioObjectSetPropertyData(id, &a, 0, nil, 4, &f)
            if el == 0 { return }
        }
    }
}

// MARK: - Mezcla final con ffmpeg

func rutaFfmpeg() -> String? {
    for r in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: r) { return r }
    return nil
}

/// ¿El proceso sigue corriendo? Un proceso ya terminado pero sin recoger (zombi) cuenta como terminado.
func procesoVivo(_ pid: Int32) -> Bool {
    var info = proc_bsdinfo()
    let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return n > 0 && info.pbi_status != UInt32(SZOMB)
}

/// Espera a que termine un proceso hijo SIN bloquear ningún hilo (nada de `waitUntilExit`): consulta cada 0.3 s. Devuelve su código de salida,
/// o nil si dejó de existir sin poder leerlo. Con `waitUntilExit` dentro de una tarea en segundo plano, la app se quedó esperando a ffmpeg
/// 8 min y a Whisper 2 h 15 min después de que ya habían terminado (2026-11-18).
func esperarFin(_ p: Process) async -> Int32? {
    let pid = p.processIdentifier
    var vueltas = 0
    // 0.3 s al principio (ffmpeg y las pruebas cortas terminan enseguida) y 1 s después: una junta larga tarda minutos y no hay que despertar la app 3 veces por segundo.
    while p.isRunning && procesoVivo(pid) { vueltas += 1; try? await Task.sleep(nanoseconds: vueltas < 20 ? 300_000_000 : 1_000_000_000) }
    return p.isRunning ? nil : p.terminationStatus
}

func mezclarYEntregar(crudo: URL, final: URL, dosPistas: Bool) async -> String? {
    guard let ff = rutaFfmpeg() else { return "ffmpeg no está instalado" }
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
    // Los errores de ffmpeg van a un archivo (no a un Pipe): así no hay riesgo de que se llene y lo detenga.
    let logFfmpeg = carpetaRegistros + "/mezcla.log"
    FileManager.default.createFile(atPath: logFfmpeg, contents: nil)
    let h = FileHandle(forWritingAtPath: logFfmpeg)
    p.standardError = h
    let inicio = Date()
    do { try p.run() } catch { try? h?.close(); return "no se pudo ejecutar ffmpeg: \(error.localizedDescription)" }
    logApp("mezcla: inicio (ffmpeg pid \(p.processIdentifier))")
    let codigo = await esperarFin(p)
    try? h?.close()
    logApp("mezcla: fin (código \(codigo.map(String.init) ?? "sin código"), \(Int(Date().timeIntervalSince(inicio))) s)")
    if codigo != 0 {
        let msg = (try? String(contentsOfFile: logFfmpeg, encoding: .utf8)) ?? ""
        return "ffmpeg falló: \(msg.prefix(300))"
    }
    return nil
}

// MARK: - Motor

final class Motor: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum Modo { case inactivo, monitor, grabando, cerrando }

    let q = DispatchQueue(label: "note-taker-app.captura")
    let lock = NSLock()
    let ajustes: Ajustes
    var stream: SCStream?
    var sesionMic: AVCaptureSession?
    var micBase = CMTime.invalid
    var micMuestras: Int64 = 0
    var micConvUltimo = CMTime.zero
    var micTasa: Int32 = 0, micBloques = 0, micCanales: UInt32 = 0, micMuestrasPorBloque = 0
    var modo: Modo = .inactivo
    var alError: ((String) -> Void)?
    var inicioGrabacion = Date()
    var urlFinal = URL(fileURLWithPath: "/dev/null")

    // Ganancias lineales (las lee la cola de captura)
    var gSis: Float = 1
    var gMic: Float = 1

    // Niveles (protegidos por `lock`)
    var ventanaSis: Float = 0, ventanaMic: Float = 0, ventanaMicCrudo: Float = 0
    var picoSisGrab: Float = 0, picoMicGrab: Float = 0
    var ultimoAudioMic = Date.distantPast

    // Escritor (solo en `q`)
    var escribiendo = false
    var congelado = false
    var sesion = 0
    var ancho = 0, alto = 0, fps = 30
    var bpp = 0.05, minBitrate = 250_000
    var urlCrudo = URL(fileURLWithPath: "/dev/null")
    var writer: AVAssetWriter?
    var vIn: AVAssetWriterInput?, sIn: AVAssetWriterInput?, mIn: AVAssetWriterInput?
    var iniciado = false, rendirseMic = false, rendirseSis = false, hayMicEnConfig = false
    var pendV: CMSampleBuffer?
    var pendS: [CMSampleBuffer] = [], pendM: [CMSampleBuffer] = []
    var t0 = CMTime.invalid
    var finAudio = CMTime.zero
    var finSis = CMTime.zero, finMic = CMTime.zero
    var ultimoVideo: CMSampleBuffer?
    var ultimoVideoPTS = CMTime.zero
    var descartados = 0
    var errorEscritor: String?

    init(ajustes: Ajustes) {
        self.ajustes = ajustes
        super.init()
        actualizarGanancias()
    }

    func actualizarGanancias() {
        gSis = Float(pow(10.0, ajustes.gananciaSisDB / 20))
        gMic = Float(pow(10.0, ajustes.gananciaMicDB / 20))
    }

    func dispositivoMic() -> AVCaptureDevice? {
        if !ajustes.micID.isEmpty, let d = AVCaptureDevice.devices(for: .audio).first(where: { $0.uniqueID == ajustes.micID }) { return d }
        return microfonoIntegrado() ?? AVCaptureDevice.default(for: .audio)
    }

    func resetearPicosGrab() { lock.lock(); picoSisGrab = 0; picoMicGrab = 0; lock.unlock() }
    func leerPicosGrab() -> (Float, Float) { lock.lock(); defer { lock.unlock() }; return (picoSisGrab, picoMicGrab) }

    func leerNiveles() -> (sis: Float, mic: Float, micCrudo: Float, micVivo: Bool) {
        lock.lock(); defer { lock.unlock() }
        let r = (ventanaSis, ventanaMic, ventanaMicCrudo, Date().timeIntervalSince(ultimoAudioMic) < 1.5)
        ventanaSis = 0; ventanaMic = 0; ventanaMicCrudo = 0
        return r
    }

    // MARK: Captura

    @MainActor
    func arrancarStream() async throws {
        let contenido = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let objetivo = try resolverObjetivo(contenido)  // pantalla, ventana o área, según «Qué grabar»
        let pw = objetivo.pixelesAncho, ph = objetivo.pixelesAlto
        let pre = presetsVideo[max(0, min(presetsVideo.count - 1, ajustes.calidadVideo))]
        let esc = min(1.0, pre.ancho / Double(pw))
        let w = max(2, (Int(Double(pw) * esc) / 2) * 2), h = max(2, (Int(Double(ph) * esc) / 2) * 2), fpsUso = pre.fps
        q.sync { ancho = w; alto = h; fps = fpsUso; bpp = pre.bpp; minBitrate = pre.minBitrate }
        logApp("video: preset \(pre.nombre) \(w)x\(h) a \(fpsUso) fps · \(objetivo.descripcion)")
        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h
        if let a = objetivo.area { cfg.sourceRect = a }
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fpsUso))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 6
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = false
        let usarMic = ajustes.microfonoActivo && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        q.sync { hayMicEnConfig = usarMic }
        let filtro = objetivo.filtro
        let s = SCStream(filter: filtro, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
        if usarMic { await arrancarMic() }
    }

    @MainActor
    func detenerStream() async {
        await detenerMic()
        if let s = stream { try? await s.stopCapture() }
        stream = nil
    }

    /// Micrófono por AVCaptureSession (camino oficial de Apple): así macOS ofrece el «Aislamiento de voz» en el Centro de control.
    @MainActor
    func arrancarMic() async {
        guard let mic = dispositivoMic() else { logApp("mic: sin dispositivo"); return }
        let t0 = DispatchTime.now()
        // La sesión se arma fuera del hilo principal (crear la entrada del micrófono habla con el servicio de audio del sistema y puede tardar).
        let armada: AVCaptureSession? = await Task.detached(priority: .userInitiated) { [self] () -> AVCaptureSession? in
            let s = AVCaptureSession()
            do {
                let entrada = try AVCaptureDeviceInput(device: mic)
                guard s.canAddInput(entrada) else { logApp("mic: no se pudo agregar la entrada"); return nil }
                s.addInput(entrada)
                let salida = AVCaptureAudioDataOutput()
                salida.setSampleBufferDelegate(self, queue: q)
                guard s.canAddOutput(salida) else { logApp("mic: no se pudo agregar la salida"); return nil }
                s.addOutput(salida)
            } catch { logApp("mic: error \(error.localizedDescription)"); return nil }
            return s
        }.value
        guard let s = armada else { return }
        micBase = .invalid; micMuestras = 0; micBloques = 0
        sesionMic = s  // antes de arrancar: el primer bloque ya consulta su reloj
        await Task.detached { s.startRunning() }.value
        let reloj = s.synchronizationClock
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        logApp("mic: \(mic.localizedName) corriendo=\(s.isRunning) reloj_igual_al_del_sistema=\(reloj.map { CFEqual($0, CMClockGetHostTimeClock()) } ?? true) · arranque \(ms) ms")
    }

    @MainActor
    func detenerMic() async {
        guard let s = sesionMic else { return }
        sesionMic = nil
        await Task.detached { s.stopRunning() }.value
    }

    /// La hora del micrófono se calcula contando muestras desde su primer bloque (la conversión de reloj de AVCaptureSession se adelanta).
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sb.isValid else { return }
        // Con el panel abierto (monitor) solo se mide el nivel: no hace falta calcular tiempos ni copiar el bloque.
        if !escribiendo { audio(sb, mic: true); return }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee, asbd.mSampleRate > 0 else { return }
        let rate = Int32(asbd.mSampleRate)
        var conv = CMSampleBufferGetPresentationTimeStamp(sb)
        if let reloj = sesionMic?.synchronizationClock, !CFEqual(reloj, CMClockGetHostTimeClock()) {
            conv = CMSyncConvertTime(conv, from: reloj, to: CMClockGetHostTimeClock())
        }
        micConvUltimo = conv
        micTasa = rate; micBloques += 1; micCanales = asbd.mChannelsPerFrame; micMuestrasPorBloque = n
        if !micBase.isValid { micBase = conv; micMuestras = 0 }
        let pts = CMTimeAdd(micBase, CMTime(value: micMuestras, timescale: rate))
        micMuestras += Int64(n)
        var info = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate), presentationTimeStamp: pts, decodeTimeStamp: .invalid) // la duración es POR MUESTRA
        var copia: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleBufferOut: &copia)
        audio(copia ?? sb, mic: true)
    }

    @MainActor
    func iniciarMonitor() async -> String? {
        // Monitor de niveles con el panel abierto: el micrófono (AVCaptureSession; mantiene vivo el medidor de voz y el «Aislamiento de voz»)
        // y el audio de la Mac (ScreenCaptureKit SOLO de audio, sin salida de video). Así se ve el nivel
        // de ambos antes de empezar una junta; macOS muestra su píldora morada mientras el panel está abierto (medido: es inevitable).
        guard modo == .inactivo else { return nil }
        modo = .monitor
        let usarMic = ajustes.microfonoActivo && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        q.sync { hayMicEnConfig = usarMic }
        if usarMic { await arrancarMic() }
        await arrancarMonitorSistema()
        return nil
    }

    /// Captura solo el AUDIO de la Mac para el medidor: sin salida de video y con un cuadro de 2×2 px por segundo (casi sin costo).
    /// Usa el mismo objetivo que la grabación (pantalla, ventana o área); si no es válido todavía, mide el audio de toda la Mac.
    @MainActor
    func arrancarMonitorSistema() async {
        do {
            let contenido = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let principal = contenido.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? contenido.displays.first else { return }
            let filtro = (try? resolverObjetivo(contenido))?.filtro ?? SCContentFilter(display: principal, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = 2; cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = false
            let s = SCStream(filter: filtro, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
            try await s.startCapture()
            // Si mientras arrancaba se cerró el panel o empezó una grabación, este monitor ya no hace falta.
            if modo != .monitor { try? await s.stopCapture(); return }
            stream = s
        } catch { logApp("monitor del audio de la Mac: no arrancó (\(error.localizedDescription))") }
    }

    @MainActor
    func detenerMonitor() async {
        guard modo == .monitor else { return }
        await detenerStream()
        modo = .inactivo
    }

    @MainActor
    func reiniciarMonitor() async {
        guard modo == .monitor else { return }
        await detenerStream()
        modo = .inactivo
        _ = await iniciarMonitor()
    }

    // MARK: Callbacks de ScreenCaptureKit (en `q`)

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of tipo: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch tipo {
        case .screen: if escribiendo { video(sb) }
        case .audio: audio(sb, mic: false)
        default: break
        }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        let msg = "La captura se detuvo: \(error.localizedDescription)"
        DispatchQueue.main.async { self.alError?(msg) }
    }

    func video(_ sb: CMSampleBuffer) {
        guard CMSampleBufferGetImageBuffer(sb) != nil else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let crudo = arr.first?[.status] as? Int, let st = SCFrameStatus(rawValue: crudo), st != .complete { return }
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
        let crudo = picoDe(sb)  // una sola pasada por el bloque
        let g = mic ? gMic : gSis
        // El pico DESPUÉS de la ganancia (con tope en 1) sale de la cuenta, sin volver a recorrer el audio (antes: 3 pasadas); y la ganancia
        // solo se aplica al bloque cuando se está escribiendo (en el monitor del panel nadie usa el audio, solo el nivel).
        let p = (g == 1) ? crudo : min(1, crudo * g)
        if escribiendo && g != 1 { escalarAudio(sb, g) }
        lock.lock()
        if mic {
            ventanaMic = max(ventanaMic, p); ventanaMicCrudo = max(ventanaMicCrudo, crudo); ultimoAudioMic = Date()
            if escribiendo { picoMicGrab = max(picoMicGrab, p) }
        } else {
            ventanaSis = max(ventanaSis, p)
            if escribiendo { picoSisGrab = max(picoSisGrab, p) }
        }
        lock.unlock()
        guard escribiendo else { return }
        if !iniciado {
            if mic { pendM.append(sb) } else { pendS.append(sb) }
            intentarIniciar()
        } else {
            escribir(mic ? mIn : sIn, sb)
        }
    }

    // MARK: Escritor (en `q`)

    func reiniciarEscritor() {
        sesion += 1
        congelado = false
        writer = nil; vIn = nil; sIn = nil; mIn = nil
        iniciado = false; rendirseMic = false; rendirseSis = false
        pendV = nil; pendS = []; pendM = []
        t0 = .invalid; finAudio = .zero; finSis = .zero; finMic = .zero; ultimoVideo = nil; ultimoVideoPTS = .zero
        descartados = 0; errorEscritor = nil
        let s = sesion
        q.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, self.sesion == s, self.escribiendo else { return }
            self.rendirseMic = true; self.intentarIniciar()
        }
        q.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self = self, self.sesion == s, self.escribiendo else { return }
            self.rendirseSis = true; self.rendirseMic = true; self.intentarIniciar()
        }
    }

    func intentarIniciar() {
        guard !iniciado, escribiendo, let v = pendV else { return }
        if pendS.isEmpty && !rendirseSis { return }
        if hayMicEnConfig && pendM.isEmpty && !rendirseMic { return }
        do {
            let w = try AVAssetWriter(outputURL: urlCrudo, fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            let bitrate = max(minBitrate, Int(Double(ancho * alto * fps) * bpp))
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
                    AVVideoMaxKeyFrameIntervalKey: max(10, fps * 10),
                    AVVideoMaxKeyFrameIntervalDurationKey: 10,
                    AVVideoExpectedSourceFrameRateKey: fps
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
            logApp("escritor: t0=\(String(format: "%.3f", t0.seconds)) primer_sistema=\(pendS.first.map { String(format: "%.3f", CMSampleBufferGetPresentationTimeStamp($0).seconds) } ?? "-") primer_mic=\(pendM.first.map { String(format: "%.3f", CMSampleBufferGetPresentationTimeStamp($0).seconds) } ?? "-") pistas=\(sIn != nil ? "sistema " : "")\(mIn != nil ? "mic" : "")")
            writer = w; iniciado = true
            escribir(vIn, v); pendV = nil
            for b in pendS { escribir(sIn, b) }; pendS = []
            for b in pendM { escribir(mIn, b) }; pendM = []
        } catch {
            errorEscritor = "No se pudo iniciar el archivo: \(error.localizedDescription)"
            let msg = errorEscritor!
            DispatchQueue.main.async { self.alError?(msg) }
        }
    }

    func escribir(_ input: AVAssetWriterInput?, _ sb: CMSampleBuffer) {
        guard !congelado, let input = input, let w = writer, w.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if CMTimeCompare(pts, t0) < 0 { return }
        guard input.isReadyForMoreMediaData else { descartados += 1; return }
        if input.append(sb) {
            if input === sIn || input === mIn {
                let d = CMSampleBufferGetDuration(sb)
                let fin = CMTimeAdd(pts, d.isValid ? d : .zero)
                if CMTimeCompare(fin, finAudio) > 0 { finAudio = fin }
                if input === sIn { if CMTimeCompare(fin, finSis) > 0 { finSis = fin } }
                else if CMTimeCompare(fin, finMic) > 0 { finMic = fin }
            }
        } else {
            errorEscritor = w.error?.localizedDescription ?? "falló append"
        }
    }

    func prepararCierre() -> AVAssetWriter? {
        escribiendo = false
        guard iniciado, let w = writer, w.status == .writing else { return nil }
        let fin = CMTimeCompare(finAudio, ultimoVideoPTS) > 0 ? finAudio : ultimoVideoPTS
        logApp("mic: tasa=\(micTasa) canales=\(micCanales) bloques=\(micBloques) muestras=\(micMuestras) muestras_por_bloque=\(micMuestrasPorBloque) => \(micTasa > 0 ? String(format: "%.2f", Double(micMuestras) / Double(micTasa)) : "-") s por conteo; reloj: +\(String(format: "%.2f", micConvUltimo.seconds - micBase.seconds)) s")
        logApp("cierre: t0=\(String(format: "%.3f", t0.seconds)) fin_sistema=+\(String(format: "%.2f", finSis.seconds - t0.seconds)) fin_mic=+\(String(format: "%.2f", finMic.seconds - t0.seconds)) ultimo_video=+\(String(format: "%.2f", ultimoVideoPTS.seconds - t0.seconds)) mic_reloj_convertido=+\(String(format: "%.2f", micConvUltimo.seconds - t0.seconds)) fin_usado=+\(String(format: "%.2f", fin.seconds - t0.seconds))")
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

    // MARK: Grabación

    @MainActor
    func iniciarGrabacion() async -> String? {
        guard modo == .inactivo || modo == .monitor else { return "Ya hay una grabación en curso." }
        if modo == .monitor { await detenerStream() }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ts = f.string(from: Date())
        let salida = carpetaVideos
        let trabajo = carpetaTemporal
        try? FileManager.default.createDirectory(atPath: salida, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: trabajo, withIntermediateDirectories: true)
        urlFinal = URL(fileURLWithPath: salida + "/nota_\(ts).mov")
        let crudo = URL(fileURLWithPath: trabajo + "/crudo_\(ts).mov")
        resetearPicosGrab()
        q.sync { urlCrudo = crudo; escribiendo = true; reiniciarEscritor() }
        modo = .grabando
        do {
            try await arrancarStream()
            inicioGrabacion = Date()
            return nil
        } catch {
            q.sync { escribiendo = false }
            modo = .inactivo
            return "No se pudo iniciar la captura: \(error.localizedDescription)"
        }
    }

    @MainActor
    func detenerGrabacion() async -> ResultadoGrabacion? {
        guard modo == .grabando else { return nil }
        modo = .cerrando
        q.sync { congelado = true }
        logApp("detener: solicitado")
        await detenerStream()
        logApp("detener: captura parada")
        var w: AVAssetWriter?
        var dosPistas = false
        var descartadosFinal = 0
        var duracion = 0.0
        q.sync {
            w = prepararCierre()
            dosPistas = (sIn != nil && mIn != nil)
            descartadosFinal = descartados
            if t0.isValid {
                let fin = CMTimeCompare(finAudio, ultimoVideoPTS) > 0 ? finAudio : ultimoVideoPTS
                duracion = max(0, CMTimeGetSeconds(CMTimeSubtract(fin, t0)))
            }
        }
        var avisos: [String] = []
        guard let escritor = w else {
            modo = .inactivo
            return ResultadoGrabacion(ruta: "", duracion: 0, megas: 0, picoSis: 0, picoMic: 0, avisos: ["No se grabó nada (no llegó ningún cuadro de video)."])
        }
        await escritor.finishWriting()
        logApp("detener: archivo cerrado")
        let crudo = urlCrudo, final = urlFinal
        if escritor.status != .completed {
            avisos.append("El archivo no se cerró bien: \(escritor.error?.localizedDescription ?? "?"). El crudo quedó en \(crudo.path)")
            modo = .inactivo
            return ResultadoGrabacion(ruta: crudo.path, duracion: duracion, megas: 0, picoSis: 0, picoMic: 0, avisos: avisos)
        }
        let fallo = await mezclarYEntregar(crudo: crudo, final: final, dosPistas: dosPistas)
        if let fallo = fallo {
            avisos.append("No se pudo mezclar (\(fallo)). Se conserva el archivo con pistas separadas.")
            try? FileManager.default.moveItem(at: crudo, to: final)
        } else {
            try? FileManager.default.removeItem(at: crudo)
        }
        let (pS, pM) = leerPicosGrab()
        let tam = ((try? FileManager.default.attributesOfItem(atPath: final.path)[.size]) as? NSNumber)?.doubleValue ?? 0
        var notas: [String] = []
        let hayVoz = ajustes.microfonoActivo && pM > 0.0001
        if pS <= 0.0001 {
            // Solo voz y la Mac callada es normal (nadie reproducía nada): nota neutra; sin voz tampoco, es un aviso.
            if hayVoz { notas.append("Solo se grabó tu voz; del Mac no llegó sonido (normal si no sonaba nada).") }
            else { avisos.append("No se captó audio del Mac: ¿sonaba algo? (el contenido con DRM no se puede grabar).") }
        }
        if ajustes.microfonoActivo && pM <= 0.0001 { avisos.append("El micrófono no registró sonido: revisa el permiso de Micrófono y la ganancia.") }
        if hayVoz && pM >= 0.89 { notas.append("Tu voz llegó al límite (pico ≈ 0 dB): si suena aplastada, baja un poco «Nivel de mi voz».") }
        if descartadosFinal > 0 { avisos.append("Se descartaron \(descartadosFinal) bloques por sobrecarga.") }
        modo = .inactivo
        return ResultadoGrabacion(ruta: final.path, duracion: duracion, megas: tam / 1_048_576, picoSis: pS, picoMic: pM, avisos: avisos, notas: notas)
    }
}
